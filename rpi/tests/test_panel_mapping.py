"""사진 → mm 매핑(가전 추가 ②~④) — 원근 왜곡을 넣은 합성 점으로 확인한다. 실제 사진은 미검증."""

from __future__ import annotations

import numpy as np
import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app
from rpi.services.panel_mapping import (
    FrameConfig,
    MappingInput,
    MappingRejected,
    compute_mapping,
    frame_config,
)

#: mm → 사진 px 원근 변환(합성). 카메라가 비스듬히 본 프레임.
H = np.array([[2.1, 0.3, 150.0], [0.1, 2.4, 90.0], [0.0004, 0.0006, 1.0]])
FRAME = FrameConfig(300.0, 200.0, source="request")
CORNERS_MM = [(0, 0), (300, 0), (300, 200), (0, 200)]


def px(x_mm, y_mm):
    u, v, w = H @ np.array([x_mm, y_mm, 1.0])
    return [float(u / w), float(v / w)]


CORNERS = [px(*c) for c in CORNERS_MM]


def data(**over):
    base = dict(photo_w=1200, photo_h=900, corners_px=tuple(tuple(c) for c in CORNERS), frame=FRAME,
                buttons_px={"BT-05": tuple(px(250, 150)), "BT-06": tuple(px(200, 150))},
                park_px=tuple(px(20, 185)))
    base.update(over)
    return MappingInput(**base)


def test_perspective_distorted_taps_map_back_to_mm():
    result = compute_mapping(data())
    assert result.buttons_mm["BT-05"] == pytest.approx((250, 150), abs=0.01)
    assert result.buttons_mm["BT-06"] == pytest.approx((200, 150), abs=0.01)
    assert result.park_mm == pytest.approx((20, 185), abs=0.01)
    assert len(result.version) == 12
    assert result.quality["residual_check"] == "none"  # 네 점뿐이라 잔차 검증 없음을 밝힌다
    assert result.record["photo"] == {"width": 1200, "height": 900}
    assert result.record["buttons_px"]["BT-05"] == pytest.approx(px(250, 150))


def test_extra_reference_points_give_a_real_residual_check():
    extra = ((tuple(px(150, 100)), (150.0, 100.0)),)
    result = compute_mapping(data(extra_points=extra))
    assert result.quality["residual_check"] == "extra_points"
    assert result.quality["rms_error_mm"] < 0.01
    wrong = ((tuple(px(150, 100)), (170.0, 100.0)),)  # 기준점 mm를 20 mm 틀리게 적음
    with pytest.raises(MappingRejected):
        compute_mapping(data(extra_points=wrong))


