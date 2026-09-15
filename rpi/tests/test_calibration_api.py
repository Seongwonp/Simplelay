"""캘리브레이션 저장 API — 기준점 → 변환 → 버튼 mm, 검증 실패 시 아무것도 저장하지 않는다."""

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.services.persistence import SimpleLayDb


def _point(sx, sy):
    # 알려진 변환: x_mm = 0.5·sx + 10, y_mm = 0.5·sy + 20
    return {"source": [sx, sy], "target": [0.5 * sx + 10, 0.5 * sy + 20]}


GOOD_POINTS = [_point(0, 0), _point(200, 0), _point(0, 300), _point(200, 300)]

FAN = {
    "name": "거실 선풍기",
    "rows": 1,
    "cols": 3,
    "buttons": [
        {"id": "F-01", "label": "전원", "x": 0, "y": 0},
        {"id": "F-02", "label": "약풍", "x": 1, "y": 0},
        {"id": "F-03", "label": "강풍", "x": 2, "y": 0},
    ],
}


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    caches = (deps.get_appliance_registry, deps.get_service)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def test_builtin_microwave_gets_mm_coordinates(client) -> None:
    res = client.put(
        "/appliances/microwave/calibration",
        json={"points": GOOD_POINTS, "button_centers": {"BT-05": [100, 200], "BT-06": [40, 60]}},
    )

    assert res.status_code == 200, res.text
    body = res.json()
    assert len(body["version"]) == 12
    assert body["kind"] == "affine"
    assert body["point_count"] == 4 and body["redundant_points"] == 1
    assert body["rms_error_mm"] < 1e-6
    start = next(b for b in body["appliance"]["buttons"] if b["id"] == "BT-05")
    assert start["x_mm"] == pytest.approx(60.0) and start["y_mm"] == pytest.approx(120.0)
    assert "BT-01" in body["unmapped_buttons"]

    listed = next(a for a in client.get("/appliances").json() if a["id"] == "microwave")
    assert listed["calibration_version"] == body["version"]


def test_custom_calibration_replaces_all_mm_and_bumps_revision(client) -> None:
    saved = client.put("/appliances/custom_fan", json=FAN).json()

    res = client.put(
        "/appliances/custom_fan/calibration",
        json={
            "expected_revision": saved["revision"],
            "points": GOOD_POINTS,
            "button_centers": {"F-01": [20, 40], "F-02": [60, 40]},
        },
    )

    assert res.status_code == 200, res.text
    appliance = res.json()["appliance"]
    assert appliance["revision"] == saved["revision"] + 1
    by_id = {b["id"]: b for b in appliance["buttons"]}
    assert by_id["F-01"]["x_mm"] == pytest.approx(20.0)
    assert by_id["F-03"]["x_mm"] is None  # 이번 보정에 없는 버튼은 비운다
    assert res.json()["unmapped_buttons"] == ["F-03"]


def test_stale_revision_is_a_conflict_and_saves_nothing(client) -> None:
    client.put("/appliances/custom_fan", json=FAN)

    res = client.put(
        "/appliances/custom_fan/calibration",
        json={"expected_revision": 99, "points": GOOD_POINTS, "button_centers": {"F-01": [0, 0]}},
    )

    assert res.status_code == 409
    listed = next(a for a in client.get("/appliances").json() if a["id"] == "custom_fan")
    assert listed["calibration_version"] is None


@pytest.mark.parametrize(
    ("payload", "needle"),
    [
        ({"points": [_point(0, 0), _point(10, 10), _point(20, 20)], "button_centers": {"BT-05": [5, 5]}}, ""),
        ({"points": GOOD_POINTS, "button_centers": {"NOPE": [1, 1]}}, "없는 버튼"),
        (
            {
                "points": GOOD_POINTS[:3] + [{"source": [200, 300], "target": [200.0, 300.0]}],
                "button_centers": {"BT-05": [1, 1]},
            },
            "기준점",
        ),
        ({"points": GOOD_POINTS, "button_centers": {"BT-05": [5000, 5000]}}, "프레임"),
        ({"points": GOOD_POINTS[:2], "button_centers": {"BT-05": [1, 1]}}, ""),
        ({"points": GOOD_POINTS, "kind": "polynomial", "button_centers": {"BT-05": [1, 1]}}, ""),
    ],
)
def test_rejected_calibration_saves_nothing(client, payload, needle) -> None:
    res = client.put("/appliances/microwave/calibration", json=payload)

    assert res.status_code == 422
    if needle:
        assert needle in str(res.json()["detail"])
    listed = next(a for a in client.get("/appliances").json() if a["id"] == "microwave")
    assert listed["calibration_version"] is None


def test_unknown_appliance_is_404(client) -> None:
    res = client.put(
        "/appliances/ghost/calibration",
        json={"points": GOOD_POINTS, "button_centers": {"X": [1, 1]}},
    )
    assert res.status_code == 404


def test_builtin_calibration_survives_restart(tmp_path) -> None:
    path = str(tmp_path / "cal.db")
    ApplianceRegistry(store=SimpleLayDb(path)).apply_calibration(
        "microwave", version="abcdef123456", coords={"BT-05": (60.0, 120.0)}
    )

    reloaded = ApplianceRegistry(store=SimpleLayDb(path)).get("microwave")

    assert reloaded.calibration_version == "abcdef123456"
    start = next(b for b in reloaded.buttons if b.id == "BT-05")
    assert (start.x_mm, start.y_mm) == (60.0, 120.0)
