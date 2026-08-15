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
