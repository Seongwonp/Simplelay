"""ThinQ 가전 전원 기억 → ``GET /thinq/power``(2026-10-16, 키오스크 가전 줄의 '켜짐').

새로 클라우드를 부르지 않고, 이미 하는 조회(공기질 판독·상태 재조회·명령 확인)의 전원 칸만 옮겨 적는다. 모르는 값·조회
실패·오래된 기억은 내보내지 않는다(지어내지 않는다). 전부 **모의**(mock 클라이언트)다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import get_power_cache, get_thinq_client, reset_thinq_caches
from rpi.routines.wiring import reset_routines
from rpi.services.thinq import air_purifier_binding, dehumidifier_binding, washer_binding
from rpi.services.thinq.power import POWER_STALE_SECONDS, ThinqPowerCache, power_of

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_control_arbiter, deps.get_presence_state_machine, deps.get_appliance_done_log,
)


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()


def _env(monkeypatch, thinq_mode: str | None):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_V2_SCENARIOS", "SIMPLELAY_LOCAL_APPLIANCES",
                 "SIMPLELAY_ACT_MODE", "SIMPLELAY_ROUTINE_DONE_SENSORS", "SIMPLELAY_PRESENCE_GATING",
                 "SIMPLELAY_AIR_POLL_SECONDS", "SIMPLELAY_PAUSE_CARRYOVER_UNTIL"):
        monkeypatch.delenv(name, raising=False)
    if thinq_mode is None:
        monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    else:
        monkeypatch.setenv("SIMPLELAY_THINQ_MODE", thinq_mode)
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.3")


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _wait_done(client, job_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish")


def _command(api, appliance_id, action, args):
    res = api.post("/thinq/command", json={"appliance_id": appliance_id, "action": action, "args": args})
    assert res.status_code == 200, res.text
    return _wait_done(api, res.json()["job_id"])


def _power(api) -> dict:
    res = api.get("/thinq/power")
    assert res.status_code == 200, res.text
    return {e["appliance_id"]: e["power"] for e in res.json()["appliances"]}


# ── 전원 칸 읽기(대응표의 set_power 칸 그대로) ─────────────────────────────────────


@pytest.mark.parametrize(("value", "expected"), [("POWER_ON", "on"), ("POWER_OFF", "off"),
                                                 ("SOMETHING_ELSE", None), (None, None), (1, None)])
def test_power_of_reads_the_set_power_field(value, expected):
    state = {"operation": {"airPurifierOperationMode": value}, "airFlow": {"windStrength": "LOW"}}
    assert power_of(air_purifier_binding("d"), state) == expected


def test_power_of_unknown_when_field_missing_or_no_power_action():
    assert power_of(air_purifier_binding("d"), {"airFlow": {"windStrength": "HIGH"}}) is None
    assert power_of(air_purifier_binding("d"), None) is None
    assert power_of(dehumidifier_binding("d"), {"operation": {"dehumidifierOperationMode": "POWER_ON"}}) == "on"
    # 세탁기에는 전원 동작이 없다 — 운전 상태로 '켜짐'을 짐작하지 않는다.
    assert power_of(washer_binding("d"), [{"location": {"locationName": "MAIN"},
                                          "runState": {"currentState": "RUNNING"}}]) is None


def test_cache_drops_stale_and_unknown():
    now = [100.0]
    cache = ThinqPowerCache(monotonic=lambda: now[0])
    binding = air_purifier_binding("d")
    cache.observe("air_purifier", binding, {"operation": {"airPurifierOperationMode": "POWER_ON"}})
    assert cache.snapshot() == [{"appliance_id": "air_purifier", "power": "on", "age_s": 0.0}]
    now[0] += POWER_STALE_SECONDS + 1
    assert cache.snapshot() == []
    cache.observe("air_purifier", binding, {"operation": {"airPurifierOperationMode": "POWER_ON"}})
    assert [e["power"] for e in cache.snapshot()] == ["on"]
    # 다음 조회에서 값을 모르면 이전 '켜짐'을 지운다.
    cache.observe("air_purifier", binding, {"airFlow": {}})
    assert cache.snapshot() == []


# ── API ─────────────────────────────────────────────────────────────────────────


def test_power_is_empty_before_any_read_and_does_not_call_thinq(api, monkeypatch):
    client = get_thinq_client()

    def boom(*_a, **_k):
        raise AssertionError("GET /thinq/power must not call ThinQ")

    monkeypatch.setattr(client, "get_status", boom)
    res = api.get("/thinq/power")
    assert res.status_code == 200
    assert res.json() == {"execution_mode": "mock", "appliances": []}


def test_power_on_command_confirm_read_marks_on(api):
    _command(api, "air_purifier", "set_power", {"power": "POWER_ON"})
    assert _power(api) == {"air_purifier": "on"}
    _command(api, "air_purifier", "set_power", {"power": "POWER_OFF"})
    assert _power(api) == {"air_purifier": "off"}


def test_status_reread_records_power_and_failure_forgets(api, monkeypatch):
    assert api.get("/thinq/status/dehumidifier").status_code == 200
    assert _power(api) == {"dehumidifier": "off"}
    _command(api, "dehumidifier", "set_power", {"power": "POWER_ON"})
    assert _power(api) == {"dehumidifier": "on"}

    client = get_thinq_client()

    def offline(*_a, **_k):
        raise RuntimeError("down")

    monkeypatch.setattr(client, "get_status", offline)
    assert api.get("/thinq/status/dehumidifier").status_code == 503
    assert _power(api) == {}


def test_air_quality_read_records_purifier_power(api):
    from rpi.api.air_quality_wiring import _read_purifier_state

    _command(api, "air_purifier", "set_power", {"power": "POWER_ON"})
    get_power_cache().clear()
    _read_purifier_state()
    assert _power(api) == {"air_purifier": "on"}


def test_power_entry_older_than_limit_is_not_reported(api, monkeypatch):
    _command(api, "air_purifier", "set_power", {"power": "POWER_ON"})
    cache = get_power_cache()
    real = cache._monotonic
    monkeypatch.setattr(cache, "_monotonic", lambda: real() + POWER_STALE_SECONDS + 5)
    assert _power(api) == {}


def test_power_endpoint_with_thinq_off_is_empty(monkeypatch):
    _env(monkeypatch, None)
    _reset()
    from rpi.main import app

    try:
        res = TestClient(app).get("/thinq/power")
        assert res.status_code == 200
        assert res.json() == {"execution_mode": None, "appliances": []}
    finally:
        _reset()
