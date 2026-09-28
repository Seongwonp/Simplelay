"""G3 세탁 완료 → 제습 시나리오 · G6 모의 ThinQ 장애 주입 API (2026-09-30).

전부 모의 ThinQ 클라이언트다. 실제 ThinQ 호출은 없다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.tests.test_thinq_u1 import _reset, _wait_done, client, mock_mode  # noqa: F401
from rpi.services.thinq import MOCK_DEHUMIDIFIER_ID, MOCK_PURIFIER_ID

HIGH = {"appliance_id": "air_purifier", "action": "set_wind_strength",
        "args": {"wind_strength": "HIGH"}}


def _mock_client():
    return deps.get_service().thinq_controller.client


def _cards(client, scenario_id="wash_then_dry"):
    return [s for s in client.get("/suggestions").json() if s.get("scenario_id") == scenario_id]


def _fault(client, **body):
    return client.post("/demo/thinq/fault", json=body)


def _run_high(client):
    response = client.post("/thinq/command", json=HIGH)
    assert response.status_code == 200, response.text
    return _wait_done(client, response.json()["job_id"])


# ── G3: 세탁 완료 → 제습기 제안 ───────────────────────────────────────────


def test_wash_complete_offers_dehumidifier_card_and_approval_sends_thinq(client):
    event = client.post("/demo/thinq/event", json={"event": "wash_complete"})
    assert event.status_code == 200
    mock = _mock_client()
    assert mock.controls == []  # 승인 없는 자동 실행 없음

    cards = _cards(client)
    assert len(cards) == 1
    card = cards[0]
    assert card["purpose"] == "세탁이 끝났어요. 실내 건조를 위해 제습기를 켤까요?"
    assert card["is_demo"] is True
    assert "세탁 완료" in card["reason"] and "모의" in card["reason"]
    assert card["commands"] == [{
        "target_id": "dehumidifier", "route": "thinq", "action": "set_power",
        "args": {"power": "POWER_ON"}, "buttons": [], "summary": "제습기(모의) 전원 켜기"}]

    # 같은 이벤트가 또 와도 카드는 하나.
    client.post("/demo/thinq/event", json={"event": "wash_complete"})
    assert len(_cards(client)) == 1

    approved = client.post(f"/suggestions/{card['id']}/approve")
    assert approved.status_code == 200, approved.text
    status = _wait_done(client, approved.json()["job_id"])
    assert status["last_route"] == "thinq"
    assert status["last_confirmation"] == "state_confirmed"
    assert mock.controls == [(MOCK_DEHUMIDIFIER_ID, {"operation": {"dehumidifierOperationMode": "POWER_ON"}})]
    assert mock.get_status(MOCK_DEHUMIDIFIER_ID)["operation"]["dehumidifierOperationMode"] == "POWER_ON"
    assert _cards(client) == []


def test_wash_start_makes_no_card(client):
    assert client.post("/demo/thinq/event", json={"event": "wash_start"}).status_code == 200
    assert _cards(client) == []


def test_wash_complete_with_offline_dehumidifier_makes_no_card_and_no_error(client):
    assert _fault(client, device_id="dehumidifier", mode="offline").status_code == 200
    event = client.post("/demo/thinq/event", json={"event": "wash_complete"})
    assert event.status_code == 200
    assert _cards(client) == []


def test_wash_complete_with_thinq_off_is_silent():
    from rpi.scenarios import ScenarioCatalog, ScenarioEngine

    offered = []

    class Suggestions:
        def set_scenario_resolver(self, r):
            pass

        def create_scenario_suggestion(self, **kw):
            offered.append(kw)

    class Registry:
        def get(self, appliance_id):
            return None  # ThinQ off: 제습기가 등록되지 않는다

    class Service:
        _appliance_registry = Registry()

    engine = ScenarioEngine(ScenarioCatalog(), Suggestions(), Service())
    engine.on_thinq_event({"event": "wash_complete", "execution_mode": "mock"})  # 예외 없음
    assert offered == []


def test_wash_then_dry_is_registered_in_catalog():
    from rpi.scenarios import DEFAULT_SCENARIOS, WASH_THEN_DRY

    assert WASH_THEN_DRY in DEFAULT_SCENARIOS
    assert WASH_THEN_DRY.trigger.kind == "thinq_event"
    assert WASH_THEN_DRY.trigger.event == "wash_complete"


# ── G6: 장애 주입 ─────────────────────────────────────────────────────────


def test_fault_offline_makes_readiness_412_and_normal_restores(client):
    body = _fault(client, device_id="air_purifier", mode="offline").json()
    assert body["device_id"] == MOCK_PURIFIER_ID and body["mode"] == "offline"
    assert body["online"] is False and body["execution_mode"] == "mock"
    readiness = client.get("/readiness/air_purifier").json()
    assert readiness["can_execute"] is False
    assert client.post("/thinq/command", json=HIGH).status_code == 412
    assert _mock_client().controls == []  # 보내지 않았다

    assert _fault(client, device_id="air_purifier", mode="normal").json()["online"] is True
    assert client.get("/readiness/air_purifier").json()["can_execute"] is True


def test_fault_unconfirmed_is_accepted_not_success_nor_failure(client):
    _fault(client, device_id="air_purifier", mode="unconfirmed")
    status = _run_high(client)
    assert status["last_route"] == "thinq"
    assert status["last_receipt"] == "accepted"
    assert status["last_confirmation"] == "none"
    assert status["last_outcome"] != "failed"
    # 지속 장애: 다음 명령도 같다.
    assert _run_high(client)["last_receipt"] == "accepted"
    assert len(_mock_client().controls) == 2


def test_fault_lost_is_unknown_receipt_without_resend(client):
    _fault(client, device_id="air_purifier", mode="lost")
    status = _run_high(client)
    assert status["last_receipt"] == "unknown"
    assert status["last_confirmation"] == "none"
    assert len(_mock_client().controls) == 1  # 자동 재전송 없음


def test_fault_latency_is_listed_and_command_still_confirms(client):
    body = _fault(client, device_id=MOCK_PURIFIER_ID, mode="normal", latency_ms=20).json()
    assert body["latency_ms"] == 20 and body["mode"] == "normal"
    faults = {f["device_id"]: f for f in client.get("/demo/thinq/fault").json()["faults"]}
    assert faults[MOCK_PURIFIER_ID]["latency_ms"] == 20
    assert _run_high(client)["last_confirmation"] == "state_confirmed"


def test_fault_rejects_unknown_device_and_mode(client):
    assert _fault(client, device_id="toaster", mode="offline").status_code == 404
    assert _fault(client, device_id="air_purifier", mode="broken").status_code == 422
    assert _fault(client, device_id="air_purifier", mode="normal",
                  latency_ms=99_999).status_code == 422


def test_fault_api_is_404_when_thinq_off(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    _reset()
    try:
        from rpi.main import app

        c = TestClient(app)
        assert c.post("/demo/thinq/fault", json={"device_id": "air_purifier",
                                                 "mode": "offline"}).status_code == 404
        assert c.get("/demo/thinq/fault").status_code == 404
    finally:
        _reset()


@pytest.mark.parametrize("mode", ["offline", "unconfirmed", "lost"])
def test_fault_is_mock_only_in_real_mode(monkeypatch, mode):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "real")
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", "dev-123")
    _reset()
    try:
        from rpi.main import app

        c = TestClient(app)
        assert c.post("/demo/thinq/fault", json={"device_id": "air_purifier",
                                                 "mode": mode}).status_code == 409
    finally:
        _reset()
