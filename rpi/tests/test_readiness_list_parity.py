"""가전 목록(GET /appliances)과 GET /readiness/{id}가 같은 대상·같은 조건에서 같은 판정을 내는가(2026-10-13).

폰은 두 응답을 모두 본다. 한쪽만 '실행 가능'이면 화면이 근거 없이 긍정한다.
고치기 전: 노드가 끊긴 내장 가전이 /readiness에서 can_execute=true·빈 사유, 비상정지 걸림 사유도 빠졌다.
모의·로컬 대상의 정상 경로(실행 가능·실행 200)는 막지 않는다.
"""

import time

import pytest

from rpi.controller import ExecutionMode


@pytest.fixture()
def client(monkeypatch):
    import rpi.api.deps as deps
    from fastapi.testclient import TestClient
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "simulator")  # 내장 가전을 목록에 보인다
    caches = (deps.get_appliance_registry, deps.get_node_registry,
              deps.get_readiness_registry, deps.get_service)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    app.dependency_overrides.clear()
    for dep in caches:
        dep.cache_clear()


def _pair(client, appliance_id):
    row = next(a for a in client.get("/appliances").json() if a["id"] == appliance_id)
    r = client.get(f"/readiness/{appliance_id}").json()
    return ((row["readiness"], row["can_execute"], row["readiness_reasons"]),
            (r["state"], r["can_execute"], r["reasons"]))


def test_local_mock_builtin_is_operable_in_both_and_still_executes(client):
    listed, single = _pair(client, "microwave")
    assert listed == ("operable", True, [])
    assert single == listed
    res = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert res.status_code == 200
    job_id = res.json()["job_id"]
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:  # 다음 시험에 실행 중 작업을 남기지 않는다
        s = client.get("/status").json()
        if not s["running"] and s.get("last_job_id") == job_id:
            break
        time.sleep(0.05)


def test_disconnected_node_is_not_executable_in_readiness_either(client):
    """노드가 등록됐지만 아직 보고가 없다 — 실행은 그 노드로 간다. 로컬 대상이라고 긍정하지 않는다."""
    client.post("/nodes/microwave", json={"base_url": "http://node.local"})
    listed, single = _pair(client, "microwave")
    assert listed[1] is False and listed[2], listed
    assert single == listed


def test_custom_node_unverified_matches(client):
    client.put("/appliances/fan", json={"name": "선풍기", "rows": 1, "cols": 1,
                                         "buttons": [{"id": "F-01", "label": "전원", "x": 0, "y": 0}]})
    client.post("/nodes/fan", json={"base_url": "http://node.local"})
    listed, single = _pair(client, "fan")
    assert listed[1] is False
    assert single == listed


def test_estop_block_reason_appears_in_readiness_too(client):
    import rpi.api.deps as deps
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver

    class _Latched:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons, targets=None):
            raise AssertionError("must not run while latched")

        def estop_status(self):
            return {"latched": True, "detail": "걸림", "known": True, "link_up": True}

        def request_stop(self):
            pass

    service = SimpleLayService(RuleBasedIntentResolver(), _Latched(),
                               appliance_registry=deps.get_appliance_registry())
    from rpi.main import app
    app.dependency_overrides[deps.get_service] = lambda: service
    listed, single = _pair(client, "microwave")
    assert listed[0] == "needs_setup" and listed[1] is False and listed[2], listed
    assert single == listed
    res = client.post("/execute-buttons", json={"buttons": ["즉석밥"], "appliance_id": "microwave"})
    assert res.status_code == 412


def test_fully_ready_node_is_operable_in_both(client):
    client.put("/appliances/fan", json={"name": "선풍기", "rows": 1, "cols": 1,
                                         "buttons": [{"id": "F-01", "label": "전원", "x": 0, "y": 0}]})
    client.post("/nodes/fan", json={"base_url": "http://node.local"})
    client.post("/readiness/fan", json={"transport": True, "motion": True, "sensor": True,
                                        "calibration": True,
                                        "calibration_profile_version": "fan-cal-1"})
    listed, single = _pair(client, "fan")
    assert listed == ("operable", True, [])
    assert single == listed
