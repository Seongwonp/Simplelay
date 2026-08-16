"""FastAPI 라우터 통합 테스트 — 하드웨어 없이 mock으로 동작."""
import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import get_service, get_suggestion_service
from rpi.main import app


@pytest.fixture(autouse=True)
def reset_singletons():
    """각 테스트마다 서비스 싱글톤을 초기화해 상태 오염 방지."""
    get_service.cache_clear()
    get_suggestion_service.cache_clear()
    yield
    get_service.cache_clear()
    get_suggestion_service.cache_clear()


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
    assert response.json() == {"ok": True}


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
