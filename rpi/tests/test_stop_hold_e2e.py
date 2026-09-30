"""정지 대기·보관 끝단 — API(사진 매핑 저장 → 확인 주행 → 실행 → /stop → /status·/twin).

SimulatorController(실제 ActClient ↔ ActExecutor, 모의 모터·모의 가전)로 돈다. 실물 미검증.
"""

from __future__ import annotations

import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.services.link_tap import LinkFrameTap

H = np.array([[2.1, 0.3, 150.0], [0.1, 2.4, 90.0], [0.0004, 0.0006, 1.0]])


def px(x_mm, y_mm):
    u, v, w = H @ np.array([x_mm, y_mm, 1.0])
    return [float(u / w), float(v / w)]


MAPPING = {
    "photo_width": 1200, "photo_height": 900, "frame_w_mm": 300, "frame_h_mm": 200,
    "corners_px": [px(0, 0), px(300, 0), px(300, 200), px(0, 200)],
    "buttons_px": {"BT-08": px(100, 60), "BT-05": px(250, 150)},
    "stop_button": "BT-06", "stop_px": px(200, 150), "stop_presses": 2, "park_px": px(20, 185),
}


@pytest.fixture
def sim(tmp_path, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_HOLD_STOP_CONFIRM_S", "0.3")
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.simulator_controller import SimulatorController

    def make(**env):
        for key, value in env.items():
            monkeypatch.setenv(key, value)
        for dep in (deps.get_appliance_registry, deps.get_service):
            dep.cache_clear()
        registry = deps.get_appliance_registry()
        tap = LinkFrameTap(None, transport="in_memory")
        controller = SimulatorController(step_seconds=0, tap=tap)
        service = SimpleLayService(RuleBasedIntentResolver(), controller, appliance_registry=registry)
        app.dependency_overrides[deps.get_service] = lambda: service
        made.append(controller)
        return TestClient(app), controller

    made = []
    yield make
    from rpi.main import app
    app.dependency_overrides.pop(deps.get_service, None)
    for controller in made:
        controller.close()
    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()


def _until(c, pred, timeout=6.0):
    deadline = time.monotonic() + timeout
    while True:
        status = c.get("/status").json()
        if pred(status):
            return status
        assert time.monotonic() < deadline, status
        time.sleep(0.02)


def _map_and_run(c):
    res = c.put("/appliances/microwave/mapping", json=MAPPING)
    assert res.status_code == 200, res.text
    job = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"}).json()
    return _until(c, lambda s: s["last_job_id"] == job["job_id"] and not s["running"]
                  and s["hold_state"] == "hovering_stop" and "기다리는 중" in (s["hold_detail"] or ""))


def test_verify_pass_then_run_hover_stop_confirmed_and_park(sim):
    c, controller = sim()
    assert c.put("/appliances/microwave/mapping", json=MAPPING).status_code == 200
    assert c.post("/appliances/microwave/verify-pass").status_code == 202
    deadline = time.monotonic() + 5
    while (doc := c.get("/appliances/microwave/verify-pass").json())["state"] == "running":
        assert time.monotonic() < deadline
        time.sleep(0.02)
    assert doc["state"] == "done" and doc["route"] == "act_link" and doc["execution_mode"] == "mock"
    assert [s["status"] for s in doc["steps"]] == ["reached"] * 4  # 버튼 3 + 보관 위치
    assert controller.hold_hardware.motion.presses() == []  # 확인 주행은 누르지 않는다

    status = _map_and_run(c)
    assert status["hold_appliance_id"] == "microwave" and status["hold_stop_button"] == "취소"
    assert status["hold_execution_mode"] == "mock"
    twin = c.get("/twin/state").json()
    assert twin["hold"]["stop"] == pytest.approx({"x_mm": 200, "y_mm": 150}, abs=0.01)
    assert twin["hold"]["park"] == pytest.approx({"x_mm": 20, "y_mm": 185}, abs=0.01)

    stop = c.post("/stop").json()
    assert stop["was_running"] is False
    assert stop["appliance_stop_requested"] is True and stop["hold_state_at_request"] == "hovering_stop"
    status = _until(c, lambda s: s["hold_state"] == "parked")
    assert status["hold_stop_outcome"] == "stopped"
    assert controller.hold_hardware.motion.presses() == ["취소", "취소"]
    assert c.get("/twin/state").json()["hold"]["hold_state"] == "parked"


def test_appliance_that_ignores_stop_is_reported_unconfirmed(sim):
    c, controller = sim(SIMPLELAY_HOLD_MOCK_STOP="ignore")
    _map_and_run(c)
    c.post("/stop")
    status = _until(c, lambda s: s["hold_stop_outcome"] == "requested_unconfirmed")
    assert status["hold_state"] == "hovering_stop" and "정지 요청함·미확인" in status["hold_detail"]
    assert controller.hold_hardware.motion.presses() == ["취소", "취소"]


def test_finished_appliance_parks_without_a_stop(sim):
    c, controller = sim(SIMPLELAY_HOLD_MOCK_RUN_S="0.4")
    res = c.put("/appliances/microwave/mapping", json=MAPPING)
    assert res.status_code == 200
    c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
    status = _until(c, lambda s: s["hold_state"] == "parked")
    assert status["hold_stop_outcome"] is None and "끝나" in status["hold_detail"]
    assert controller.hold_hardware.motion.presses() == []


def test_no_stop_or_park_registered_means_no_hover(sim):
    c, _ = sim()
    job = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"}).json()
    status = _until(c, lambda s: s["last_job_id"] == job["job_id"] and not s["running"])
    time.sleep(0.1)
    assert c.get("/status").json()["hold_state"] is None
    assert c.post("/stop").json()["appliance_stop_requested"] is False
