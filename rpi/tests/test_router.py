"""FastAPI 라우터 통합 테스트 — 하드웨어 없이 mock으로 동작."""
import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import (
    get_alert_store,
    get_node_registry,
    get_service,
    get_suggestion_service,
)
from rpi.main import app


@pytest.fixture(autouse=True)
def reset_singletons():
    """각 테스트마다 서비스 싱글톤을 초기화해 상태 오염 방지."""
    get_service.cache_clear()
    get_suggestion_service.cache_clear()
    get_alert_store.cache_clear()
    get_node_registry.cache_clear()
    yield
    get_service.cache_clear()
    get_suggestion_service.cache_clear()
    get_alert_store.cache_clear()
    get_node_registry.cache_clear()


@pytest.fixture()
def client():
    return TestClient(app)


# ── /execute ──────────────────────────────────────────────────────────────────

def test_execute_known_purpose_succeeds(client):
    response = client.post("/execute", json={"text": "우유 데워줘"})
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "succeeded"
    assert len(body["buttons"]) == 3
    assert all(step["success"] for step in body["buttons"])


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
    assert body["status"] == "succeeded"
    assert [step["button"] for step in body["buttons"]] == ["커스텀A", "커스텀B"]


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
    assert body["status"] == "succeeded"
    assert [step["button"] for step in body["buttons"]] == ["해동", "시작"]


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
    client.post("/execute", json={"text": "우유 데워줘"})
    response = client.get("/status")
    body = response.json()
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
    client.post("/execute", json={"text": "우유 데워줘"})
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
