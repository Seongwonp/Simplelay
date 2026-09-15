"""공간 상태 API — 거리 관측이 상태 전이와 동작 어휘로 이어진다(시간 규칙은 단위 테스트가 덮는다)."""

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    deps.get_presence_state_machine.cache_clear()
    yield TestClient(app)
    deps.get_presence_state_machine.cache_clear()


def test_initial_state_is_idle_with_radar_only(client) -> None:
    body = client.get("/presence/state").json()

    assert body["state"] == "idle"
    assert body["radar"] is True and body["actuator_powered"] is False
    assert body["transitions"] == []


def test_far_then_near_observations_wake_node_and_screen(client) -> None:
    far = client.post("/presence/distance", json={"distance_m": 4.0}).json()
    assert far["state"] == "room_present"
    assert far["node_awake"] is True
    assert "wake_node" in far["transitions"][0]["actions"]

    near = client.post("/presence/distance", json={"distance_m": 0.8}).json()
    assert near["state"] == "approaching"
    assert near["screen_on"] is True
    assert near["actuator_powered"] is False  # 체류 전에는 구동부 전원 없음


def test_first_detection_already_near_reports_the_ordered_chain(client) -> None:
    body = client.post("/presence/distance", json={"distance_m": 0.5}).json()

    assert [t["current"] for t in body["transitions"]] == ["room_present", "approaching"]


def test_no_detection_tick_is_accepted(client) -> None:
    res = client.post("/presence/distance", json={"distance_m": None})
    assert res.status_code == 200
    assert res.json()["state"] == "idle"


@pytest.mark.parametrize("bad", [-1.0, "far"])
def test_invalid_distance_is_rejected(client, bad) -> None:
    assert client.post("/presence/distance", json={"distance_m": bad}).status_code == 422


def test_arrival_hint_precomputes_without_waking(client) -> None:
    body = client.post("/presence/arriving").json()

    assert body["state"] == "idle"
    assert body["arrival_hint"] is True
    assert body["transitions"][0]["actions"] == ["precompute_suggestions"]

    again = client.post("/presence/arriving").json()
    assert again["transitions"] == []  # 유효 시간 안의 중복 신호는 다시 발행하지 않음
