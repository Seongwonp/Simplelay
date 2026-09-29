"""시연 gap G5·G10·G13 (2026-09-29) — 전부 모의다. 실물 호출은 없다.

- G5: ``GET /appliances``가 제어 경로(``control_path``)를 싣고, ThinQ 가전도 목록에 나온다.
- G10: 부재 중에는 ``POST /demo/scenario/{id}``가 카드를 만들지 않고 409로 거절한다.
- G13: ``POST /demo/alert``로 위험 소리 경보를 주입한다(모의·시뮬레이터 전용).
"""

from __future__ import annotations

import asyncio
import json

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.router import alert_event_payload, sse_event_lines
from rpi.tests.test_thinq_u1 import _reset, client, mock_mode  # noqa: F401


@pytest.fixture()
def thinq_off(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    yield
    _reset()


@pytest.fixture()
def plain_client(thinq_off):
    from rpi.main import app

    return TestClient(app)


def _by_id(response):
    assert response.status_code == 200, response.text
    return {a["id"]: a for a in response.json()}


# ── G5: /appliances의 제어 경로 ────────────────────────────────────────────


def test_appliances_expose_control_path_and_thinq_entries(client):
    appliances = _by_id(client.get("/appliances"))
    assert "microwave" in appliances
    assert appliances["microwave"]["control_path"] == "physical"
    assert "air_purifier" in appliances, "ThinQ 가전이 목록에 없다"
    assert appliances["air_purifier"]["control_path"] == "thinq"
    assert appliances["air_purifier"]["name"] == "공기청정기(모의)"
    assert appliances["washer"]["control_path"] == "thinq"
    assert appliances["dehumidifier"]["control_path"] == "thinq"
    # ThinQ 가전은 누를 조작부가 없다 — 기존 화면이 격자를 그리지 않도록 빈 목록.
    assert appliances["air_purifier"]["buttons"] == []
    # 모의 모드의 ThinQ 가전은 지금 조작할 수 있다고 말해도 되는 상태다.
    assert appliances["air_purifier"]["readiness"] == "operable"
    assert appliances["air_purifier"]["can_execute"] is True
    # 모의 물리 선풍기(서버 구성)는 폰 편집기 대상이 아니라 종전대로 숨긴다.
    assert "fan" not in appliances


def test_appliances_without_thinq_have_only_physical_entries(plain_client):
    appliances = _by_id(plain_client.get("/appliances"))
    assert "air_purifier" not in appliances
    assert "washer" not in appliances
    assert appliances["microwave"]["control_path"] == "physical"
    assert all(a["control_path"] == "physical" for a in appliances.values())


# ── G10: 부재 중 시연 시나리오 트리거 ──────────────────────────────────────


def _events(client):
    return client.get("/suggestions/events?limit=50").json()["events"]


@pytest.fixture()
def gated_client(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.5")
    monkeypatch.setenv("SIMPLELAY_PRESENCE_GATING", "true")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def test_manual_scenario_is_refused_while_absent(gated_client):
    assert gated_client.post(
        "/presence", json={"present": False, "source": "demo"}
    ).status_code == 200

    response = gated_client.post("/demo/scenario/evening_rest")
    assert response.status_code == 409, response.text
    assert "자리에 안 계셔서" in response.json()["detail"]
    assert gated_client.get("/suggestions").json() == []
    # 만들었다가 거두는 두 줄(created → withdrawn)이 남지 않아야 한다.
    assert [e for e in _events(gated_client) if e.get("action") == "created"] == []


def test_manual_scenario_works_while_present(gated_client):
    assert gated_client.post(
        "/presence", json={"present": True, "source": "demo"}
    ).status_code == 200

    response = gated_client.post("/demo/scenario/evening_rest")
    assert response.status_code == 200, response.text
    assert response.json()["scenario_id"] == "evening_rest"
    assert [s["scenario_id"] for s in gated_client.get("/suggestions").json()] == [
        "evening_rest"
    ]


# ── G13: 위험 소리 경보 주입 ───────────────────────────────────────────────


ALERT_BODY = {
    "kind": "danger_sound",
    "band_energy_ratio": 0.82,
    "mean_period_seconds": 0.5,
}


def _sse_alert_events(payloads):
    """주어진 alert 스냅샷 순서를 SSE 제너레이터에 흘려 alert 이벤트만 걷는다."""
    ticks = {"n": 0}

    async def disconnected():
        ticks["n"] += 1
        return ticks["n"] > len(payloads)

    async def run():
        out = []
        gen = sse_event_lines(
            disconnected,
            lambda: payloads[min(ticks["n"] - 1, len(payloads) - 1)],
            lambda: {"running": False},
            check_interval=0.0,
            keepalive_every=1000,
        )
        async for chunk in gen:
            if chunk.startswith("event: alert\n"):
                out.append(json.loads(chunk.split("\n")[1][len("data: "):]))
        return out

    return asyncio.run(run())


def test_demo_alert_updates_snapshot_and_sse(plain_client):
    store = deps.get_alert_store()
    before = alert_event_payload(store)
    assert before["active"] is False

    response = plain_client.post("/demo/alert", json=ALERT_BODY)
    assert response.status_code == 200, response.text

    snapshot = plain_client.get("/alerts").json()
    assert snapshot["active"] is True
    assert snapshot["kind"] == "danger_sound"
    assert snapshot["band_energy_ratio"] == pytest.approx(0.82)
    assert snapshot["mean_period_seconds"] == pytest.approx(0.5)
    assert snapshot["updated_at"] is not None

    after = alert_event_payload(store)
    assert after != before
    assert _sse_alert_events([before, after]) == [before, after]

    cleared = plain_client.post("/demo/alert", json={"kind": "danger_sound", "raised": False})
    assert cleared.status_code == 200, cleared.text
    assert plain_client.get("/alerts").json()["active"] is False


def test_demo_alert_records_care_event_once(plain_client):
    plain_client.post("/demo/alert", json=ALERT_BODY)
    kinds = [e["kind"] for e in plain_client.get("/care-events").json()]
    assert kinds.count("danger_sound") == 1


def test_demo_alert_returns_404_in_uart_mode(plain_client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    response = plain_client.post("/demo/alert", json=ALERT_BODY)
    assert response.status_code == 404, response.text
    assert plain_client.get("/alerts").json()["active"] is False
