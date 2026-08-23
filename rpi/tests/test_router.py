"""FastAPI 라우터 통합 테스트 — 하드웨어 없이 mock으로 동작."""
import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import (
    get_alert_store,
    get_demo_failure_state,
    get_job_history,
    get_node_registry,
    get_presence_store,
    get_service,
    get_suggestion_service,
)
from rpi.main import app

_SINGLETONS = (
    get_service,
    get_suggestion_service,
    get_alert_store,
    get_node_registry,
    get_demo_failure_state,
    get_job_history,
    get_presence_store,
)


@pytest.fixture(autouse=True)
def reset_singletons():
    """각 테스트마다 서비스 싱글톤을 초기화해 상태 오염 방지."""
    for dep in _SINGLETONS:
        dep.cache_clear()
    yield
    for dep in _SINGLETONS:
        dep.cache_clear()


@pytest.fixture()
def client():
    return TestClient(app)


def _wait_job_done(client, job_id, timeout=2.0):
    """job 모델: 백그라운드 실행이 끝나 last_job_id가 내 job_id가 될 때까지
    /status를 폴링한다 — 실제 클라이언트(폰·키오스크)와 같은 계약."""
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish within {timeout}s")


# ── /execute ──────────────────────────────────────────────────────────────────

def test_execute_known_purpose_succeeds(client):
    response = client.post("/execute", json={"text": "우유 데워줘"})
    assert response.status_code == 200
    body = response.json()
    # job 모델: 즉시 접수 응답, 결과는 /status 폴링 + job_id 대조로
    assert body["status"] == "accepted"
    assert body["job_id"]

    status = _wait_job_done(client, body["job_id"])
    assert status["last_status"] == "succeeded"
    assert len(status["last_buttons"]) == 3
    assert all(step["success"] for step in status["last_buttons"])


def test_execute_unknown_purpose_returns_422(client):
    response = client.post("/execute", json={"text": "알 수 없는 명령"})
    assert response.status_code == 422


def test_execute_blank_text_returns_422(client):
    response = client.post("/execute", json={"text": "   "})
    assert response.status_code == 422


def test_execute_concurrent_returns_409(client):
    import threading
    from rpi.api.deps import get_service
    svc = get_service()
    svc._running = True
    try:
        response = client.post("/execute", json={"text": "우유 데워줘"})
        assert response.status_code == 409
    finally:
        svc._running = False


# ── /execute-buttons (의도 해석 우회, 사용자 정의 가전용) ──────────────────────

def test_execute_buttons_succeeds(client):
    response = client.post("/execute-buttons", json={"buttons": ["커스텀A", "커스텀B"]})
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "accepted"

    status = _wait_job_done(client, body["job_id"])
    assert status["last_status"] == "succeeded"
    assert [step["button"] for step in status["last_buttons"]] == ["커스텀A", "커스텀B"]


def test_execute_buttons_empty_list_returns_422(client):
    response = client.post("/execute-buttons", json={"buttons": []})
    assert response.status_code == 422


def test_execute_buttons_blank_only_returns_422(client):
    response = client.post("/execute-buttons", json={"buttons": ["   "]})
    assert response.status_code == 422


def test_execute_buttons_concurrent_returns_409(client):
    from rpi.api.deps import get_service
    svc = get_service()
    svc._running = True
    try:
        response = client.post("/execute-buttons", json={"buttons": ["버튼"]})
        assert response.status_code == 409
    finally:
        svc._running = False


# ── /execute-for-appliance (커스텀 가전 음성 명령, LLM 기반) ────────────────────

def test_execute_for_appliance_without_llm_configured_returns_503(client):
    response = client.post(
        "/execute-for-appliance",
        json={"text": "해동해줘", "known_buttons": ["해동", "시작"]},
    )
    assert response.status_code == 503


