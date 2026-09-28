"""디지털 트윈(개념 모션) 화면 라우트와 읽기 전용 상태 요약."""
import time
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.simulator_router import router, require_simulator
from rpi.services.twin_view import attribute_presses, build_twin_state


def _frame(direction, **message):
    return {"direction": direction, "message": message}


def _snapshot(frames, presses=(), status=None, running=False):
    return {"execution_mode": "mock", "transport": "in_memory", "running": running,
            "frames": list(frames),
            "act_local": {"status": status, "presses": list(presses), "note": ""}}


def test_no_execute_frame_means_no_job():
    state = build_twin_state(_snapshot([_frame("hub_to_act", type="clear_failure")]))
    assert state["job"] is None
    assert state["execution_mode"] == "mock"


def test_result_only_from_matching_result_frame():
    frames = [_frame("hub_to_act", type="execute", sequence_id="a", buttons=["즉석밥", "시작"])]
    running = build_twin_state(_snapshot(frames, ["즉석밥"], running=True))
    assert running["job"]["result"] is None
    assert running["job"]["press_log"] == [
        {"n": 0, "label": "즉석밥", "step_index": 0, "attempt": 1}]
    # 다른 시퀀스의 result는 이 실행의 결과가 아니다.
    other = frames + [_frame("act_to_hub", type="result", sequence_id="zzz", success=True, retry=0)]
    assert build_twin_state(_snapshot(other, ["즉석밥"], running=True))["job"]["result"] is None
    done = frames + [_frame("act_to_hub", type="result", sequence_id="a", success=False, retry=2)]
    job = build_twin_state(_snapshot(done, ["즉석밥"] * 3, status="safety_stopped"))["job"]
    assert job["result"] == {"success": False, "retry": 2}
    assert job["steps"][0]["attempts"] == 3 and job["steps"][1]["attempts"] == 0
    assert job["abort_requested"] is False


def test_abort_frame_is_reported_and_stale_presses_are_not_attached():
    frames = [_frame("hub_to_act", type="execute", sequence_id="a", buttons=["30초"]),
              _frame("act_to_hub", type="result", sequence_id="a", success=True, retry=0),
              _frame("hub_to_act", type="execute", sequence_id="b", buttons=["즉석밥", "시작"]),
              _frame("hub_to_act", type="abort")]
    # 새 실행이 아직 시작 전이면 이전 실행 결과(status)와 누름 기록이 남아 있다.
    job = build_twin_state(_snapshot(frames, ["30초"], status="succeeded", running=True))["job"]
    assert job["sequence_id"] == "b"
    assert job["abort_requested"] is True
    assert job["presses"] == [] and job["act_local_status"] is None


def test_attribution_retry_next_ambiguous_and_mismatch():
    r = attribute_presses(["즉석밥", "시작"], ["즉석밥", "즉석밥", "시작"])
    assert [s["attempts"] for s in r["steps"]] == [2, 1]
    assert r["attribution"] == "sequential"
    assert r["press_log"][1]["attempt"] == 2
    amb = attribute_presses(["10초", "10초", "시작"], ["10초", "10초", "시작"])
    assert [s["attempts"] for s in amb["steps"]] == [1, 1, 1]
    assert amb["attribution"] == "ambiguous"
    bad = attribute_presses(["즉석밥"], ["라면", "즉석밥"])
    assert bad["attribution"] == "mismatch"
    assert all(p["step_index"] is None for p in bad["press_log"])


@pytest.fixture
def client():
    from rpi.services.simulator_controller import SimulatorController  # noqa: F401
    app = FastAPI()
    app.include_router(router)
    controller = SimpleNamespace(snapshot=lambda: _snapshot(
        [_frame("hub_to_act", type="execute", sequence_id="x", buttons=["시작"])], ["시작"], running=True))
    app.dependency_overrides[require_simulator] = lambda: controller
    return TestClient(app)


def test_twin_page_script_and_state_routes(client):
    page = client.get('/simulator/twin')
    assert page.status_code == 200
    assert 'id="twinCanvas"' in page.text
    assert '개념 모션 · 실제 동역학 아님' in page.text
    assert '/simulator/parking' in page.text
    script = client.get('/simulator/twin-motion.js')
    assert script.status_code == 200
    assert script.headers['content-type'].startswith('text/javascript')
    assert 'createEngine' in script.text
    state = client.get('/simulator/twin/state').json()
    assert state['job']['press_log'][0]['label'] == '시작'


def test_twin_routes_are_404_without_simulator_controller():
    from rpi.api.deps import get_service
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_service] = lambda: SimpleNamespace(_controller=object())
    c = TestClient(app)
    for path in ('/simulator/twin', '/simulator/twin/state', '/simulator/twin-motion.js'):
        assert c.get(path).status_code == 404, path


def test_twin_state_follows_real_simulator_execution_retry_and_stop():
    from rpi.api.deps import get_service
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.simulator_controller import SimulatorController
    controller = SimulatorController(step_seconds=0)
    service = SimpleLayService(RuleBasedIntentResolver(), controller)
    app.dependency_overrides[get_service] = lambda: service
    try:
        c = TestClient(app)
        assert c.get('/simulator/twin').status_code == 200
        controller.inject_failure(0, 2)
        job = c.post('/execute-buttons', json={'buttons': ['즉석밥', '시작'], 'appliance_id': 'microwave'}).json()['job_id']
        deadline = time.monotonic() + 3
        while True:
            status = c.get('/status').json()
            if status['last_job_id'] == job and not status['running']:
                break
            assert time.monotonic() < deadline
            time.sleep(0.005)
        twin = c.get('/simulator/twin/state').json()
        assert twin['execution_mode'] == 'mock'
        assert twin['job']['buttons'] == ['즉석밥', '시작']
        assert twin['job']['result'] == {'success': True, 'retry': 2}
        assert [s['attempts'] for s in twin['job']['steps']] == [3, 1]
    finally:
        app.dependency_overrides.pop(get_service, None)
        controller.close()

    slow = SimulatorController(step_seconds=0.3)
    try:
        with ThreadPoolExecutor() as pool:
            future = pool.submit(slow.execute, ['즉석밥', '시작'])
            deadline = time.monotonic() + 3
            while not build_twin_state(slow.snapshot())['job'] or not build_twin_state(slow.snapshot())['job']['presses']:
                assert time.monotonic() < deadline
                time.sleep(0.005)
            slow.request_stop()
            future.result(3)
        job = build_twin_state(slow.snapshot())['job']
        assert job['abort_requested'] is True
        assert job['result']['success'] is False
        assert job['presses'] == ['즉석밥']
    finally:
        slow.close()
