"""공기청정기 센서 공기질 → '공기가 나빠요' 제안(2026-10-15, 사용자 요청).

근거는 공기청정기 자체 센서(ThinQ 상태 ``airQualitySensor``)의 **가전 등급**뿐이다. 센서 칸이 없으면(꺼짐·센서 준비 중)
제안하지 않는다. 승인하면 ThinQ 한 단계(``set_wind_strength HIGH``)가 종전 승인·실행 경로로 나간다. '다음부터 자동으로'는
없다. 전부 **모의**(mock 클라이언트·저장소 안 모의 클라우드)다 — 실제 공기청정기에서 나쁨 판정으로 카드가 뜬 것은 아직 보지 않았다.
"""

from __future__ import annotations

import threading
import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.air_quality_wiring import reset_air_quality
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.routines.wiring import reset_routines
from rpi.services.air_quality import (
    AirQualityMonitor,
    AirQualityPoller,
    AirReadSkipped,
    poll_seconds_from_env,
    read_air,
)

SCENARIO = "air_quality_high"
QUESTION = "공기청정기를 강풍으로 바꿀까요?"

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
    reset_air_quality()


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


def _client():
    from rpi.api.thinq_wiring import get_thinq_client

    return get_thinq_client()


def _wait_done(client, job_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish")


def _command(api, action, args):
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": action, "args": args})
    assert res.status_code == 200, res.text
    return _wait_done(api, res.json()["job_id"])


def _power_on(api, wind=None):
    """모의 공기청정기를 켠다(모의 기본은 꺼짐 — 꺼져 있으면 센서 값이 없다). 보낸 기록은 지운다."""
    _command(api, "set_power", {"power": "POWER_ON"})
    if wind is not None:
        _command(api, "set_wind_strength", {"wind_strength": wind})
    _client().controls.clear()


def _inject(api, level, **extra):
    res = api.post("/demo/thinq/air-quality", json={"level": level, **extra})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["execution_mode"] == "mock"
    return body


def _cards(api):
    return [s for s in api.get("/suggestions").json() if s.get("scenario_id") == SCENARIO]


def _bad_state(level="BAD", *, pm2=42, wind="LOW", power="POWER_ON", **levels):
    sensor = {"PM2": pm2, "PM2Level": level, "PM10": 30, "PM10Level": "NORMAL",
              "totalPollution": 2, "totalPollutionLevel": "NORMAL"}
    sensor.update(levels)
    return {"operation": {"airPurifierOperationMode": power}, "airFlow": {"windStrength": wind},
            "airQualitySensor": sensor}


# ── 판정(가전 등급 그대로, 지어내지 않는다) ─────────────────────────────────────────


@pytest.mark.parametrize("level", ["BAD", "VERY_BAD"])
def test_read_air_uses_the_device_grade(level):
    reading = read_air(_bad_state(level))
    assert reading is not None and reading.is_bad
    word = "나빠요." if level == "BAD" else "매우 나빠요."
    assert reading.reason() == f"공기청정기가 재 보니 초미세먼지가 {word}"


@pytest.mark.parametrize("field", ["PM10Level", "totalPollutionLevel"])
def test_pm10_or_total_grade_alone_is_enough(field):
    reading = read_air(_bad_state("GOOD", **{field: "BAD"}))
    assert reading is not None and reading.is_bad
    assert reading.reason() in ("공기청정기가 재 보니 미세먼지가 나빠요.", "공기청정기가 재 보니 종합 공기질이 나빠요.")


@pytest.mark.parametrize("level", ["GOOD", "NORMAL"])
def test_good_or_normal_is_not_bad(level):
    reading = read_air(_bad_state(level))
    assert reading is not None and not reading.is_bad


@pytest.mark.parametrize("state", [
    {"operation": {"airPurifierOperationMode": "POWER_OFF"}, "airFlow": {"windStrength": "LOW"}},
    {"operation": {"airPurifierOperationMode": "POWER_ON"}, "airQualitySensor": {}},
    # 꺼짐 + 센서 값은 10/15 저녁부터 값이다(공기질 센서 '항상' 설정) — test_air_quality_power_on.py.
    {"operation": {"airPurifierOperationMode": "POWER_ON"}, "airQualitySensor": {"PM2": 42}},  # 등급 없음
    {"airQualitySensor": {"PM2Level": "UNKNOWN"}},
    None, [], "x",
], ids=["no_sensor_block", "empty_sensor", "value_without_grade",
        "unknown_grade", "none", "list", "str"])
def test_missing_sensor_block_is_no_data(state):
    assert read_air(state) is None


def test_strong_wind_is_seen_from_either_wind_field():
    assert read_air(_bad_state(wind="HIGH")).wind_is_strong
    detail = _bad_state(wind="AUTO")
    detail["airFlow"]["windStrengthDetail"] = "HIGH"
    assert read_air(detail).wind_is_strong
    assert not read_air(_bad_state(wind="MID")).wind_is_strong


@pytest.mark.parametrize(("raw", "expected"), [("", 120.0), ("10", 60.0), ("59.9", 60.0), ("300", 300.0),
                                               ("abc", 120.0), ("nan", 120.0), ("999999", 3600.0)])
def test_poll_interval_default_and_minimum(raw, expected):
    assert poll_seconds_from_env({"SIMPLELAY_AIR_POLL_SECONDS": raw}) == expected


# ── 중복·다시 준비·쉬는 시간(판정기 단위) ──────────────────────────────────────────


class _Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _monitor(states, offers, clock):
    def read():
        state = states[0]
        if isinstance(state, Exception):
            raise state
        return state

    def offer(reason, **_):
        offers.append(reason)
        return object()

    return AirQualityMonitor(read, offer, monotonic=clock)


def test_one_card_then_waits_for_good_air_and_the_quiet_time():
    clock, offers, states = _Clock(), [], [_bad_state()]
    monitor = _monitor(states, offers, clock)
    assert monitor.check_once() == "offered"
    assert monitor.check_once() == "waiting_rearm"  # 여전히 나쁨 — 다시 만들지 않는다
    clock.t += 3 * 3600
    assert monitor.check_once() == "waiting_rearm"  # 시간이 지나도 좋음·보통을 보기 전에는
    states[0] = {"operation": {"airPurifierOperationMode": "POWER_OFF"}}
    assert monitor.check_once() == "no_data"  # 값 없음은 다시 준비가 아니다
    states[0] = _bad_state()
    assert monitor.check_once() == "waiting_rearm"
    states[0] = _bad_state("NORMAL")
    assert monitor.check_once() == "ok"
    states[0] = _bad_state()
    assert monitor.check_once() == "offered"  # 다시 준비 + 쉬는 시간(45분) 지남
    assert len(offers) == 2


def test_rearmed_soon_after_a_card_still_waits_the_quiet_time():
    clock, offers, states = _Clock(), [], [_bad_state()]
    monitor = _monitor(states, offers, clock)
    assert monitor.check_once() == "offered"
    clock.t += 60
    states[0] = _bad_state("GOOD")
    assert monitor.check_once() == "ok"
    states[0] = _bad_state()
    clock.t += 20 * 60
    assert monitor.check_once() == "card_quiet"  # 카드 유효 15분 + 30분 안
    clock.t += 24 * 60 + 1
    assert monitor.check_once() == "offered"
    assert len(offers) == 2


def test_blocked_offer_keeps_the_monitor_armed():
    """조용한 시간·잠시 쉬기 등으로 카드가 안 생기면 다음 판독에서 다시 본다(끝난 뒤에도 나쁘면 그때)."""
    clock, states = _Clock(), [_bad_state()]
    allowed = [False]
    offers = []
    monitor = AirQualityMonitor(lambda: states[0],
                                lambda reason, **_: offers.append(reason) or (object() if allowed[0] else None),
                                monotonic=clock)
    assert monitor.check_once() == "not_offered"
    assert monitor.armed
    allowed[0] = True
    assert monitor.check_once() == "offered"


def test_read_failure_is_logged_and_skipped(caplog):
    clock, offers, states = _Clock(), [], [RuntimeError("cloud down")]
    monitor = _monitor(states, offers, clock)
    with caplog.at_level("DEBUG", logger="rpi.services.air_quality"):
        assert monitor.check_once() == "read_failed"
        assert monitor.check_once() == "read_failed"
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert len(warnings) == 1  # 연달아 실패해도 경고는 한 번
    assert offers == []
    states[0] = AirReadSkipped("no_purifier")
    assert monitor.check_once() == "skipped:no_purifier"


def test_poller_does_not_retry_failures_in_a_storm():
    calls = []

    def failing():
        calls.append(time.monotonic())
        raise RuntimeError("boom")

    poller = AirQualityPoller(failing, interval_s=0.3, first_delay_s=0.0)
    poller.start()
    time.sleep(0.5)
    poller.stop()
    assert 1 <= len(calls) <= 2, calls  # 주기마다 한 번 — 실패 뒤 곧바로 다시 읽지 않는다


# ── 서버 경로(mock) ───────────────────────────────────────────────────────────────


@pytest.mark.parametrize("level", ["BAD", "VERY_BAD"])
def test_bad_air_offers_one_air_card(api, level):
    _power_on(api)
    body = _inject(api, level, pm2=42)
    assert body["check"] == "offered"
    cards = _cards(api)
    assert len(cards) == 1
    card = cards[0]
    assert card["purpose"] == QUESTION
    word = "나빠요." if level == "BAD" else "매우 나빠요."
    assert card["reason"] == f"공기청정기가 재 보니 초미세먼지가 {word} 연습용 센서 값이에요."
    assert card["is_demo"] is True
    assert [(c["target_id"], c["route"], c["action"], c["args"]) for c in card["commands"]] == [
        ("air_purifier", "thinq", "set_wind_strength", {"wind_strength": "HIGH"})]
    assert card["commands"][0]["summary"] == "공기청정기(모의) 풍량 강"
    for claim in ("좋아졌", "깨끗", "나아졌"):
        assert claim not in card["reason"] and claim not in card["purpose"]
    names = {s["scenario_id"]: s["name"] for s in api.get("/scenarios").json()}
    assert names[SCENARIO] == "공기가 나빠요"
    assert _client().controls == []  # 카드는 제안일 뿐 — 아무것도 보내지 않았다


@pytest.mark.parametrize("level", ["GOOD", "NORMAL"])
def test_good_or_normal_air_offers_nothing(api, level):
    _power_on(api)
    assert _inject(api, level)["check"] == "ok"
    assert _cards(api) == []


def test_no_card_when_the_purifier_is_off_or_warming_up(api):
    assert _inject(api, "BAD")["check"] == "no_data"  # 모의 기본은 꺼짐 — 센서 칸이 없다
    assert _cards(api) == []
    _power_on(api)
    assert _inject(api, "NONE")["check"] == "no_data"  # 켠 직후 센서 준비 중(칸 없음)
    assert _cards(api) == []
    status = api.get("/thinq/status/air_purifier").json()["state"]
    assert "airQualitySensor" not in status


def test_no_card_when_the_wind_is_already_high(api):
    _power_on(api, wind="HIGH")
    assert _inject(api, "VERY_BAD")["check"] == "already_strong"
    assert _cards(api) == []


def test_approval_sends_exactly_one_high_wind_step(api):
    _power_on(api)
    _inject(api, "BAD")
    card = _cards(api)[0]
    res = api.post(f"/suggestions/{card['id']}/approve")
    assert res.status_code == 200, res.text
    job_id = res.json()["job_id"]
    assert _wait_done(api, job_id)["last_status"] == "succeeded"
    assert _client().controls == [("mock-purifier-01", {"airFlow": {"windStrength": "HIGH"}})]
    run = api.get("/scenarios/last-run").json()["run"]
    assert run["job_id"] == job_id and run["scenario_id"] == SCENARIO
    assert [(s["action"], s["args"], s["confirmation"], s["execution_mode"]) for s in run["steps"]] == [
        ("set_wind_strength", {"wind_strength": "HIGH"}, "state_confirmed", "mock")]
    assert _cards(api) == []
    # 강풍이 된 뒤에도 나쁨 — 다시 제안하지 않는다(이미 강풍 · 다시 준비 전).
    assert _inject(api, "BAD")["check"] == "already_strong"


def test_air_card_never_offers_auto_allow(api):
    _power_on(api)
    _inject(api, "BAD")
    card = _cards(api)[0]
    assert card.get("auto_rule_offer") is None
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow", json={"offer_fingerprint": "x"})
    assert res.status_code == 422
    from rpi.routines.wiring import get_auto_rule_engine

    assert get_auto_rule_engine().store.list() == ()  # 규칙이 생기지 않았다
    assert _client().controls == []  # 이번 실행도 나가지 않았다
    assert len(_cards(api)) == 1  # 카드는 그대로(이번만 실행할 수 있다)


def test_manual_scenario_trigger_cannot_make_an_air_card(api):
    """센서 값 없이 공기질 카드를 만들지 않는다 — 시연 트리거로도."""
    res = api.post(f"/demo/scenario/{SCENARIO}")
    assert res.status_code == 409
    assert _cards(api) == []


def test_dismissed_card_is_not_reoffered_until_air_recovers(api):
    _power_on(api)
    assert _inject(api, "BAD")["check"] == "offered"
    assert _inject(api, "BAD")["check"] == "waiting_rearm"
    assert len(_cards(api)) == 1  # 떠 있는 공기질 카드는 하나
    card = _cards(api)[0]
    assert api.post(f"/suggestions/{card['id']}/reject").status_code == 200
    assert _inject(api, "VERY_BAD")["check"] == "waiting_rearm"
    assert _cards(api) == []
    assert _inject(api, "NORMAL")["check"] == "ok"
    assert _inject(api, "BAD")["check"] == "card_quiet"  # 다시 준비됐지만 내려간 뒤 30분 안
    assert _cards(api) == []
    body = _inject(api, "BAD", forget_recent=True)  # 리허설 되풀이(모의 전용)
    assert body["check"] == "offered" and body["suggestion"]["purpose"] == QUESTION


def test_quiet_hours_block_the_air_card_like_other_suggestions(api):
    _power_on(api)
    now = time.localtime()
    window = {"enabled": True, "start": f"{(now.tm_hour - 1) % 24:02d}:00", "end": f"{(now.tm_hour + 2) % 24:02d}:00"}
    assert api.put("/quiet-hours", json=window).status_code == 200
    assert _inject(api, "BAD")["check"] == "not_offered"
    assert _cards(api) == []
    assert api.put("/quiet-hours", json={"enabled": False}).status_code == 200
    assert _inject(api, "BAD")["check"] == "offered"  # 끝난 뒤에도 나쁘면 그때 제안


@pytest.mark.parametrize("scope", ["suggestions_and_auto", "suggestions_only"])
def test_pause_blocks_the_air_card_in_both_scopes(api, scope):
    _power_on(api)
    svc = deps.get_suggestion_service()
    if scope == "suggestions_and_auto":
        assert api.post("/dnd", json={"duration_minutes": 30}).status_code == 200
    else:
        from datetime import datetime, timedelta

        assert svc.carry_over_pause((datetime.now().astimezone() + timedelta(minutes=30)).isoformat())
    assert svc.dnd_scope() == scope
    assert _inject(api, "BAD")["check"] == "not_offered"
    assert _cards(api) == []


def test_a_pending_air_card_is_withdrawn_when_a_pause_starts(api):
    _power_on(api)
    assert _inject(api, "BAD")["check"] == "offered"
    assert len(_cards(api)) == 1
    assert api.post("/dnd", json={"duration_minutes": 30}).status_code == 200
    assert _cards(api) == []


def test_muted_air_card_is_not_offered_again(api):
    _power_on(api)
    _inject(api, "BAD")
    card = _cards(api)[0]
    assert api.post(f"/suggestions/{card['id']}/reject", json={"mute": True}).status_code == 200
    assert _inject(api, "NORMAL")["check"] == "ok"
    assert _inject(api, "BAD", forget_recent=True)["check"] == "not_offered"
    assert _cards(api) == []


# ── 판독 스레드·호출 ─────────────────────────────────────────────────────────────


def _count_reads(monkeypatch):
    count = [0]
    client = _client()
    original = client.get_status

    def counted(device_id):
        count[0] += 1
        return original(device_id)

    monkeypatch.setattr(client, "get_status", counted)
    return count


def test_no_poller_thread_when_thinq_is_off(monkeypatch):
    from rpi.api.air_quality_wiring import start_air_quality_poller

    _env(monkeypatch, None)
    _reset()
    try:
        assert start_air_quality_poller() is None
        assert not any(t.name == "air-quality-poll" for t in threading.enumerate())
    finally:
        _reset()


def test_no_thinq_read_without_an_added_purifier(api, monkeypatch):
    from rpi.api.air_quality_wiring import get_air_monitor

    deps.get_service()
    deps.get_appliance_registry().unregister_system("air_purifier")
    reads = _count_reads(monkeypatch)
    assert get_air_monitor().check_once() == "skipped:no_purifier"
    assert reads[0] == 0


def test_poll_skips_while_a_job_runs_and_when_the_call_budget_is_half_used(api, monkeypatch):
    from types import SimpleNamespace

    from rpi.api.air_quality_wiring import get_air_monitor

    _power_on(api)
    service = deps.get_service()
    reads = _count_reads(monkeypatch)
    real_status = service.status
    monkeypatch.setattr(service, "status", lambda: SimpleNamespace(running=True))
    assert get_air_monitor().check_once() == "skipped:job_running"
    monkeypatch.setattr(service, "status", real_status)
    monkeypatch.setattr(_client(), "calls_last_minute", lambda: 15, raising=False)  # 기본 상한 30의 절반
    assert get_air_monitor().check_once() == "skipped:rate_reserve"
    assert reads[0] == 0
    monkeypatch.setattr(_client(), "calls_last_minute", lambda: 14, raising=False)
    assert get_air_monitor().check_once() == "ok"
    assert reads[0] == 1


def test_poller_reads_on_its_own_thread(api, monkeypatch):
    from rpi.api import air_quality_wiring

    _power_on(api)
    seen = []
    client = _client()
    original = client.get_status

    def observed(device_id):
        seen.append(threading.current_thread().name)
        return original(device_id)

    monkeypatch.setattr(client, "get_status", observed)
    monkeypatch.setattr(air_quality_wiring, "FIRST_DELAY_SECONDS", 0.0)
    poller = air_quality_wiring.start_air_quality_poller()
    try:
        assert poller is not None and poller.interval_s == 120.0
        deadline = time.monotonic() + 5
        while not seen and time.monotonic() < deadline:
            time.sleep(0.01)
        assert seen == ["air-quality-poll"]
    finally:
        air_quality_wiring.stop_air_quality_poller()


# ── 리허설 주입: real에서는 거절 ───────────────────────────────────────────────────


@pytest.mark.parametrize("how", ["mode", "execution_mode"])
def test_demo_injection_is_refused_in_real_mode(api, monkeypatch, how):
    from rpi.controller.models import ExecutionMode
    from rpi.services.thinq import ThinqMode

    _power_on(api)
    controller = deps.get_service().thinq_controller
    if how == "mode":
        monkeypatch.setattr(controller, "mode", ThinqMode.REAL)
    else:
        monkeypatch.setattr(_client(), "execution_mode", ExecutionMode.REAL)
    res = api.post("/demo/thinq/air-quality", json={"level": "BAD"})
    assert res.status_code == 409
    assert "실제" in res.json()["detail"]
    state = api.get("/thinq/status/air_purifier").json()["state"]
    assert state["airQualitySensor"]["PM2Level"] == "GOOD"  # 바뀌지 않았다
    assert _cards(api) == []


def test_demo_injection_needs_thinq(monkeypatch):
    _env(monkeypatch, None)
    _reset()
    from rpi.main import app

    try:
        assert TestClient(app).post("/demo/thinq/air-quality", json={"level": "BAD"}).status_code == 404
    finally:
        _reset()


# ── 모의 클라우드(공식 SDK) ──────────────────────────────────────────────────────


def test_fake_cloud_bad_air_offers_a_mock_labelled_card(monkeypatch, tmp_path):
    pytest.importorskip("thinqconnect")
    from rpi.tools.fake_thinq_cloud import FakeThinqCloud

    cloud = FakeThinqCloud()
    cloud.start()
    _env(monkeypatch, "fake_cloud")
    monkeypatch.setenv("SIMPLELAY_THINQ_FAKE_CLOUD_URL", cloud.base_url)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", cloud.device_id("air_purifier"))
    monkeypatch.delenv("SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE", raising=False)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        assert _inject(api, "BAD")["check"] == "no_data"  # 모의 클라우드 기본은 꺼짐
        _command(api, "set_power", {"power": "POWER_ON"})
        body = _inject(api, "BAD")
        assert body["check"] == "offered"
        card = _cards(api)[0]
        assert card["is_demo"] is True and card["reason"].endswith("연습용 센서 값이에요.")
        assert card["commands"][0]["summary"] == "공기청정기(모의 클라우드) 풍량 강"
        res = api.post(f"/suggestions/{card['id']}/approve")
        assert _wait_done(api, res.json()["job_id"], timeout=10)["last_status"] == "succeeded"
        controls = [r["body"] for r in cloud.controls()]
        assert controls[-1] == {"airFlow": {"windStrength": "HIGH"}}
        assert len([c for c in controls if "airFlow" in c]) == 1
    finally:
        _reset()
        cloud.stop()


# ── 판독이 멈춰도 정지는 늦지 않는다(lifespan 켠 Uvicorn) ─────────────────────────────


def test_stop_is_not_delayed_by_a_stalled_air_quality_read(monkeypatch, tmp_path):
    """판독 스레드가 ThinQ 상태 조회에서 멈춘 채 ``/stop`` — ``request_stop`` 진입이 상한(0.5초) 안, 응답 200,
    서버 종료도 그 판독을 기다리지 않는다. 계측은 개발 PC의 HTTP 요청 시작부터 Python 진입까지(모터 정지 시간이 아니다)."""
    from rpi.api import air_quality_wiring
    from rpi.tests.test_eval_recheck2_stop import _cleanup, _db_app, _req
    from rpi.tests.test_eval_recheck2_stop import _client as _stop_client
    from rpi.tests.test_eval_recheck_stop import KEY, STOP_CALL_BOUND_S, STOP_RESPONSE_BOUND_S, _start, _timed
    from rpi.tests.test_startup_init_stop import _LifespanServer

    app = _db_app(monkeypatch, tmp_path)
    monkeypatch.setattr(air_quality_wiring, "FIRST_DELAY_SECONDS", 0.0)
    service = deps.get_service()
    called, stamp = _timed(monkeypatch, service._controller)  # noqa: SLF001 -- 시험 계측
    client = _client()
    entered, release = threading.Event(), threading.Event()
    original = client.get_status

    def stalled(device_id):
        if threading.current_thread().name == "air-quality-poll":
            entered.set()
            assert release.wait(30)
        return original(device_id)

    monkeypatch.setattr(client, "get_status", stalled)
    client._state["mock-purifier-01"]["operation"]["airPurifierOperationMode"] = "POWER_ON"  # noqa: SLF001
    server = _LifespanServer(app)
    threads: list[threading.Thread] = []
    results: dict = {}
    try:
        assert entered.wait(10), "판독 스레드가 ThinQ 조회에 닿지 않았다"
        stop_client = _stop_client()  # 측정 전에 준비(시험 클라이언트 생성 시간을 정지 지연에 넣지 않는다)
        started = time.perf_counter()
        stopper = _start(threads, lambda: _req(server.root, results, "stop", "POST", "/stop",
                                               headers={"X-API-Key": KEY}, client=stop_client))
        reached = called.wait(STOP_CALL_BOUND_S * 3)
        stopper.join(STOP_RESPONSE_BOUND_S)
        delay = stamp["at"] - started if reached else None
        print(f"\n[air poll stalled] 정지 진입 {'없음' if delay is None else f'{delay * 1000:.2f} ms'}, 응답 "
              f"{results['stop'].status_code if 'stop' in results else results.get('stop_error', '없음')}")
        assert reached and delay is not None and delay < STOP_CALL_BOUND_S, f"정지 진입 지연: {delay}"
        assert results["stop"].status_code == 200
        assert not release.is_set()  # 판독은 그때까지 멈춘 채였다
        closing = time.perf_counter()
        server.close()
        assert not server.thread.is_alive() and time.perf_counter() - closing < 10
    finally:
        release.set()
        for thread in threads:
            thread.join(10)
        server.close()
        _cleanup()
        reset_air_quality()
