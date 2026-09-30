"""정지 대기·보관 등록 필드(레지스트리·영속·검증)와 허브 쪽 보고 요약."""

from __future__ import annotations

from dataclasses import replace

import pytest

from rpi.services.appliance_registry import (
    ApplianceButtonDef,
    ApplianceDef,
    ApplianceRegistry,
    ButtonKind,
)
from rpi.services.persistence import SimpleLayDb
from rpi.services.stop_park import (
    hold_plan_for,
    hold_status_fields,
    latest_hold_frame,
    validate_stop_park,
)
from rpi.services.twin_view import build_link_twin_state

LIMITS = {"SIMPLELAY_MOTION_X_MIN_MM": "0", "SIMPLELAY_MOTION_X_MAX_MM": "280",
          "SIMPLELAY_MOTION_Y_MIN_MM": "0", "SIMPLELAY_MOTION_Y_MAX_MM": "195"}


def appliance(**over):
    base = ApplianceDef(
        appliance_id="custom_mw", name="작은 전자레인지", rows=1, cols=3, is_custom=True,
        buttons=(
            ApplianceButtonDef("A", "시작", 0, 0, x_mm=50.0, y_mm=50.0),
            ApplianceButtonDef("B", "취소", 1, 0, x_mm=100.0, y_mm=50.0, press_ms=150),
            ApplianceButtonDef("C", "화력", 2, 0, kind=ButtonKind.DIAL, detents=6),
        ),
        stop_button="B", stop_presses=2, park_xy=(10.0, 190.0),
    )
    return replace(base, **over)


def test_validation_accepts_unverified_without_limits_and_ok_with_limits():
    assert validate_stop_park(appliance(), env={}).status == "unverified"
    assert validate_stop_park(appliance(), env=LIMITS).status == "ok"
    assert validate_stop_park(appliance(stop_button=None, park_xy=None), env={}).status == "none"
    check = validate_stop_park(appliance(park_xy=None), env={})
    assert check.status == "incomplete" and any("보관 위치" in n for n in check.notes)


@pytest.mark.parametrize("over, message", [
    ({"stop_presses": 0}, "1~3번"),
    ({"stop_presses": 4}, "1~3번"),
    ({"stop_button": "Z"}, "버튼에 없어요"),
    ({"stop_button": "C"}, "다이얼"),
    ({"park_xy": (55.0, 55.0)}, "너무 가까워요"),
    ({"park_xy": (700.0, 5.0)}, "mm 안의"),
])
def test_validation_rejects(over, message):
    with pytest.raises(ValueError, match=message):
        validate_stop_park(appliance(**over), env={})


def test_validation_rejects_points_outside_configured_soft_limits():
    with pytest.raises(ValueError, match="이동 범위"):
        validate_stop_park(appliance(park_xy=(279.0, 199.0)), env=LIMITS)


def test_hold_plan_uses_the_stop_button_label_mm_and_press_time():
    reg = ApplianceRegistry()
    reg.register(appliance())
    plan = hold_plan_for(reg, "custom_mw")
    assert plan == {"appliance_id": "custom_mw", "stop_button": "취소", "stop_x_mm": 100.0, "stop_y_mm": 50.0,
                    "stop_presses": 2, "park_x_mm": 10.0, "park_y_mm": 190.0, "press_ms": 150}
    reg.register(appliance(park_xy=None))
    assert hold_plan_for(reg, "custom_mw") is None
    assert hold_plan_for(reg, None) is None and hold_plan_for(None, "custom_mw") is None


def test_fields_survive_restart_and_builtin_overlay(tmp_path):
    db = SimpleLayDb(tmp_path / "s.db")
    reg = ApplianceRegistry(store=db)
    reg.register(appliance(panel_mapping={"photo": {"width": 10, "height": 10}}))
    reg.apply_calibration("microwave", version="v1", coords={"BT-06": (120.0, 80.0)},
                          stop_park={"stop_button": "BT-06", "stop_presses": 2, "park_xy": (10.0, 190.0),
                                     "panel_mapping": {"photo": {"width": 1, "height": 1}}})
    again = ApplianceRegistry(store=SimpleLayDb(tmp_path / "s.db"))
    custom = again.get("custom_mw")
    assert (custom.stop_button, custom.stop_presses, custom.park_xy) == ("B", 2, (10.0, 190.0))
    assert custom.panel_mapping == {"photo": {"width": 10, "height": 10}}
    mw = again.get("microwave")
    assert (mw.stop_button, mw.stop_presses, mw.park_xy) == ("BT-06", 2, (10.0, 190.0))
    assert hold_plan_for(again, "microwave")["stop_button"] == "취소"


def test_register_carries_stop_park_unless_request_sets_it_and_drops_a_removed_stop_button():
    reg = ApplianceRegistry()
    reg.register(appliance())
    plain = appliance(stop_button=None, stop_presses=1, park_xy=None)
    assert reg.register(plain).stop_button == "B"
    without_b = replace(plain, buttons=plain.buttons[:1])
    saved = reg.register(without_b)
    assert saved.stop_button is None and saved.park_xy == (10.0, 190.0)


def test_status_fields_and_twin_hold_view_come_only_from_rpi4_frames():
    assert hold_status_fields(None)["hold_state"] is None
    frames = [
        {"direction": "hub_to_act", "message": {"type": "execute", "sequence_id": "s1", "buttons": ["시작"]}},
        {"direction": "act_to_hub", "message": {"type": "result", "sequence_id": "s1", "success": True}},
        {"direction": "act_to_hub", "message": {
            "type": "progress", "sequence_id": "s1", "phase": "hold", "hold_state": "hovering_stop",
            "stop_button": "취소", "stop": {"x_mm": 100, "y_mm": 50}, "park": {"x_mm": 10, "y_mm": 190},
            "execution_mode": "mock", "appliance_id": "custom_mw"}},
    ]
    fields = hold_status_fields(latest_hold_frame(frames))
    assert fields["hold_state"] == "hovering_stop" and fields["hold_appliance_id"] == "custom_mw"
    twin = build_link_twin_state(frames, controller_mode="mock")
    assert twin["hold"]["stop"] == {"x_mm": 100, "y_mm": 50}
    assert twin["job"]["progress_count"] == 0  # 대기 보고는 누름 진행이 아니다
    # 다음 실행이 시작되면 이전 실행의 대기 보고를 붙이지 않는다
    frames.append({"direction": "hub_to_act", "message": {"type": "execute", "sequence_id": "s2",
                                                          "buttons": ["시작"]}})
    assert build_link_twin_state(frames, controller_mode="mock")["hold"] is None