def test_execute_for_appliance_succeeds_with_configured_llm(client):
    from rpi.intent.mock import MockLlmClient

    svc = get_service()
    svc._llm_client = MockLlmClient({"해동해줘": '{"sequence": ["해동", "시작"]}'})
    response = client.post(
        "/execute-for-appliance",
        json={"text": "해동해줘", "known_buttons": ["해동", "시작", "취소"]},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "accepted"

    status = _wait_job_done(client, body["job_id"])
    assert status["last_status"] == "succeeded"
    assert [step["button"] for step in status["last_buttons"]] == ["해동", "시작"]


def test_execute_for_appliance_empty_known_buttons_returns_422(client):
    response = client.post(
        "/execute-for-appliance", json={"text": "해동해줘", "known_buttons": []}
    )
    assert response.status_code == 422


def test_execute_for_appliance_blank_text_returns_422(client):
    response = client.post(
        "/execute-for-appliance", json={"text": "   ", "known_buttons": ["해동"]}
    )
    assert response.status_code == 422


def test_execute_for_appliance_unmatched_purpose_returns_422(client):
    from rpi.intent.mock import MockLlmClient

    svc = get_service()
    svc._llm_client = MockLlmClient({"이상한말": '{"sequence": []}'})
    response = client.post(
        "/execute-for-appliance",
        json={"text": "이상한말", "known_buttons": ["해동"]},
    )
    assert response.status_code == 422


def test_execute_for_appliance_concurrent_returns_409(client):
    from rpi.intent.mock import MockLlmClient

    svc = get_service()
    svc._llm_client = MockLlmClient({"해동해줘": '{"sequence": ["해동"]}'})
    svc._running = True
    try:
        response = client.post(
            "/execute-for-appliance",
            json={"text": "해동해줘", "known_buttons": ["해동"]},
        )
        assert response.status_code == 409
    finally:
        svc._running = False


# ── /status ───────────────────────────────────────────────────────────────────

def test_status_initially_idle(client):
    response = client.get("/status")
    assert response.status_code == 200
    body = response.json()
    assert body["running"] is False
    assert body["last_status"] is None
    assert body["last_buttons"] is None


def test_status_after_execute_shows_last_result(client):
    accepted = client.post("/execute", json={"text": "우유 데워줘"}).json()
    body = _wait_job_done(client, accepted["job_id"])
    assert body["last_status"] == "succeeded"
    assert body["last_buttons"] is not None


def test_status_initially_has_no_live_progress_fields(client):
    response = client.get("/status")
    body = response.json()
    assert body["current_button"] is None
    assert body["current_attempt"] is None
    assert body["completed_steps"] is None
    assert body["verification_confidence"] is None
    assert body["verification_detail"] is None


def test_status_after_execute_completes_clears_live_progress_fields(client):
    # 실행이 끝나면 진행 상황 트래커가 초기화되므로, 완료 후 조회한 /status에는
    # 마지막 결과(last_*)만 남고 실행 중이던 진행 정보(current_*)는 사라져야 한다.
    accepted = client.post("/execute", json={"text": "우유 데워줘"}).json()
    _wait_job_done(client, accepted["job_id"])
    response = client.get("/status")
    body = response.json()
    assert body["current_button"] is None
    assert body["current_attempt"] is None
    assert body["completed_steps"] is None
    assert body["verification_confidence"] is None
    assert body["verification_detail"] is None


# ── /stop ─────────────────────────────────────────────────────────────────────

def test_emergency_stop_returns_ok(client):
    response = client.post("/stop")
    assert response.status_code == 200
    # 유휴 상태의 정지 요청 — 성공하되 was_running=False로 구분된다
    assert response.json() == {"ok": True, "was_running": False}


def test_emergency_stop_reports_was_running(client):
    from rpi.api.deps import get_service

    svc = get_service()
    svc._running = True
    try:
        response = client.post("/stop")
    finally:
        svc._running = False
    assert response.status_code == 200
    assert response.json() == {"ok": True, "was_running": True}


# ── /suggestions ──────────────────────────────────────────────────────────────

def test_suggestions_empty_initially(client):
    response = client.get("/suggestions")
    assert response.status_code == 200
    assert response.json() == []


def test_approve_nonexistent_suggestion_returns_404(client):
    response = client.post("/suggestions/no-such-id/approve")
    assert response.status_code == 404


def test_reject_nonexistent_suggestion_returns_404(client):
    response = client.post("/suggestions/no-such-id/reject")
    assert response.status_code == 404


# ── /alerts ───────────────────────────────────────────────────────────────────

def test_alerts_inactive_before_anything_ever_fires(client):
    response = client.get("/alerts")
    assert response.status_code == 200
    body = response.json()
    assert body["active"] is False
    assert body["kind"] is None
    assert body["updated_at"] is None


def test_alerts_reflects_a_recorded_danger_sound_event(client):
    from rpi.services import AlertEvent

    store = get_alert_store()
    store.record(AlertEvent(kind="danger_sound", raised=True, band_energy_ratio=0.8, mean_period_seconds=0.4))

    response = client.get("/alerts")
    body = response.json()
    assert body["active"] is True
    assert body["kind"] == "danger_sound"
    assert body["band_energy_ratio"] == pytest.approx(0.8)
    assert body["mean_period_seconds"] == pytest.approx(0.4)
    assert body["updated_at"] is not None


def test_alerts_reflects_clearing_after_raising(client):
    from rpi.services import AlertEvent

    store = get_alert_store()
    store.record(AlertEvent(kind="danger_sound", raised=True))
    store.record(AlertEvent(kind="danger_sound", raised=False))

    response = client.get("/alerts")
    assert response.json()["active"] is False


# ── /nodes (다중 노드 등록부) ────────────────────────────────────────────────

def test_nodes_empty_initially(client):
    response = client.get("/nodes")
    assert response.status_code == 200
    assert response.json() == []


def test_register_node_returns_it_and_lists_it(client):
    response = client.post("/nodes/microwave", json={"base_url": "http://192.168.1.10:8080"})
    assert response.status_code == 200
    assert response.json() == {"appliance_id": "microwave", "base_url": "http://192.168.1.10:8080"}

    listed = client.get("/nodes").json()
    assert listed == [{"appliance_id": "microwave", "base_url": "http://192.168.1.10:8080"}]


def test_register_node_blank_base_url_returns_422(client):
    response = client.post("/nodes/microwave", json={"base_url": "   "})
    assert response.status_code == 422


def test_reregistering_replaces_the_address(client):
    client.post("/nodes/microwave", json={"base_url": "http://old-node"})
    client.post("/nodes/microwave", json={"base_url": "http://new-node"})

    listed = client.get("/nodes").json()
    assert listed == [{"appliance_id": "microwave", "base_url": "http://new-node"}]


def test_unregister_node_removes_it(client):
    client.post("/nodes/microwave", json={"base_url": "http://node"})

    response = client.delete("/nodes/microwave")

    assert response.status_code == 200
    assert client.get("/nodes").json() == []


def test_unregister_unknown_node_still_returns_ok(client):
    response = client.delete("/nodes/no-such-appliance")
    assert response.status_code == 200


def test_multiple_nodes_can_be_registered_independently(client):
    client.post("/nodes/microwave", json={"base_url": "http://node-a"})
    client.post("/nodes/aircon", json={"base_url": "http://node-b"})

    listed = {n["appliance_id"]: n["base_url"] for n in client.get("/nodes").json()}
    assert listed == {"microwave": "http://node-a", "aircon": "http://node-b"}


# ── execute 계열 appliance_id 전달 확인 ──────────────────────────────────────
# (실제 노드 라우팅 자체는 test_service_node_routing.py가 커버 — 여기선 요청
# 스키마가 라우터를 통해 서비스까지 문제없이 전달되는지만 확인)

def test_execute_buttons_accepts_optional_appliance_id(client):
    response = client.post(
        "/execute-buttons", json={"buttons": ["커스텀A"], "appliance_id": "microwave"}
    )
    assert response.status_code == 200


def test_execute_buttons_blank_appliance_id_is_treated_as_unset(client):
    response = client.post(
        "/execute-buttons", json={"buttons": ["커스텀A"], "appliance_id": "   "}
    )
    assert response.status_code == 200


# ── /demo/suggest (시연용 제안 강제 생성) ─────────────────────────────────────

def test_demo_suggest_creates_pending_suggestion(client):
    response = client.post("/demo/suggest", json={})
    assert response.status_code == 200
    body = response.json()
    assert body["purpose"] == "우유 데워줘"
    assert body["time_band"] == "데모"
    assert body["steps"] == ["해동", "시간 90초", "시작"]

    listed = client.get("/suggestions").json()
    assert [s["id"] for s in listed] == [body["id"]]


def test_demo_suggest_is_idempotent_for_same_purpose(client):
    first = client.post("/demo/suggest", json={}).json()
    second = client.post("/demo/suggest", json={}).json()
    # 트리거를 연타해도 같은 pending 제안을 돌려준다 — 중복 카드 없음
    assert first["id"] == second["id"]
    assert len(client.get("/suggestions").json()) == 1


def test_demo_suggest_respects_dnd(client):
    client.post("/dnd", json={"duration_minutes": 10})
    response = client.post("/demo/suggest", json={})
    assert response.status_code == 409


def test_demo_suggestion_approve_executes(client):
    created = client.post("/demo/suggest", json={}).json()
    approved = client.post(f"/suggestions/{created['id']}/approve")
    assert approved.status_code == 200
    body = approved.json()
    assert body["status"] == "accepted"

    status = _wait_job_done(client, body["job_id"])
    assert status["last_status"] == "succeeded"


def test_demo_suggestion_reject_dismisses(client):
    created = client.post("/demo/suggest", json={}).json()
    rejected = client.post(f"/suggestions/{created['id']}/reject")
    assert rejected.status_code == 200
    assert client.get("/suggestions").json() == []
    # 같은 id 재거부는 404 — pending 전용 계약 유지
    assert client.post(f"/suggestions/{created['id']}/reject").status_code == 404


# ── job 모델 계약 ─────────────────────────────────────────────────────────────

def test_job_ids_are_unique_per_execution(client):
    first = client.post("/execute-buttons", json={"buttons": ["버튼1"]}).json()
    _wait_job_done(client, first["job_id"])
    second = client.post("/execute-buttons", json={"buttons": ["버튼2"]}).json()
    done = _wait_job_done(client, second["job_id"])
    # 이전 실행의 결과를 내 것으로 오인할 수 없다 — job_id가 실행마다 다르다
    assert first["job_id"] != second["job_id"]
    assert done["last_job_id"] == second["job_id"]


def test_status_idle_has_no_job_fields(client):
    body = client.get("/status").json()
    assert body["job_id"] is None
    assert body["last_job_id"] is None
    assert body["total_steps"] is None


# ── /demo/inject-failure (리허설 실패 주입) ───────────────────────────────────

def test_inject_failure_forces_retry_on_next_execution(client):
    armed = client.post("/demo/inject-failure", json={"button_index": 0, "attempts": 1})
    assert armed.status_code == 200

    accepted = client.post("/execute-buttons", json={"buttons": ["해동", "시작"]}).json()
    status = _wait_job_done(client, accepted["job_id"])

    # 최종 결과는 성공(재시도로 회복) — 내부 결과로 재시도가 실제 있었는지 확인
    assert status["last_status"] == "succeeded"
    svc = get_service()
    assert svc._last_result.buttons[0].attempts == 2
    assert svc._last_result.buttons[1].attempts == 1


def test_inject_failure_with_high_attempts_causes_safety_stop(client):
    client.post("/demo/inject-failure", json={"attempts": 3})

    accepted = client.post("/execute-buttons", json={"buttons": ["해동", "시작"]}).json()
    status = _wait_job_done(client, accepted["job_id"])

    assert status["last_status"] == "safety_stopped"


def test_inject_failure_is_one_shot_across_executions(client):
    client.post("/demo/inject-failure", json={"attempts": 1})

    first = client.post("/execute-buttons", json={"buttons": ["해동"]}).json()
    _wait_job_done(client, first["job_id"])
    second = client.post("/execute-buttons", json={"buttons": ["해동"]}).json()
    status = _wait_job_done(client, second["job_id"])

    assert status["last_status"] == "succeeded"
    assert get_service()._last_result.buttons[0].attempts == 1


def test_inject_failure_can_be_cleared(client):
    client.post("/demo/inject-failure", json={"attempts": 2})
    cleared = client.delete("/demo/inject-failure")
    assert cleared.status_code == 200

    accepted = client.post("/execute-buttons", json={"buttons": ["해동"]}).json()
    _wait_job_done(client, accepted["job_id"])
    assert get_service()._last_result.buttons[0].attempts == 1


def test_inject_failure_validates_input(client):
    assert client.post("/demo/inject-failure", json={"attempts": 0}).status_code == 422
    assert client.post("/demo/inject-failure", json={"button_index": -1}).status_code == 422


# ── /history (실행 이력) ──────────────────────────────────────────────────────

def test_history_empty_initially(client):
    assert client.get("/history").json() == []


def test_history_records_executions_newest_first(client):
    first = client.post("/execute", json={"text": "우유 데워줘"}).json()
    _wait_job_done(client, first["job_id"])
    second = client.post("/execute-buttons", json={"buttons": ["전원"]}).json()
    _wait_job_done(client, second["job_id"])

    entries = client.get("/history").json()

    assert len(entries) == 2
    # 최신순 — 버튼 직접 실행이 먼저
    assert entries[0]["job_id"] == second["job_id"]
    assert entries[0]["purpose"] is None
    assert entries[0]["buttons"] == [
        {"button": "전원", "success": True, "attempts": 1}
    ]
    assert entries[1]["purpose"] == "우유 데워줘"
    assert entries[1]["status"] == "succeeded"
    assert entries[1]["finished_at"]  # ISO 타임스탬프 존재


def test_history_captures_injected_retry(client):
    # 실패 주입 → 폐루프 재시도 회복이 이력의 retry_count로 남는다
    client.post("/demo/inject-failure", json={"button_index": 0, "attempts": 1})
    accepted = client.post("/execute-buttons", json={"buttons": ["전원", "시작"]}).json()
    _wait_job_done(client, accepted["job_id"])

    (entry,) = client.get("/history").json()

    assert entry["status"] == "succeeded"
    assert entry["retry_count"] == 1
    assert entry["buttons"][0]["attempts"] == 2


def test_history_limit_clamped(client):
    for i in range(3):
        accepted = client.post(
            "/execute-buttons", json={"buttons": [f"버튼{i}"]}
        ).json()
        _wait_job_done(client, accepted["job_id"])

    assert len(client.get("/history?limit=2").json()) == 2
    assert len(client.get("/history?limit=0").json()) == 1  # 1로 클램프


# ── /presence (공간 존재 보고·조회) ───────────────────────────────────────────

def test_presence_unknown_initially(client):
    body = client.get("/presence").json()
    assert body["present"] is None


def test_presence_report_and_read(client):
    posted = client.post(
        "/presence", json={"present": True, "source": "camera"}
    )
    assert posted.status_code == 200
    assert posted.json()["present"] is True

    body = client.get("/presence").json()
    assert body["present"] is True
    assert body["source"] == "camera"
    assert body["updated_at"]
