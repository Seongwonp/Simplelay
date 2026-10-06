import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from rpi.controller import ExecutionMode
from rpi.services.simulator_controller import SimulatorController


def test_persistent_link_retains_mock_provenance_and_does_not_exhaust_verifier():
    controller = SimulatorController(step_seconds=0)
    try:
        assert controller.execution_mode == ExecutionMode.MOCK
        for _ in range(205):
            controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
            assert controller.execute(['start']).status.value == 'succeeded'
        snapshot = controller.snapshot()
        assert snapshot['act_local']['presses'] == ['start']
        assert len(snapshot['frames']) == 400  # bounded trace (raised from 80 so long retries keep the execute frame)
        assert {f['direction'] for f in snapshot['frames']} == {'hub_to_act', 'act_to_hub'}
    finally:
        controller.close()
    controller.close()
    assert not controller._thread.is_alive()
    with pytest.raises(RuntimeError):
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        controller.execute(['start'])


def test_failure_injection_travels_over_link_and_can_be_cleared():
    controller = SimulatorController(step_seconds=0)
    try:
        controller.inject_failure(0, 2)
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        assert controller.execute(['start']).status.value == 'succeeded'
        assert len(controller.snapshot()['act_local']['presses']) == 3
        controller.inject_failure(0, 3)
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        assert controller.execute(['start']).status.value == 'safety_stopped'
        controller.clear_failure()
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        assert controller.execute(['start']).status.value == 'succeeded'
        assert controller.snapshot()['act_local']['presses'] == ['start']
    finally:
        controller.close()


def test_stop_crosses_protocol_and_prevents_second_button():
    controller = SimulatorController(step_seconds=0.3)
    try:
        with ThreadPoolExecutor() as pool:
            controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
            future = pool.submit(controller.execute, ['first', 'second'])
            deadline = time.monotonic() + 3
            while not controller.snapshot()['act_local']['presses']:
                assert time.monotonic() < deadline
                time.sleep(0.005)
            controller.request_stop()
            future.result(3)
        assert controller.snapshot()['act_local']['presses'] == ['first']
        assert controller.snapshot()['act_local']['status'] == 'safety_stopped'
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        assert controller.execute(['next']).status.value == 'succeeded'
    finally:
        controller.close()


def test_panel_is_unavailable_for_non_simulator_controller():
    from types import SimpleNamespace
    from fastapi import HTTPException
    from rpi.api.simulator_router import require_simulator
    with pytest.raises(HTTPException) as exc:
        require_simulator(SimpleNamespace(_controller=object()))
    assert exc.value.status_code == 404


def test_api_execution_uses_same_simulated_link():
    from fastapi.testclient import TestClient
    from rpi.api.deps import get_service
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    controller = SimulatorController(step_seconds=0)
    service = SimpleLayService(RuleBasedIntentResolver(), controller)
    app.dependency_overrides[get_service] = lambda: service
    try:
        client = TestClient(app)
        assert client.get('/simulator').status_code == 200
        response = client.post('/execute-buttons', json={'buttons': ['start']})
        assert response.status_code == 200
        job = response.json()['job_id']
        deadline = time.monotonic() + 3
        while True:
            status = client.get('/status').json()
            if status['last_job_id'] == job and not status['running']:
                break
            assert time.monotonic() < deadline
            time.sleep(0.005)
        assert status['last_execution_mode'] == 'mock'
        assert status['last_status'] == 'succeeded'
        assert client.get('/simulator/state').json()['act_local']['presses'] == ['start']
    finally:
        app.dependency_overrides.pop(get_service, None)
        controller.close()
