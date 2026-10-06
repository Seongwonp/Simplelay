"""시연 v3 갭 M3 — 전부 모의 등급(시뮬레이터)에서도 화면 정지 → 정지 버튼 위 대기 → 보관이 보인다.

정지 버튼 mm·보관 위치가 없는 가전이라도 **정지 버튼이 등록돼 있으면** 시뮬레이터는 모의 위치로
대기 계획을 만든다. 실물 좌표가 아니므로 정지 판정을 지어내지 않는다 — 모의 가전은 정지 버튼에
반응하지 않고(전력 하강 흉내 없음) 결과는 '정지 요청함·미확인'이다. UART·실물 경로는 그대로다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.services.link_tap import LinkFrameTap

HOME_MW = {
    "name": "전자레인지", "category": "microwave", "rows": 2, "cols": 2,
    "buttons": [
        {"id": "b1", "label": "즉석밥", "x": 0, "y": 0},
        {"id": "b2", "label": "시작", "x": 1, "y": 0},
        {"id": "b3", "label": "취소", "x": 0, "y": 1},
    ],
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
        controller = SimulatorController(step_seconds=0, tap=LinkFrameTap(None, transport="in_memory"))
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


def _register(c, **extra):
    res = c.put("/appliances/home_mw", json={**HOME_MW, **extra})
    assert res.status_code == 200, res.text


def _run(c, appliance_id="home_mw"):
    job = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": appliance_id}).json()
    return job


def test_stop_button_without_mm_holds_at_mock_position_then_parks_unconfirmed(sim):
    c, controller = sim(SIMPLELAY_HOLD_MOCK_RUN_S="1.0")
    _register(c, stop_button="b3", stop_presses=1)  # mm·보관 위치 없음
    _run(c)
    status = _until(c, lambda s: s["hold_state"] == "hovering_stop" and "기다리는 중" in (s["hold_detail"] or ""))
    assert status["hold_execution_mode"] == "mock"
    assert status["hold_position_source"] == "mock"
    assert status["hold_stop_button"] == "취소" and status["hold_appliance_id"] == "home_mw"
    assert status["hold_unavailable_reason"] is None
    twin = c.get("/twin/state").json()
    assert twin["hold"]["hold_state"] == "hovering_stop"

    stop = c.post("/stop").json()
    assert stop["appliance_stop_requested"] is True and stop["hold_state_at_request"] == "hovering_stop"
    status = _until(c, lambda s: s["hold_stop_outcome"] == "requested_unconfirmed")
    assert "정지 요청함·미확인" in status["hold_detail"]
    assert controller.hold_hardware.motion.presses() == ["취소"]
    # 모의 가전 시간이 끝나면 보관 위치로 — 결과는 끝까지 '미확인'(정지됨을 지어내지 않는다).
    status = _until(c, lambda s: s["hold_state"] == "parked")
    assert status["hold_stop_outcome"] == "requested_unconfirmed"
    assert status["hold_position_source"] == "mock" and status["hold_probe_source"] == "mock"


def test_mock_hold_never_reports_a_confirmed_stop(sim):
    """정지 버튼에 반응하는 모의 가전 설정(honor)이어도 모의 위치 대기는 정지됨을 말하지 않는다."""
    c, _ = sim(SIMPLELAY_HOLD_MOCK_STOP="honor", SIMPLELAY_HOLD_MOCK_RUN_S="1.0")
    _register(c, stop_button="b3", stop_presses=2)
    _run(c)
    _until(c, lambda s: s["hold_state"] == "hovering_stop" and "기다리는 중" in (s["hold_detail"] or ""))
    c.post("/stop")
    seen = []
    deadline = time.monotonic() + 6
    while True:
        s = c.get("/status").json()
        seen.append(s["hold_stop_outcome"])
        if s["hold_state"] == "parked":
            break
        assert time.monotonic() < deadline, s
        time.sleep(0.02)
    assert "stopped" not in seen
    assert s["hold_stop_outcome"] == "requested_unconfirmed"


def test_appliance_without_stop_button_keeps_hold_null_with_reason(sim):
    c, controller = sim()
    _register(c)  # 정지 버튼 없음
    job = _run(c)
    status = _until(c, lambda s: s["last_job_id"] == job["job_id"] and not s["running"])
    time.sleep(0.1)
    status = c.get("/status").json()
    assert status["hold_state"] is None
    assert status["hold_unavailable_reason"] == "no_stop_button"
    assert "정지 버튼" in (status["hold_detail"] or "")
    assert c.post("/stop").json()["appliance_stop_requested"] is False
    assert controller.hold_hardware.motion.log == []


def test_calibrated_mapping_keeps_registered_positions(sim):
    """사진 매핑으로 mm가 있으면 종전 계획 그대로(위치 출처 calibrated)."""
    from rpi.tests.test_stop_hold_e2e import MAPPING

    c, _ = sim()
    assert c.put("/appliances/microwave/mapping", json=MAPPING).status_code == 200
    c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
    status = _until(c, lambda s: s["hold_state"] == "hovering_stop")
    assert status["hold_position_source"] == "calibrated"
    assert c.get("/twin/state").json()["hold"]["stop"] == pytest.approx({"x_mm": 200, "y_mm": 150}, abs=0.01)


def test_real_link_paths_do_not_get_mock_positions():
    """UART·실물 경로(hold_plan_for)는 바뀌지 않는다 — mm가 없으면 계획 없음."""
    from rpi.services.appliance_registry import ApplianceRegistry
    from rpi.services.stop_park import hold_plan_for, simulated_hold_plan

    registry = ApplianceRegistry()
    assert hold_plan_for(registry, "microwave") is None
    plan, reason = simulated_hold_plan(registry, "microwave")
    assert plan is None and reason == "no_stop_button"


def test_act_client_controller_is_not_a_simulated_hold_target():
    from rpi.services.act_client_controller import ActClientController
    from rpi.services.simulator_controller import SimulatorController

    assert getattr(ActClientController, "simulates_stop_hold", False) is False
    assert SimulatorController.simulates_stop_hold is True
