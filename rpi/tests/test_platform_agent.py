"""플랫폼 AI 에이전트 연결(2026-10-26) — 가짜 버스로만. 기본 꺼짐, 사람 수는 바뀔 때만, 실패해도 안 깨진다."""

import pytest

from rpi.services import platform_agent as pa


class _Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


class _FakeBus:
    def __init__(self, props=None, fail=False) -> None:
        self.props = props or {}
        self.fail = fail
        self.sets: list[tuple[str, str, object]] = []
        self.gets = 0

    def set_property(self, name, signature, value):
        if self.fail:
            raise RuntimeError("bus down")
        self.sets.append((name, signature, value))

    def get_property(self, name):
        self.gets += 1
        if self.fail:
            raise RuntimeError("bus down")
        return self.props.get(name)


_REAL_GETTER = pa.get_platform_agent


@pytest.fixture(autouse=True)
def _fresh_singleton():
    _REAL_GETTER.cache_clear()
    yield
    _REAL_GETTER.cache_clear()


def test_disabled_by_default(monkeypatch):
    monkeypatch.delenv(pa.ENV_ENABLED, raising=False)
    agent = pa.get_platform_agent()
    assert agent.enabled is False
    assert agent.set_people_count(2) is False
    assert agent.snapshot() == {"weather": None, "suggestion": None, "available": False}


def test_enabled_without_bus_name_stays_off(monkeypatch):
    monkeypatch.setenv(pa.ENV_ENABLED, "1")
    monkeypatch.delenv(pa.ENV_BUS, raising=False)
    assert pa.get_platform_agent().enabled is False


def test_count_is_written_only_on_change_and_at_most_every_ten_seconds():
    clock, bus = _Clock(), _FakeBus()
    agent = pa.PlatformAgent(bus, now=clock)
    assert agent.set_people_count(1) is True
    clock.t += 2
    assert agent.set_people_count(1) is False, "같은 값은 다시 보내지 않는다"
    assert agent.set_people_count(2) is False, "10초 안의 변화는 다음 주기로 미룬다"
    clock.t += 10
    assert agent.set_people_count(2) is True
    assert bus.sets == [("NumberOfDetectedUser", "u", 1), ("NumberOfDetectedUser", "u", 2)]


def test_failure_is_swallowed_logged_once_and_backs_off(caplog):
    clock, bus = _Clock(), _FakeBus(fail=True)
    agent = pa.PlatformAgent(bus, now=clock, backoff_s=60)
    with caplog.at_level("WARNING"):
        assert agent.set_people_count(1) is False
        clock.t += 15
        assert agent.set_people_count(1) is False
        assert agent.snapshot()["available"] is False
    assert sum("플랫폼 AI 에이전트" in r.getMessage() for r in caplog.records) == 1
    bus.fail = False
    clock.t += 60
    assert agent.set_people_count(1) is True


def test_snapshot_reads_weather_and_filters_error_like_suggestion():
    clock = _Clock()
    bus = _FakeBus({
        "WeatherInfo": {"condition": "맑음", "temperature": 21.5},
        "SuggestionMessage": "Some calendars could not be validated. Please check.",
    })
    agent = pa.PlatformAgent(bus, now=clock)
    snap = agent.snapshot()
    assert snap["available"] is True
    assert snap["suggestion"] is None
    assert agent.view()["weather_summary"] == "맑음 21.5°"


def test_snapshot_is_cached_and_empty_weather_is_none():
    clock = _Clock()
    bus = _FakeBus({"WeatherInfo": {}, "SuggestionMessage": "  창문을 열어 환기해 보세요  "})
    agent = pa.PlatformAgent(bus, now=clock)
    first = agent.snapshot()
    assert first == {"weather": None, "suggestion": "창문을 열어 환기해 보세요", "available": True}
    reads = bus.gets
    agent.snapshot()
    assert bus.gets == reads, "30초 안에는 버스를 다시 부르지 않는다"


def test_publish_sends_only_counts_from_room_presence(monkeypatch):
    from rpi.api.room_presence_wiring import _publish
    from rpi.services.room_presence import RoomPresence

    clock, bus = _Clock(), _FakeBus()
    agent = pa.PlatformAgent(bus, now=clock)
    monkeypatch.setattr(pa, "get_platform_agent", lambda: agent)
    room = RoomPresence(now=clock, arrive_frames=1, dim_after_s=60, away_after_s=600, stale_s=20)
    clock.t += 1
    room.observe({"ts": clock.t, "persons": 2, "frames": 1})
    _publish(room)
    _publish(room)
    assert bus.sets == [("NumberOfDetectedUser", "u", 2)]
    assert all(isinstance(v, int) for _, _, v in bus.sets)


def test_failing_agent_does_not_break_room_route(monkeypatch):
    from fastapi.testclient import TestClient

    import rpi.api.room_presence_wiring as wiring
    from rpi.main import app

    class _Broken:
        def view(self):
            raise RuntimeError("boom")

    monkeypatch.delenv("SIMPLELAY_ROOM_PRESENCE_FILE", raising=False)
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    monkeypatch.setattr(pa, "get_platform_agent", lambda: _Broken())
    wiring.get_room_presence.cache_clear()
    try:
        resp = TestClient(app).get("/presence/room")
    finally:
        wiring.get_room_presence.cache_clear()
    assert resp.status_code == 200
    body = resp.json()
    assert body["enabled"] is False
    assert body["platform_agent"] == {"available": False, "suggestion": None, "weather_summary": None}
