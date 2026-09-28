"""API 키 인증 — 환경변수 게이트·루프백 면제·헤더 검증.

2026-09-29: 키 미설정이면 루프백만 허용하고, LAN 요청은
``SIMPLELAY_ALLOW_UNAUTHENTICATED=1``을 명시해야 열린다(본선 준비 평가 P1).
conftest가 기본으로 켜 두는 개방 플래그를 여기서는 지우고 시작한다.
"""

import logging

import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import (
    get_alert_store,
    get_node_registry,
    get_service,
    get_suggestion_service,
)
from rpi.api.auth import is_loopback_host, log_auth_mode
from rpi.main import app


@pytest.fixture(autouse=True)
def reset_singletons():
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()
    yield
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()


@pytest.fixture(autouse=True)
def strict_auth(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)


@pytest.fixture()
def client():
    # TestClient의 기본 클라이언트 호스트는 "testclient" — 루프백이 아니므로
    # 외부(LAN) 클라이언트와 같은 취급을 받는다.
    return TestClient(app)


def test_lan_rejected_when_key_not_configured(client):
    # 0.0.0.0 바인딩에서 키가 없다고 LAN 전체에 열면 안 된다
    res = client.get("/status")
    assert res.status_code == 401
    assert "SIMPLELAY_API_KEY" in res.json()["detail"]


def test_lan_execute_rejected_when_key_not_configured(client):
    res = client.post("/execute-buttons", json={"buttons": ["전원"]})
    assert res.status_code == 401


def test_loopback_allowed_when_key_not_configured():
    # 같은 보드의 키오스크(Chromium localhost)는 키 없이 동작한다
    for host in ("127.0.0.1", "::1"):
        local = TestClient(app, client=(host, 50000))
        assert local.get("/status").status_code == 200


def test_explicit_opt_in_opens_lan_without_key(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    assert client.get("/status").status_code == 200


def test_opt_in_flag_other_values_do_not_open(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "0")
    assert client.get("/status").status_code == 401


def test_opt_in_flag_does_not_bypass_a_configured_key(client, monkeypatch):
    # 키가 있으면 개방 플래그와 무관하게 키를 요구한다
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    assert client.get("/status").status_code == 401


def test_health_stays_open_when_key_not_configured(client):
    assert client.get("/health").status_code == 200


@pytest.mark.parametrize(
    ("host", "expected"),
    [
        ("127.0.0.1", True),
        ("127.0.1.1", True),
        ("::1", True),
        ("::ffff:127.0.0.1", True),
        ("localhost", True),
        ("192.168.0.10", False),
        ("::ffff:192.168.0.10", False),
        ("testclient", False),
        ("", False),
        (None, False),
    ],
)
def test_is_loopback_host(host, expected):
    assert is_loopback_host(host) is expected


def test_startup_log_warns_when_explicitly_open(monkeypatch, caplog):
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    with caplog.at_level(logging.WARNING, logger="rpi.api.auth"):
        assert log_auth_mode() == "unauthenticated"
    assert any(
        r.levelno == logging.WARNING and "SIMPLELAY_ALLOW_UNAUTHENTICATED" in r.getMessage()
        for r in caplog.records
    )


def test_startup_log_modes(monkeypatch):
    assert log_auth_mode() == "loopback_only"
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-123")
    assert log_auth_mode() == "api_key"


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
