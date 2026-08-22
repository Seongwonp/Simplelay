"""API 키 인증 — 환경변수 게이트·루프백 면제·헤더 검증."""

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
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()
    yield
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()


@pytest.fixture()
def client():
    # TestClient의 기본 클라이언트 호스트는 "testclient" — 루프백이 아니므로
    # 외부(LAN) 클라이언트와 같은 취급을 받는다.
    return TestClient(app)


def test_open_when_key_not_configured(client, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    assert client.get("/status").status_code == 200


def test_rejects_missing_key(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    assert client.get("/status").status_code == 401


def test_rejects_wrong_key(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    res = client.get("/status", headers={"X-API-Key": "wrong"})
    assert res.status_code == 401


def test_accepts_correct_key(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    res = client.get("/status", headers={"X-API-Key": "secret-123"})
    assert res.status_code == 200


def test_health_stays_open_without_key(client, monkeypatch):
    # 폰 앱이 키 입력 전에 연결 확인(ping)할 수 있어야 한다
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    assert client.get("/health").status_code == 200


def test_loopback_client_is_exempt(monkeypatch):
    # 같은 보드의 키오스크(localhost)는 키 배포 없이 동작해야 한다
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    local = TestClient(app, client=("127.0.0.1", 50000))
    assert local.get("/status").status_code == 200


def test_execute_requires_key(client, monkeypatch):
    # 물리 액추에이터 구동 경로가 무인증으로 열려 있으면 안 된다
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    res = client.post("/execute-buttons", json={"buttons": ["전원"]})
    assert res.status_code == 401
