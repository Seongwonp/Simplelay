"""루프백 인증 면제의 출처 확인(2026-10-14 보안 1차 점검 MEDIUM).

종전: 루프백 요청이면 Origin을 보지 않고 면제했다 — 그 보드의 브라우저가 연 다른 사이트 페이지가
``fetch('http://localhost:8000/stop', {method: 'POST'})``로 정지·실행 API를 부를 수 있었다.

기대(실제 진입점 = FastAPI 앱, 거절이면 서비스의 제어 호출 0회):
- 다른 사이트 Origin·``Origin: null``·``Sec-Fetch-Site: cross-site/same-site`` → 403.
- 허용 출처는 요청 Host로 만들지 않는다(재바인딩 이름의 Host·Origin 짝도 거절). 설정값(SIMPLELAY_KIOSK_ORIGINS)만.
- 키오스크가 실제로 보내는 헤더는 통과: 네이티브 앱(Dart HTTP — Origin·Sec-Fetch 없음),
  같은 출처 웹 빌드(POST: ``Origin: http://localhost:8000``·``Sec-Fetch-Site: same-origin``).
- 정상 정지 경로(/stop)는 막히거나 늦어지지 않는다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import get_alert_store, get_node_registry, get_service, get_suggestion_service
from rpi.main import app

EXECUTE = {"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"}


@pytest.fixture(autouse=True)
def _fresh(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.delenv("SIMPLELAY_KIOSK_ORIGINS", raising=False)
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-for-tests-123")
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()
    yield
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()


@pytest.fixture
def calls(monkeypatch):
    """서비스의 제어 진입(정지·실행) 호출 수."""
    svc = get_service()
    counts = {"stop": 0, "execute": 0}
    stop, submit = svc.emergency_stop_report, svc.submit_buttons

    def counted_stop(*a, **k):
        counts["stop"] += 1
        return stop(*a, **k)

    def counted_submit(*a, **k):
        counts["execute"] += 1
        return submit(*a, **k)

    monkeypatch.setattr(svc, "emergency_stop_report", counted_stop)
    monkeypatch.setattr(svc, "submit_buttons", counted_submit)
    return counts


def local(base_url: str = "http://localhost:8000") -> TestClient:
    return TestClient(app, base_url=base_url, client=("127.0.0.1", 50000))


FOREIGN = [
    {"Origin": "https://evil.example"},
    {"Origin": "http://evil.example:8000"},
    {"Origin": "null"},
    {"Sec-Fetch-Site": "cross-site"},
    {"Sec-Fetch-Site": "same-site"},
    {"Origin": "http://localhost:3000"},  # 같은 기기 다른 포트의 웹 앱도 키오스크가 아니다
]
FOREIGN_IDS = ["https_site", "http_site", "origin_null", "cross_site", "same_site", "other_local_port"]


@pytest.mark.parametrize("headers", FOREIGN, ids=FOREIGN_IDS)
def test_foreign_browser_requests_from_loopback_are_refused_before_any_control(calls, headers):
    c = local()
    stop = c.post("/stop", headers=headers)
    run = c.post("/execute-buttons", json=EXECUTE, headers=headers)
    assert (stop.status_code, run.status_code) == (403, 403), (stop.text, run.text)
    assert calls == {"stop": 0, "execute": 0}
    assert c.get("/status", headers=headers).status_code == 403


def test_origin_null_is_not_treated_like_a_missing_origin(calls):
    c = local()
    assert c.post("/stop", headers={"Origin": "null"}).status_code == 403
    assert c.post("/stop").status_code == 200
    assert calls["stop"] == 1


def test_allowed_origin_is_not_built_from_the_request_host(calls):
    """DNS 재바인딩: 페이지가 자기 이름(evil.test:8000)으로 Host·Origin을 맞춰도 키오스크 출처가 아니다."""
    c = local("http://evil.test:8000")
    assert c.post("/stop", headers={"Origin": "http://evil.test:8000"}).status_code == 403
    assert c.get("/status", headers={"Sec-Fetch-Site": "same-origin"}).status_code == 403
    assert calls["stop"] == 0


def test_kiosk_native_app_headers_pass_and_stop_is_not_delayed(calls):
    """네이티브 키오스크 앱(Dart HTTP)은 Origin·Sec-Fetch를 보내지 않는다 — 종전처럼 면제, 정지는 바로 받는다."""
    c = local()
    started = time.monotonic()
    res = c.post("/stop", headers={"User-Agent": "Dart/3.5 (dart:io)"})
    assert res.status_code == 200, res.text
    assert time.monotonic() - started < 1.0
    assert calls["stop"] == 1
    assert c.get("/status").status_code == 200


def test_kiosk_web_build_same_origin_headers_pass(calls):
    """/kiosk/ 웹 빌드(Chromium, 같은 출처): POST는 Origin을, GET·SSE는 Sec-Fetch-Site만 붙인다."""
    c = local()
    for base in ("http://localhost:8000", "http://127.0.0.1:8000"):
        stop = c.post("/stop", headers={"Origin": base, "Sec-Fetch-Site": "same-origin"})
        assert stop.status_code == 200, stop.text
    assert c.get("/status", headers={"Sec-Fetch-Site": "same-origin"}).status_code == 200
    assert c.get("/status", headers={"Sec-Fetch-Site": "none"}).status_code == 200  # 주소창 이동
    assert calls["stop"] == 2


def test_configured_kiosk_origin_replaces_the_defaults(calls, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_KIOSK_ORIGINS", "http://hub.local:8000")
    hub = local("http://hub.local:8000")
    assert hub.post("/stop", headers={"Origin": "http://hub.local:8000"}).status_code == 200
    assert local().post("/stop", headers={"Origin": "http://localhost:8000"}).status_code == 403
    assert calls["stop"] == 1


def test_lan_phone_with_key_is_unaffected_and_stops(calls):
    phone = TestClient(app, client=("192.168.0.20", 40000))
    res = phone.post("/stop", headers={"X-API-Key": "secret-for-tests-123"})
    assert res.status_code == 200
    assert phone.post("/stop").status_code == 401
    assert calls["stop"] == 1


def test_pairing_window_uses_the_same_origin_rule():
    c = local()
    assert c.post("/pair/session", headers={"Origin": "null"}).status_code == 403
    assert c.post("/pair/session", headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403
    rebound = local("http://evil.test:8000")
    assert rebound.post("/pair/session", headers={"Origin": "http://evil.test:8000"}).status_code == 403
