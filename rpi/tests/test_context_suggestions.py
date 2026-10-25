"""환경 제안(2026-10-26) — 사람·방 밝기·공기청정기·공기질·황사 특보를 함께 보고 **묻기만** 한다.

규칙 A 불 끄면 수면 모드 · B 돌아왔을 때 공기 · C 황사 특보. 판정은 고정 시계·가짜 신호로, 카드 만들기·막기(조용한
시간·잠시 쉬기·다시 받지 않기·떠 있는 카드)는 모의 ThinQ 서버로 본다. 전부 모의다 — 실물에서 뜬 적은 아직 없다.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.scenarios.catalog import CONTEXT_SCENARIOS, ScenarioCatalog
from rpi.scenarios.engine import ScenarioEngine, ScenarioUnavailableError
from rpi.services.air_quality import AirQualityMonitor
from rpi.services.context_suggestions import (
    DUST_REASON,
    RULE_ARRIVAL,
    RULE_DUST,
    RULE_SLEEP,
    SLEEP_REASON,
    ContextRuleConfig,
    ContextSignals,
    ContextSuggestionMonitor,
    has_dust_warning,
    is_night,
)
from rpi.services.room_light import DARK, LIGHT, RoomLight
from rpi.tests.test_air_quality_suggestion import _client, _env, _reset

KST = timezone(timedelta(hours=9))
NIGHT = datetime(2026, 10, 26, 22, 30, tzinfo=KST)
EVENING = datetime(2026, 10, 26, 20, 0, tzinfo=KST)


class _Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


def _purifier(power="POWER_ON", mode="CLEAN", grade="GOOD"):
    return {"operation": {"airPurifierOperationMode": power},
            "airPurifierJobMode": {"currentJobMode": mode},
            "airFlow": {"windStrength": "LOW"},
            "airQualitySensor": {"PM2": 10, "PM2Level": grade, "totalPollutionLevel": grade}}


def _sleep_signals(**kw):
    base = dict(local_now=NIGHT, presence="present", lights_off_at=500.0, dark_for_s=180.0,
                purifier=_purifier(), wall_now=10_000.0)
    base.update(kw)
    return ContextSignals(**base)


def _arrival_signals(**kw):
    base = dict(local_now=EVENING, presence="present", arrival_at=9_900.0, wall_now=10_000.0,
                purifier=_purifier(power="POWER_OFF", grade="NORMAL"))
    base.update(kw)
    return ContextSignals(**base)


def _monitor(signals, *, clock=None, offer_result=object(), blocked=None, air_recent=False):
    box = {"s": signals, "offers": [], "notes": 0}

    def offer(scenario_id, reason):
        box["offers"].append((scenario_id, reason))
        return offer_result

    def note():
        box["notes"] += 1

    monitor = ContextSuggestionMonitor(
        lambda: box["s"], offer, blocked=blocked or (lambda: None), air_card_recent=lambda: air_recent,
        note_power_card=note, monotonic=clock or _Clock())
    return monitor, box


# ── A 불 끄면 수면 모드 ─────────────────────────────────────────────────────────


def test_sleep_rule_fires_when_lights_off_at_night_with_purifier_on():
    monitor, box = _monitor(_sleep_signals())
    assert monitor.check_once().startswith("sleep:offered")
    assert box["offers"] == [(RULE_SLEEP, SLEEP_REASON)]
    assert "불을 끄셨네요" in SLEEP_REASON and "밤" in SLEEP_REASON and "켜져" in SLEEP_REASON


@pytest.mark.parametrize("change, outcome", [
    ({"presence": "away"}, "absent"),
    ({"presence": None}, "absent"),
    ({"dark_for_s": 60.0}, "holding"),
    ({"dark_for_s": 3600.0}, "stale"),
    ({"local_now": EVENING}, "not_night"),
    ({"local_now": datetime(2026, 10, 27, 2, 0, tzinfo=KST)}, "not_night"),
    ({"purifier": _purifier(mode="SLEEP")}, "already_sleep"),
    ({"purifier": _purifier(power="POWER_OFF")}, "purifier_not_on"),
    ({"purifier": None}, "no_purifier_state"),
    ({"lights_off_at": None, "dark_for_s": None}, "no_lights_off"),
])
def test_sleep_rule_does_not_fire(change, outcome):
    monitor, box = _monitor(_sleep_signals(**change))
    assert monitor.check_once().startswith(f"sleep:{outcome}")
    assert box["offers"] == []


def test_sleep_rule_asks_once_per_lights_off_and_keeps_its_cooldown():
    clock = _Clock()
    monitor, box = _monitor(_sleep_signals(), clock=clock)
    assert monitor.check_once().startswith("sleep:offered")
    assert monitor.check_once().startswith("sleep:done")
    box["s"] = _sleep_signals(lights_off_at=900.0)  # 다시 켰다 끈 불
    clock.t += 3600
    assert monitor.check_once().startswith("sleep:cooldown")
    clock.t += 8 * 3600
    assert monitor.check_once().startswith("sleep:offered")
    assert len(box["offers"]) == 2


def test_sleep_rule_retries_when_the_suggestion_service_blocks_it():
    """조용한 시간·잠시 쉬기·다시 받지 않기로 막혔으면 기억을 바꾸지 않는다(다음 판정에서 다시 본다)."""
    monitor, box = _monitor(_sleep_signals(), offer_result=None)
    assert monitor.check_once().startswith("sleep:not_offered")
    assert monitor.check_once().startswith("sleep:not_offered")
    assert len(box["offers"]) == 2


def test_night_window_crosses_midnight():
    assert [is_night(NIGHT.replace(hour=h), 21, 2) for h in (20, 21, 23, 0, 1, 2, 12)] == [
        False, True, True, True, True, False, False]


def test_room_light_reports_lights_off_only_after_light():
    clock = _Clock()
    light = RoomLight(now=clock)
    light.observe(90)  # 켜진 뒤 처음부터 어두움 — 불을 끈 것이 아니다
    assert light.snapshot().state == DARK and light.dark_since() is None
    light = RoomLight(now=clock)
    light.observe(160)
    assert light.snapshot().state == LIGHT and light.dark_since() is None
    for _ in range(20):
        clock.t += 2
        light.observe(40)
    assert light.snapshot().state == DARK
    since = light.dark_since()
    assert since is not None and since <= clock.t
    clock.t += 60  # 표본이 끊기면 모른다
    assert light.dark_since() is None


# ── B 돌아왔을 때 공기 ──────────────────────────────────────────────────────────


def test_arrival_rule_fires_with_normal_air_and_lists_signals():
    monitor, box = _monitor(_arrival_signals())
    assert "arrival:offered" in monitor.check_once()
    assert box["offers"] == [(RULE_ARRIVAL, "다녀오셨어요. 실내 공기가 보통이에요. 공기청정기가 꺼져 있어요.")]
    assert box["notes"] == 1  # 공기질 제안과 재알림 기억을 함께 쓴다


def test_arrival_rule_mentions_dust_warning_even_with_good_air():
    monitor, box = _monitor(_arrival_signals(purifier=_purifier(power="POWER_OFF", grade="GOOD"), dust_warning=True))
    assert "arrival:offered" in monitor.check_once()
    assert box["offers"] == [(RULE_ARRIVAL, "다녀오셨어요. 황사 특보가 있어요. 공기청정기가 꺼져 있어요.")]
    assert "dust:" not in monitor.last_outcome  # 카드 하나를 만들면 그 판정은 끝


@pytest.mark.parametrize("change, outcome", [
    ({"purifier": _purifier(power="POWER_OFF", grade="GOOD")}, "air_ok"),
    ({"purifier": _purifier(power="POWER_ON", grade="BAD")}, "purifier_not_off"),
    ({"presence": "idle"}, "absent"),
    ({"arrival_at": None}, "no_arrival"),
    ({"wall_now": 9_900.0 + 11 * 60}, "window_passed"),
    ({"purifier": None}, "no_purifier_state"),
])
def test_arrival_rule_does_not_fire(change, outcome):
    monitor, box = _monitor(_arrival_signals(**change))
    assert f"arrival:{outcome}" in monitor.check_once()
    assert box["offers"] == []


def test_arrival_rule_waits_for_the_air_card_quiet_time():
    monitor, box = _monitor(_arrival_signals(), air_recent=True)
    assert "arrival:air_card_quiet" in monitor.check_once()
    assert box["offers"] == []


def test_arrival_rule_asks_once_per_arrival():
    monitor, box = _monitor(_arrival_signals())
    monitor.check_once()
    assert "arrival:done" in monitor.check_once()
    assert len(box["offers"]) == 1


# ── C 황사 특보 ─────────────────────────────────────────────────────────────────


def _dust_signals(**kw):
    base = dict(local_now=EVENING, presence="present", purifier=_purifier(power="POWER_OFF"), dust_warning=True)
    base.update(kw)
    return ContextSignals(**base)


def test_dust_rule_fires_on_a_new_warning_and_waits_for_someone():
    monitor, box = _monitor(_dust_signals(presence="away"))
    assert "dust:absent" in monitor.check_once()
    box["s"] = _dust_signals()
    assert "dust:offered" in monitor.check_once()
    assert box["offers"] == [(RULE_DUST, DUST_REASON)]
    assert "황사 특보" in DUST_REASON and "꺼져" in DUST_REASON
    assert "dust:no_new_warning" in monitor.check_once()  # 같은 특보로 또 묻지 않는다


def test_dust_rule_cooldown_six_hours():
    clock = _Clock()
    monitor, box = _monitor(_dust_signals(), clock=clock)
    assert "dust:offered" in monitor.check_once()
    box["s"] = _dust_signals(dust_warning=False)
    monitor.check_once()
    box["s"] = _dust_signals()
    clock.t += 3600
    assert "dust:cooldown" in monitor.check_once()
    clock.t += 5 * 3600
    assert "dust:offered" in monitor.check_once()


def test_dust_rule_skips_when_purifier_is_on():
    monitor, box = _monitor(_dust_signals(purifier=_purifier(power="POWER_ON")))
    assert "dust:purifier_on" in monitor.check_once()
    assert box["offers"] == []


def test_dust_warning_shape():
    assert has_dust_warning([{"kind": "황사", "icon": "dust"}])
    assert not has_dust_warning([{"kind": "호우", "icon": "rain"}])
    assert not has_dust_warning(None)


# ── 공통: 막기·한 번에 하나·설정 ────────────────────────────────────────────────


def test_blocked_by_estop_or_pending_card_offers_nothing():
    monitor, box = _monitor(_sleep_signals(dust_warning=True), blocked=lambda: "estop")
    assert monitor.check_once() == "blocked:estop"
    assert box["offers"] == []


def test_one_card_at_a_time():
    """돌아온 때 황사 특보가 있으면 B 카드 하나만 — 같은 특보로 C가 뒤따르지 않는다."""
    monitor, box = _monitor(_arrival_signals(dust_warning=True))
    monitor.check_once()
    assert "dust:no_new_warning" in monitor.check_once()
    assert [s for s, _ in box["offers"]] == [RULE_ARRIVAL]


def test_config_from_env():
    config = ContextRuleConfig.from_env({"SIMPLELAY_CONTEXT_NIGHT_START_HOUR": "22",
                                         "SIMPLELAY_CONTEXT_DUST_COOLDOWN_S": "60",
                                         "SIMPLELAY_CONTEXT_LIGHTS_OFF_HOLD_S": "abc",
                                         "SIMPLELAY_CONTEXT_NIGHT_END_HOUR": "99"})
    assert config.night_start_hour == 22 and isinstance(config.night_start_hour, int)
    assert config.dust_cooldown_s == 60.0
    assert config.lights_off_hold_s == 120.0 and config.night_end_hour == 2


def test_air_monitor_shares_card_quiet_with_context_cards():
    clock = _Clock()
    state = {"operation": {"airPurifierOperationMode": "POWER_OFF"},
             "airQualitySensor": {"PM2Level": "BAD", "PM2": 50}}
    offers = []
    monitor = AirQualityMonitor(lambda: state, lambda reason, power_off=False: offers.append(reason) or object(),
                                monotonic=clock)
    assert monitor.recent_state(300) is None
    monitor.note_external_card()
    assert monitor.card_recent()
    assert monitor.check_once() == "card_quiet"
    assert monitor.recent_state(300) is state
    clock.t += 400
    assert monitor.recent_state(300) is None
    clock.t += 45 * 60
    assert monitor.check_once() == "offered"


def test_context_cards_are_plain_and_not_auto():
    texts = [SLEEP_REASON, DUST_REASON, "다녀오셨어요. 실내 공기가 매우 나빠요. 황사 특보가 있어요. 공기청정기가 꺼져 있어요."]
    texts += [d.question for d in CONTEXT_SCENARIOS] + [d.name for d in CONTEXT_SCENARIOS]
    for text in texts:
        assert "!" not in text and "—" not in text and "·" not in text and "(" not in text, text
    assert all(not d.auto_allowed and d.trigger.kind == "context" for d in CONTEXT_SCENARIOS)


def test_context_cards_cannot_be_triggered_manually():
    class _Suggestions:
        def set_scenario_resolver(self, _):
            pass

    engine = ScenarioEngine(ScenarioCatalog(CONTEXT_SCENARIOS), _Suggestions(), object())
    with pytest.raises(ScenarioUnavailableError):
        engine.trigger_manual(RULE_SLEEP)


# ── 서버(모의 ThinQ): 카드가 되고, 실행하지 않고, 다른 제안처럼 막힌다 ────────────────────


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _server_monitor(signals):
    from rpi.api.context_suggestion_wiring import blocked_reason, offer

    return ContextSuggestionMonitor(lambda: signals, offer, blocked=blocked_reason, monotonic=_Clock())


def _context_cards(api):
    return [s for s in api.get("/suggestions").json() if s.get("scenario_id") in (RULE_SLEEP, RULE_ARRIVAL, RULE_DUST)]


def test_sleep_card_is_a_suggestion_and_never_executes(api):
    _client().controls.clear()
    monitor = _server_monitor(_sleep_signals())
    assert monitor.check_once().startswith("sleep:offered")
    cards = _context_cards(api)
    assert len(cards) == 1
    card = cards[0]
    assert card["purpose"] == "공기청정기를 수면 모드로 할까요?"
    assert card["reason"].startswith(SLEEP_REASON)
    assert [(c["action"], c["args"]) for c in card["commands"]] == [("set_job_mode", {"job_mode": "SLEEP"})]
    assert _client().controls == []  # 승인 전에는 아무것도 보내지 않는다
    assert api.get("/status").json()["running"] is False
    assert monitor.check_once() == "blocked:card_pending"  # 한 번에 카드 하나


def test_quiet_hours_block_context_cards(api):
    now = time.localtime()
    window = {"enabled": True, "start": f"{(now.tm_hour - 1) % 24:02d}:00", "end": f"{(now.tm_hour + 2) % 24:02d}:00"}
    assert api.put("/quiet-hours", json=window).status_code == 200
    assert _server_monitor(_sleep_signals()).check_once().startswith("sleep:not_offered")
    assert _context_cards(api) == []


def test_dnd_blocks_context_cards(api):
    assert api.post("/dnd", json={"duration_minutes": 30}).status_code == 200
    assert "arrival:not_offered" in _server_monitor(_arrival_signals()).check_once()
    assert _context_cards(api) == []


def test_muted_context_card_is_not_offered_again(api):
    monitor = _server_monitor(_dust_signals())
    assert "dust:offered" in monitor.check_once()
    card = _context_cards(api)[0]
    assert api.post(f"/suggestions/{card['id']}/reject", json={"mute": True}).status_code == 200
    monitor.forget_recent()
    assert "dust:not_offered" in monitor.check_once()
    assert _context_cards(api) == []


def test_estop_blocks_context_cards(api, monkeypatch):
    monkeypatch.setattr(type(deps.get_service()), "estop_latched", lambda self: True)
    assert _server_monitor(_sleep_signals()).check_once() == "blocked:estop"
    assert _context_cards(api) == []
