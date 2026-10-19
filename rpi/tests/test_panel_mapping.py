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
    ([[100, 100], [1100, 100], [1100, 150], [100, 150]], "비율"),
    ([CORNERS[0], CORNERS[1], CORNERS[2], [-5, 500]], "사진 밖"),
])
def test_wrong_or_degenerate_corners_are_rejected_in_plain_korean(corners, message):
    with pytest.raises(MappingRejected, match=message):
        compute_mapping(data(corners_px=tuple(tuple(c) for c in corners)))


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
