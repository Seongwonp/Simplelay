"""ThinQ 공기청정기 공기질 기억 → ``GET /thinq/air``(2026-10-16, 키오스크 평소 화면의 '실내 공기' 한 줄).

전원 기억(``GET /thinq/power``)과 같은 원칙: 새로 클라우드를 부르지 않고, 이미 하는 조회(공기질 판독·상태 재조회·명령
확인)의 센서 칸만 옮겨 적는다. 등급은 **가전이 매긴 것**(``totalPollutionLevel`` → 없으면 ``PM2Level``)만 쓴다 — 우리 임계값으로
지어내지 않는다. 모르는 등급·조회 실패·오래된 기억(600초 초과)은 내보내지 않는다. 전부 **모의**(mock 클라이언트)다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rpi.api.thinq_wiring import get_power_cache, get_thinq_client
from rpi.services.air_quality import air_summary
from rpi.services.thinq import air_purifier_binding
from rpi.services.thinq.power import POWER_STALE_SECONDS, ThinqPowerCache
from rpi.services.thinq.profiles_sample import air_sensor_sample

from rpi.tests.test_thinq_power import _command, _env, _reset


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _air(api) -> dict:
    res = api.get("/thinq/air")
    assert res.status_code == 200, res.text
    return {e["appliance_id"]: e for e in res.json()["appliances"]}


# ── 센서 칸 → 요약(가전 등급 그대로) ─────────────────────────────────────────────


def test_summary_prefers_total_level_and_keeps_pm_values():
    state = {"airQualitySensor": {"PM2": 8, "PM10": 10, "PM2Level": "GOOD", "PM10Level": "NORMAL",
                                  "totalPollutionLevel": "NORMAL"}}
    assert air_summary(state) == {"grade": "NORMAL", "grade_source": "total", "pm25": 8, "pm25_level": "GOOD",
                                  "pm10": 10, "pm10_level": "NORMAL"}


def test_summary_falls_back_to_pm25_level_without_total():
    state = {"airQualitySensor": {"PM2": 42, "PM2Level": "BAD"}}
    summary = air_summary(state)
    assert summary["grade"] == "BAD"
    assert summary["grade_source"] == "pm2"
    assert summary["pm25"] == 42
    assert summary["pm10"] is None and summary["pm10_level"] is None


@pytest.mark.parametrize("state", [
    None,
    {},
    {"airQualitySensor": {}},
    # 값만 있고 가전 등급이 없으면 — 우리 임계값으로 등급을 만들지 않는다.
    {"airQualitySensor": {"PM2": 8, "PM10": 10}},
    {"airQualitySensor": {"PM2": 8, "PM2Level": "SOMETHING", "totalPollutionLevel": 3}},
    [{"location": {"locationName": "MAIN"}}],
])
def test_summary_unknown_is_none(state):
    assert air_summary(state) is None


def test_summary_ignores_non_numeric_values():
    summary = air_summary({"airQualitySensor": {"PM2": True, "PM10": "12", "totalPollutionLevel": "GOOD"}})
    assert summary["grade"] == "GOOD"
    assert summary["pm25"] is None and summary["pm10"] is None


def test_cache_air_entry_fresh_stale_and_forgotten():
    now = [100.0]
    cache = ThinqPowerCache(monotonic=lambda: now[0])
    binding = air_purifier_binding("d")
    state = {"operation": {"airPurifierOperationMode": "POWER_ON"},
             "airQualitySensor": air_sensor_sample("GOOD")}
    cache.observe("air_purifier", binding, state)
    assert cache.air_snapshot() == [{
        "appliance_id": "air_purifier", "grade": "GOOD", "grade_source": "total", "pm25": 8,
        "pm25_level": "GOOD", "pm10": 10, "pm10_level": "GOOD", "power": "on", "age_s": 0.0}]
    now[0] += POWER_STALE_SECONDS + 1
    assert cache.air_snapshot() == []
    cache.observe("air_purifier", binding, state)
    assert len(cache.air_snapshot()) == 1
    # 다음 조회에서 센서 칸이 비면(켠 직후·'운전 중에만' 설정에서 꺼짐) 이전 값을 지운다.
    cache.observe("air_purifier", binding, {"operation": {"airPurifierOperationMode": "POWER_OFF"}})
    assert cache.air_snapshot() == []
    cache.observe("air_purifier", binding, state)
    cache.forget("air_purifier")
    assert cache.air_snapshot() == []
    cache.observe("air_purifier", binding, state)
    # 명령을 보내기 직전(상태 None)에도 지운다 — 보낸 뒤 값은 다시 읽어야 안다.
    cache.observe("air_purifier", binding, None)
    assert cache.air_snapshot() == []


def test_cache_air_with_power_off_keeps_values_and_says_off():
    cache = ThinqPowerCache(monotonic=lambda: 5.0)
    cache.observe("air_purifier", air_purifier_binding("d"),
                  {"operation": {"airPurifierOperationMode": "POWER_OFF"},
                   "airQualitySensor": air_sensor_sample("BAD")})
    (entry,) = cache.air_snapshot()
    assert entry["grade"] == "BAD" and entry["power"] == "off"


# ── API ─────────────────────────────────────────────────────────────────────────


def test_air_is_empty_before_any_read_and_does_not_call_thinq(api, monkeypatch):
    client = get_thinq_client()

    def boom(*_a, **_k):
        raise AssertionError("GET /thinq/air must not call ThinQ")

    monkeypatch.setattr(client, "get_status", boom)
    monkeypatch.setattr(client, "cached_status", boom, raising=False)
    res = api.get("/thinq/air")
    assert res.status_code == 200
    assert res.json() == {"execution_mode": "mock", "appliances": []}


def test_air_quality_poll_read_records_air_and_endpoint_does_not_reread(api, monkeypatch):
    from rpi.api.air_quality_wiring import _read_purifier_state

    _command(api, "air_purifier", "set_power", {"power": "POWER_ON"})
    get_power_cache().clear()
    _read_purifier_state()
    client = get_thinq_client()

    def boom(*_a, **_k):
        raise AssertionError("GET /thinq/air must not call ThinQ")

    monkeypatch.setattr(client, "get_status", boom)
    entry = _air(api)["air_purifier"]
    assert entry["grade"] == "GOOD"
    assert entry["pm25"] == 8
    assert entry["power"] == "on"
    assert entry["age_s"] >= 0


def test_status_reread_records_air_and_failure_forgets(api, monkeypatch):
    # 모의 공기청정기는 꺼져 있으면 센서 칸이 없다('운전 중에만' 설정과 같다) — 켠 뒤 다시 읽는다.
    _command(api, "air_purifier", "set_power", {"power": "POWER_ON"})
    get_power_cache().clear()
    assert api.get("/thinq/status/air_purifier").status_code == 200
    assert "air_purifier" in _air(api)

    client = get_thinq_client()

    def offline(*_a, **_k):
        raise RuntimeError("down")

    monkeypatch.setattr(client, "get_status", offline)
    assert api.get("/thinq/status/air_purifier").status_code == 503
    assert _air(api) == {}


def test_air_entry_older_than_limit_is_not_reported(api, monkeypatch):
    _command(api, "air_purifier", "set_power", {"power": "POWER_ON"})
    assert "air_purifier" in _air(api)
    assert api.get("/thinq/status/air_purifier").status_code == 200
    cache = get_power_cache()
    real = cache._monotonic
    monkeypatch.setattr(cache, "_monotonic", lambda: real() + POWER_STALE_SECONDS + 5)
    assert _air(api) == {}


def test_air_endpoint_with_thinq_off_is_empty(monkeypatch):
    _env(monkeypatch, None)
    _reset()
    from rpi.main import app

    try:
        res = TestClient(app).get("/thinq/air")
        assert res.status_code == 200
        assert res.json() == {"execution_mode": None, "appliances": []}
    finally:
        _reset()


def test_air_endpoint_requires_api_key_when_set(monkeypatch):
    _env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_API_KEY", "k" * 32)
    _reset()
    from rpi.main import app

    try:
        client = TestClient(app, client=("192.168.0.50", 50000))
        assert client.get("/thinq/air").status_code == 401
        assert client.get("/thinq/air", headers={"X-API-Key": "k" * 32}).status_code == 200
    finally:
        _reset()
