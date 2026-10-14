"""공개 /health 축소(2026-10-14 보안 1차 점검 MEDIUM).

종전: 키 없이 열린 /health가 조용한 시간 설정(시작·끝·켜짐·지금 조용한지)과 잠시 쉬기 끝 시각을 실었다 —
같은 망의 누구나 생활 시간(잠자는 시간대)을 읽을 수 있었다.
기대: 공개 /health는 생존·버전만. 준비 상태·잠시 쉬기·조용한 시간은 인증 경로 /health/detail.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import get_alert_store, get_node_registry, get_service, get_suggestion_service
from rpi.main import app

KEY = "secret-for-tests-123"


@pytest.fixture(autouse=True)
def _strict(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_API_KEY", KEY)
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()
    yield
    for dep in (get_service, get_suggestion_service, get_alert_store, get_node_registry):
        dep.cache_clear()


def test_public_health_carries_only_liveness_and_version():
    lan = TestClient(app, client=("192.168.0.30", 40000))
    lan.headers.update({"X-API-Key": KEY})
    lan.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"})
    lan.post("/dnd", json={"duration_minutes": 30})
    anonymous = TestClient(app, client=("192.168.0.31", 40000))
    res = anonymous.get("/health")
    assert res.status_code == 200
    body = res.json()
    assert set(body) == {"ok", "version"} and body["ok"] is True
    text = res.text
    for leaked in ("quiet", "22:00", "07:00", "dnd", "actuator", "act_mode"):
        assert leaked not in text


def test_detail_needs_the_key_from_lan_and_has_the_moved_fields():
    anonymous = TestClient(app, client=("192.168.0.31", 40000))
    assert anonymous.get("/health/detail").status_code == 401
    phone = TestClient(app, client=("192.168.0.30", 40000))
    body = phone.get("/health/detail", headers={"X-API-Key": KEY}).json()
    assert {"ok", "actuator_ready", "dnd_until", "quiet", "act_mode"} <= set(body)
    assert set(body["quiet"]) >= {"enabled", "start", "end", "active"}


def test_kiosk_on_loopback_reads_detail_without_a_key():
    kiosk = TestClient(app, base_url="http://localhost:8000", client=("127.0.0.1", 50000))
    res = kiosk.get("/health/detail")
    assert res.status_code == 200 and "quiet" in res.json()
    # 다른 사이트 페이지가 루프백으로 읽으려 하면 거절(출처 확인, test_loopback_origin.py)
    assert kiosk.get("/health/detail", headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403