def test_frame_origin_offset_shifts_every_point(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_FRAME_ORIGIN_X_MM", "12")
    monkeypatch.setenv("SIMPLELAY_FRAME_ORIGIN_Y_MM", "8")
    frame = frame_config(300, 200)
    result = compute_mapping(data(frame=frame))
    assert result.buttons_mm["BT-05"] == pytest.approx((262, 158), abs=0.01)


@pytest.mark.parametrize("corners, message", [
    ([CORNERS[0], CORNERS[1], CORNERS[3], CORNERS[2]], "순서가 꼬였어요"),
    ([CORNERS[0], CORNERS[3], CORNERS[2], CORNERS[1]], "반대 방향"),
    ([CORNERS[1], CORNERS[2], CORNERS[3], CORNERS[0]], "왼쪽 위가 아니에요"),
    ([CORNERS[0], CORNERS[1], [(CORNERS[1][0] + CORNERS[3][0]) / 2 + 1, (CORNERS[1][1] + CORNERS[3][1]) / 2 + 1],
      CORNERS[3]], "찌그러졌어요"),
    ([[100, 100], [130, 100], [130, 120], [100, 120]], "너무 작아요"),
    ([CORNERS[0], CORNERS[1], CORNERS[2], [-5, 500]], "사진 밖"),
])
def test_wrong_or_degenerate_corners_are_rejected_in_plain_korean(corners, message):
    with pytest.raises(MappingRejected, match=message):
        compute_mapping(data(corners_px=tuple(tuple(c) for c in corners)))


def test_photo_aspect_far_from_the_typed_size_is_no_longer_rejected():
    """2026-10-26 실사용: 자가 없어 잴 수 없는 크기와 사진 비율이 다르다고 거절했다 — 이제 기록만 한다."""
    flat = ((100.0, 100.0), (1100.0, 100.0), (1100.0, 250.0), (100.0, 250.0))
    result = compute_mapping(data(corners_px=flat, buttons_px={}, park_px=None))
    assert result.quality["photo_aspect"] > 6 and "aspect_factor" not in result.quality


def test_taps_outside_the_frame_and_missing_frame_size_are_rejected():
    with pytest.raises(MappingRejected, match="버튼판 네 귀퉁이 밖"):
        compute_mapping(data(buttons_px={"BT-05": tuple(px(360, 100))}))
    with pytest.raises(MappingRejected, match="버튼판 가로·세로 크기가 없어요"):
        compute_mapping(data(frame=FrameConfig(None, None)))


# ── API ─────────────────────────────────────────────────────────────────────


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    for name in ("SIMPLELAY_MOTION_X_MIN_MM", "SIMPLELAY_MOTION_X_MAX_MM",
                 "SIMPLELAY_MOTION_Y_MIN_MM", "SIMPLELAY_MOTION_Y_MAX_MM"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_FRAME_W_MM", "300")
    monkeypatch.setenv("SIMPLELAY_FRAME_H_MM", "200")
    caches = (deps.get_appliance_registry, deps.get_service)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


FAN = {"name": "거실 선풍기", "rows": 1, "cols": 3, "buttons": [
    {"id": "F-01", "label": "전원", "x": 0, "y": 0},
    {"id": "F-02", "label": "약풍", "x": 1, "y": 0},
    {"id": "F-03", "label": "정지", "x": 2, "y": 0}]}


def body(**over):
    base = {"photo_width": 1200, "photo_height": 900, "corners_px": CORNERS,
            "buttons_px": {"F-01": px(60, 100), "F-02": px(150, 100)},
            "stop_button": "F-03", "stop_px": px(240, 100), "stop_presses": 2, "park_px": px(15, 190)}
    base.update(over)
    return base


def test_mapping_preview_does_not_save_and_save_stores_stop_and_park(client):
    saved = client.put("/appliances/custom_fan", json=FAN).json()
    assert client.get("/mapping/frame").json()["frame_w_mm"] == 300

    preview = client.post("/appliances/custom_fan/mapping/preview", json=body())
    assert preview.status_code == 200, preview.text
    doc = preview.json()
    assert doc["saved"] is False and doc["buttons_mm"]["F-03"] == pytest.approx([240, 100], abs=0.01)
    assert doc["stop_park_check"]["status"] == "unverified"  # 소프트 리밋 미설정 → 범위 미확인
    fan = next(a for a in client.get("/appliances").json() if a["id"] == "custom_fan")
    assert fan["stop_button"] is None

    res = client.put("/appliances/custom_fan/mapping", json=body(expected_revision=saved["revision"]))
    assert res.status_code == 200, res.text
    app_doc = res.json()["appliance"]
    assert app_doc["stop_button"] == "F-03" and app_doc["stop_presses"] == 2
    assert app_doc["park_xy"] == pytest.approx([15, 190], abs=0.01)
    assert app_doc["panel_mapping"]["photo"] == {"width": 1200, "height": 900}
    assert app_doc["stop_park_check"]["status"] == "unverified"
    assert app_doc["revision"] == saved["revision"] + 1

    # 옛 폰 편집기가 이름만 바꿔 저장해도 정지·보관은 지워지지 않는다
    again = client.put("/appliances/custom_fan", json={**FAN, "name": "선풍기"}).json()
    assert again["stop_button"] == "F-03" and again["park_xy"] == pytest.approx([15, 190], abs=0.01)
    assert again["stop_presses"] == 2


def test_mapping_rejections_are_422_with_korean_messages(client):
    client.put("/appliances/custom_fan", json=FAN)
    swapped = [CORNERS[0], CORNERS[1], CORNERS[3], CORNERS[2]]
    res = client.put("/appliances/custom_fan/mapping", json=body(corners_px=swapped))
    assert res.status_code == 422 and "순서가 꼬였어요" in res.json()["detail"]
    res = client.put("/appliances/custom_fan/mapping", json=body(park_px=px(62, 100)))
    assert res.status_code == 422 and "너무 가까워요" in res.json()["detail"]
    res = client.put("/appliances/custom_fan/mapping", json=body(stop_button="X-9"))
    assert res.status_code == 422
    assert client.put("/appliances/custom_fan/mapping", json=body(stop_presses=4)).status_code == 422
    fan = next(a for a in client.get("/appliances").json() if a["id"] == "custom_fan")
    assert fan["calibration_version"] is None  # 거절되면 아무것도 저장하지 않는다


def test_soft_limits_turn_unverified_into_ok_or_reject(client, monkeypatch):
    client.put("/appliances/custom_fan", json=FAN)
    for name, value in (("X_MIN", "0"), ("X_MAX", "280"), ("Y_MIN", "0"), ("Y_MAX", "195")):
        monkeypatch.setenv(f"SIMPLELAY_MOTION_{name}_MM", value)
    ok = client.post("/appliances/custom_fan/mapping/preview", json=body())
    assert ok.json()["stop_park_check"]["status"] == "ok"
    outside = client.post("/appliances/custom_fan/mapping/preview", json=body(stop_px=px(295, 100)))
    assert outside.status_code == 422 and "이동 범위" in outside.json()["detail"]


def test_register_validates_explicit_stop_fields(client):
    bad = {**FAN, "stop_button": "F-09"}
    assert client.put("/appliances/custom_fan", json=bad).status_code == 422
    bad = {**FAN, "stop_button": "F-03", "stop_presses": 0}
    assert client.put("/appliances/custom_fan", json=bad).status_code == 422
    good = {**FAN, "stop_button": "F-03", "stop_presses": 3, "park_xy": [5, 5]}
    doc = client.put("/appliances/custom_fan", json=good).json()
    assert doc["stop_presses"] == 3
    assert doc["stop_park_check"]["status"] == "incomplete"  # 정지 버튼 mm가 없다


def test_verify_pass_on_the_local_mock_controller(client):
    client.put("/appliances/custom_fan", json=FAN)
    assert client.post("/appliances/custom_fan/verify-pass").status_code == 422  # 매핑 전
    client.put("/appliances/custom_fan/mapping", json=body())
    # 노드 없는 커스텀 가전은 로컬 갠트리 대상이 아니다
    res = client.post("/appliances/custom_fan/verify-pass")
    assert res.status_code == 409

    client.put("/appliances/microwave/mapping", json={
        "photo_width": 1200, "photo_height": 900, "corners_px": CORNERS,
        "buttons_px": {"BT-08": px(100, 60), "BT-05": px(250, 150)}, "stop_button": "BT-06",
        "stop_px": px(200, 150), "park_px": px(20, 185)})
    started = client.post("/appliances/microwave/verify-pass", json={"button_ids": ["BT-08", "BT-06"]})
    assert started.status_code == 202, started.text
    import time
    deadline = time.monotonic() + 5
    while True:
        doc = client.get("/appliances/microwave/verify-pass").json()
        if doc["state"] != "running":
            break
        assert time.monotonic() < deadline
        time.sleep(0.01)
    assert doc["state"] == "done" and doc["route"] == "local_mock"
    assert [(s["button"], s["status"]) for s in doc["steps"]] == [("즉석밥", "reached"), ("취소", "reached"),
                                                                  ("기다리는 자리", "reached")]


def test_y_up_gantry_maps_the_photo_bottom_left_to_origin(monkeypatch):
    """HW 담당 원본 펌웨어(10/25): 원점 좌하단, +Y 위, 음수 좌표 거절. 사진에서 짚는 순서는 그대로(왼쪽 위부터)인데
    Y만 뒤집혀야 한다 — 그렇지 않으면 위아래가 바뀐 버튼을 누른다."""
    monkeypatch.setenv("SIMPLELAY_FRAME_Y_UP", "1")
    frame = frame_config(300, 200)
    assert frame.y_up is True
    result = compute_mapping(data(frame=frame))
    # 사진 아래쪽(종전 y=150)은 바닥에서 50 mm 위 — 위로 커지는 Y
    assert result.buttons_mm["BT-05"] == pytest.approx((250, 50), abs=0.01)
    assert result.park_mm == pytest.approx((20, 15), abs=0.01)
    monkeypatch.delenv("SIMPLELAY_FRAME_Y_UP")
    assert frame_config(300, 200).y_up is False


# ── 누름 장치 칸 방식(2026-10-26) ─────────────────────────────────────────────

#: 15×115 mm 작업 영역이 사진에 옆으로 누워 있다 — 폰이 그린 칸(왼쪽 위부터 시계 방향).
STRIP = ((300.0, 400.0), (900.0, 400.0), (900.0, 500.0), (300.0, 500.0))
WORKSPACE = FrameConfig(15.0, 115.0, source="workspace", y_up=True)


def strip_data(**over):
    base = dict(photo_w=1200, photo_h=900, corners_px=STRIP, frame=WORKSPACE, orientation=(90, False))
    base.update(over)
    return MappingInput(**base)


def test_device_corner_order_covers_all_eight_orientations_and_matches_the_legacy_rule():
    from rpi.services.panel_mapping import device_corner_order, legacy_orientation
    orders = {device_corner_order(r, f) for r in (0, 90, 180, 270) for f in (False, True)}
    assert len(orders) == 8
    assert device_corner_order(*legacy_orientation(True)) == (3, 2, 1, 0)   # 원점 왼쪽 아래, +Y 위
    assert device_corner_order(*legacy_orientation(False)) == (0, 1, 2, 3)  # 원점 왼쪽 위, +Y 아래
    # 앱(deviceCornerOrder)과 같은 표 — add_appliance_wizard_test.dart가 같은 값을 본다.
    assert device_corner_order(90, False) == (0, 3, 2, 1)
    assert device_corner_order(0, True) == (2, 3, 0, 1)


def test_sideways_device_maps_with_the_chosen_orientation_and_no_mm_input():
    """돌리기 90°: 원점이 칸의 왼쪽 위, +X가 아래(15 mm), +Y가 오른쪽(115 mm). 사진 비율(6:1)과 치수 비율(15:115)이
    전혀 달라도 거절하지 않는다 — 원점·축은 사용자가 정했다."""
    result = compute_mapping(strip_data(buttons_px={"A": (600.0, 400.0), "B": (900.0, 500.0)},
                                        park_px=(300.0, 450.0)))
    assert result.buttons_mm["A"] == pytest.approx((0, 57.5), abs=0.01)
    assert result.buttons_mm["B"] == pytest.approx((15, 115), abs=0.01)
    assert result.park_mm == pytest.approx((7.5, 0), abs=0.01)
    assert result.record["orientation"] == {"rotation": 90, "flipped": False}
    # 뒤집으면 원점이 칸의 왼쪽 아래로 가고 +X는 위, +Y는 오른쪽이다(같은 칸, 거울 방향).
    flipped = compute_mapping(strip_data(orientation=(90, True),
                                         buttons_px={"A": (300.0, 500.0), "B": (300.0, 400.0)}))
    assert flipped.buttons_mm["A"] == pytest.approx((0, 0), abs=0.01)
    assert flipped.buttons_mm["B"] == pytest.approx((15, 0), abs=0.01)


def test_tap_outside_the_device_area_is_rejected_in_plain_korean():
    with pytest.raises(MappingRejected, match="누름 장치가 닿지 않는 곳") as info:
        compute_mapping(strip_data(buttons_px={"A": (960.0, 450.0)}, button_labels={"A": "시작"}))
    assert str(info.value).startswith("버튼 '시작'은 누름 장치가 닿지 않는 곳에 있어요")
    # 작은 칸에서는 여유도 작다 — 5 mm(칸 폭의 1/3)를 끝으로 당겨 받지 않는다.
    with pytest.raises(MappingRejected, match="누름 장치가 닿지 않는 곳"):
        compute_mapping(strip_data(buttons_px={"A": (600.0, 520.0)}))  # X ≈ 18 mm


def test_device_area_shape_checks_stay_but_order_rules_do_not():
    twisted = (STRIP[0], STRIP[1], STRIP[3], STRIP[2])
    with pytest.raises(MappingRejected, match="칸 모양이 꼬였어요"):
        compute_mapping(strip_data(corners_px=twisted))
    tiny = ((300.0, 400.0), (330.0, 400.0), (330.0, 420.0), (300.0, 420.0))
    with pytest.raises(MappingRejected, match="너무 작아요"):
        compute_mapping(strip_data(corners_px=tiny))
    # 시계 반대 방향·첫 귀퉁이가 왼쪽 위가 아니어도 칸 방식에서는 받는다(방향은 돌리기·뒤집기가 말한다).
    ccw = tuple(reversed(STRIP))
    assert compute_mapping(strip_data(corners_px=ccw)).version
    with pytest.raises(MappingRejected, match="범위가 본체에 아직 정해지지 않았어요"):
        compute_mapping(strip_data(frame=FrameConfig(None, None)))


def test_workspace_env_wins_over_the_old_frame_env_and_soft_limits_are_the_last_fallback():
    env = {"SIMPLELAY_WORKSPACE_W_MM": "15", "SIMPLELAY_WORKSPACE_H_MM": "115",
           "SIMPLELAY_FRAME_W_MM": "300", "SIMPLELAY_FRAME_H_MM": "200", "SIMPLELAY_FRAME_Y_UP": "1"}
    frame = frame_config(env=env)
    assert (frame.width_mm, frame.height_mm, frame.source, frame.y_up) == (15, 115, "workspace", True)
    assert frame_config(300, 200, env=env).source == "request"  # 옛 폰이 적어 보낸 크기(호환)
    old = frame_config(env={"SIMPLELAY_FRAME_W_MM": "300", "SIMPLELAY_FRAME_H_MM": "200"})
    assert (old.width_mm, old.source) == (300, "env")
    limits = frame_config(env={"SIMPLELAY_MOTION_X_MIN_MM": "2", "SIMPLELAY_MOTION_X_MAX_MM": "17",
                               "SIMPLELAY_MOTION_Y_MIN_MM": "0", "SIMPLELAY_MOTION_Y_MAX_MM": "115"})
    assert (limits.width_mm, limits.height_mm, limits.origin_x_mm, limits.source) == (15, 115, 2, "soft_limits")
    assert frame_config(env={}).source == "none"


def test_api_maps_with_the_workspace_and_orientation_without_any_mm_input(client, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_FRAME_W_MM")
    monkeypatch.delenv("SIMPLELAY_FRAME_H_MM")
    monkeypatch.setenv("SIMPLELAY_WORKSPACE_W_MM", "15")
    monkeypatch.setenv("SIMPLELAY_WORKSPACE_H_MM", "115")
    monkeypatch.setenv("SIMPLELAY_FRAME_Y_UP", "1")
    frame = client.get("/mapping/frame").json()
    assert frame["workspace"] == {"w_mm": 15, "h_mm": 115, "origin_x_mm": 0, "origin_y_mm": 0, "y_up": True,
                                  "source": "workspace"}
    client.put("/appliances/custom_fan", json=FAN)
    req = {"photo_width": 1200, "photo_height": 900, "corners_px": [list(c) for c in STRIP],
           "orientation": {"rotation": 90, "flipped": False},
           "buttons_px": {"F-01": [600, 400], "F-02": [750, 450]},
           "stop_button": "F-03", "stop_px": [880, 450], "park_px": [320, 450]}
    res = client.put("/appliances/custom_fan/mapping", json=req)
    assert res.status_code == 200, res.text
    doc = res.json()
    assert doc["buttons_mm"]["F-01"] == pytest.approx([0, 57.5], abs=0.01)
    assert doc["appliance"]["panel_mapping"]["orientation"] == {"rotation": 90, "flipped": False}
    outside = client.post("/appliances/custom_fan/mapping/preview",
                          json={**req, "buttons_px": {"F-01": [960, 450]}})
    assert outside.status_code == 422 and "누름 장치가 닿지 않는 곳" in outside.json()["detail"]
    bad = client.post("/appliances/custom_fan/mapping/preview", json={**req, "orientation": {"rotation": 45}})
    assert bad.status_code == 422
    # 옛 폰(크기를 적어 보냄)도 그대로 된다.
    legacy = client.post("/appliances/custom_fan/mapping/preview", json={**body(), "frame_w_mm": 300, "frame_h_mm": 200})
    assert legacy.status_code == 200, legacy.text
