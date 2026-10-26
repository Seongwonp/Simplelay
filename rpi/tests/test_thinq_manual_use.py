"""LG 앱·리모컨·가전 버튼으로 바꾼 상태 변화도 '직접 사용'으로 기록(2026-10-26, 심사 추천 ④).

공기질 판독(기본 120초)이 이미 읽는 상태를 바로 앞 판독과 견준다 — 새 클라우드 호출은 없다. 대응표 목적 문장과 같은
변화만, SimpleLay가 그 가전에 명령을 보낸 직후의 변화는 빼고, 실제(REAL) 클라이언트일 때만 습관 근거(REAL)로 적는다.
전부 모의다(실제 공기청정기에서 앱으로 바꿔 기록된 것을 본 적은 아직 없다).
"""

from __future__ import annotations

from datetime import datetime, time, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.controller.models import ExecutionMode
from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand
from rpi.intent.mock import FixedClock
from rpi.intent.models import UsageOutcome, UsageSource
from rpi.services.thinq.bindings import air_purifier_binding, washer_binding
from rpi.services.thinq.manual_use import SELF_CHANGE_WINDOW_SECONDS, ThinqManualUseTracker
from rpi.tests.test_air_quality_suggestion import _client, _command, _env, _reset

KST = timezone(timedelta(hours=9))
BINDING = air_purifier_binding("dev-1")
APPLIANCE = "air_purifier"
BANDS = (TimeBand('아침', time(6), time(11)), TimeBand('점심', time(11), time(14)),
         TimeBand('오후', time(14), time(17)), TimeBand('저녁', time(17), time(21)),
         TimeBand('야간', time(21), time(6)))


class _Mono:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _state(power="POWER_OFF", wind="LOW", job="CLEAN"):
    return {"operation": {"airPurifierOperationMode": power}, "airFlow": {"windStrength": wind},
            "airPurifierJobMode": {"currentJobMode": job}}


def _at(day, hh=22, mm=0):
    return datetime(2026, 10, day, hh, mm, tzinfo=KST)


def _tracker():
    mono = _Mono()
    return ThinqManualUseTracker(monotonic=mono), mono, InMemoryUsageLog([])


def _read(tracker, log, state, *, mode=ExecutionMode.REAL, now=None, binding=BINDING):
    return tracker.observe_read(APPLIANCE, binding, state, execution_mode=mode, usage_log=log,
                                now=now or _at(20))


# ── 판정(단위) ────────────────────────────────────────────────────────────────


def test_outside_power_on_is_recorded_once_as_direct_real():
    tracker, mono, log = _tracker()
    assert _read(tracker, log, _state("POWER_OFF")) == ()  # 첫 판독은 기준만
    mono.t += 120
    record, = _read(tracker, log, _state("POWER_ON"), now=_at(20, 22, 2))
    assert record.purpose == "공기청정기 켜줘"
    assert (record.outcome, record.source, record.execution_mode) == (
        UsageOutcome.SUCCEEDED, UsageSource.DIRECT, ExecutionMode.REAL)
    assert record.appliance_id == APPLIANCE and record.occurred_at == _at(20, 22, 2)  # 변화를 본 판독 시각
    mono.t += 120
    assert _read(tracker, log, _state("POWER_ON")) == ()  # 같은 상태를 다시 읽어도 또 세지 않는다
    assert len(log.records()) == 1


def test_baseline_read_records_nothing():
    tracker, _mono, log = _tracker()
    assert _read(tracker, log, _state("POWER_ON", "HIGH")) == ()
    assert log.records() == ()


def test_change_right_after_our_command_is_not_recorded():
    tracker, mono, log = _tracker()
    _read(tracker, log, _state("POWER_OFF"))
    mono.t += 60
    tracker.note_command(APPLIANCE)  # SimpleLay가 켰다(직접 명령·루틴·자동 실행·제안 승인 모두 실행기를 지난다)
    mono.t += 60
    assert _read(tracker, log, _state("POWER_ON")) == ()
    assert log.records() == ()
    # 기준은 새 값으로 옮겼다 — 창이 지난 뒤 사람이 앱으로 끄면 그것은 센다.
    mono.t += SELF_CHANGE_WINDOW_SECONDS + 1
    record, = _read(tracker, log, _state("POWER_OFF"))
    assert record.purpose == "공기청정기 꺼줘"


def test_command_before_previous_read_but_inside_window_still_suppresses():
    tracker, mono, log = _tracker()
    tracker.note_command(APPLIANCE)
    mono.t += 10
    _read(tracker, log, _state("POWER_OFF"))
    mono.t += 120  # 명령 뒤 130초 — 창(10분) 안이라 클라우드 상태가 늦게 바뀐 것일 수 있다
    assert _read(tracker, log, _state("POWER_ON")) == ()


def test_mock_mode_is_recorded_as_mock_and_never_teaches_a_habit():
    tracker, mono, log = _tracker()
    for day in (20, 21, 22):
        _read(tracker, log, _state("POWER_OFF"), mode=ExecutionMode.MOCK)
        mono.t += 120
        _read(tracker, log, _state("POWER_ON"), mode=ExecutionMode.MOCK, now=_at(day))
        mono.t += 120
    assert [r.execution_mode for r in log.records() if r.purpose == "공기청정기 켜줘"] == [ExecutionMode.MOCK] * 3
    detector = PatternDetector(log, FixedClock(_at(25, 21, 55)), PatternConfig(3, BANDS, ask_lead_minutes=10))
    assert detector.established() == ()


def test_unmapped_transition_is_not_recorded():
    tracker, mono, log = _tracker()
    _read(tracker, log, _state("POWER_ON", "LOW", "CLEAN"))
    mono.t += 120
    # 운전 모드는 대응표에 목적 문장이 없고, 바람 세기 '중'도 없다.
    assert _read(tracker, log, _state("POWER_ON", "MID", "SLEEP")) == ()
    assert log.records() == ()


def test_setting_changed_while_off_is_not_recorded():
    tracker, mono, log = _tracker()
    _read(tracker, log, _state("POWER_OFF", "LOW"))
    mono.t += 120
    assert _read(tracker, log, _state("POWER_OFF", "HIGH")) == ()


def test_empty_or_failed_read_keeps_the_baseline():
    tracker, mono, log = _tracker()
    _read(tracker, log, _state("POWER_OFF"))
    mono.t += 120
    assert _read(tracker, log, {}) == ()  # 빈 판독(실패는 판독 쪽에서 아예 넘기지 않는다)
    mono.t += 120
    record, = _read(tracker, log, _state("POWER_ON"))
    assert record.purpose == "공기청정기 켜줘"


def test_other_device_types_are_not_tracked():
    tracker, mono, log = _tracker()
    washer = washer_binding("w-1")
    _read(tracker, log, {"runState": {"currentState": "PAUSE"}}, binding=washer)
    mono.t += 120
    assert _read(tracker, log, {"runState": {"currentState": "RUNNING"}}, binding=washer) == ()


def test_three_days_of_app_use_become_a_habit_candidate():
    tracker, mono, log = _tracker()
    for day in (20, 21, 22):
        _read(tracker, log, _state("POWER_OFF"), now=_at(day, 21, 58))
        mono.t += SELF_CHANGE_WINDOW_SECONDS + 120
        _read(tracker, log, _state("POWER_ON"), now=_at(day, 22, 0))
        mono.t += 120
    detector = PatternDetector(log, FixedClock(_at(25, 21, 55)), PatternConfig(3, BANDS, ask_lead_minutes=10))
    (candidate, _ask), = detector.established()
    assert (candidate.purpose, candidate.appliance_id, candidate.occurrences, candidate.distinct_days) == (
        "공기청정기 켜줘", APPLIANCE, 3, 3)
    assert candidate.usual_time == "22:00"
    # 루틴 초안(``_thinq_draft``)이 쓰는 대응표가 그대로 같은 명령을 돌려준다.
    command = BINDING.command_for_purpose(APPLIANCE, candidate.purpose)
    assert (command.action, command.args_dict()) == ("set_power", {"power": "POWER_ON"})


# ── 배선(모의 ThinQ, 공기질 판독 경로) ──────────────────────────────────────────


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _manual_records():
    from rpi.api import deps

    return [r for r in deps.get_usage_log().records() if r.appliance_id == APPLIANCE]


def _set_power_outside(power):
    """LG 앱·리모컨으로 바꾼 것 흉내 — 모의 클라이언트 상태를 SimpleLay 명령 없이 바꾼다."""
    from rpi.services.thinq.mock_client import MOCK_PURIFIER_ID

    client = _client()
    state = client.get_status(MOCK_PURIFIER_ID)
    state.pop("airQualitySensor", None)
    state["operation"]["airPurifierOperationMode"] = power
    client.set_state(MOCK_PURIFIER_ID, state)


def test_poll_read_records_outside_change_as_mock(api):
    from rpi.api.air_quality_wiring import get_air_monitor

    monitor = get_air_monitor()
    monitor.check_once()  # 기준
    assert _manual_records() == []
    _set_power_outside("POWER_ON")
    monitor.check_once()
    record, = _manual_records()
    assert record.purpose == "공기청정기 켜줘"
    assert (record.source, record.execution_mode) == (UsageSource.DIRECT, ExecutionMode.MOCK)


def test_poll_read_after_simplelay_command_adds_nothing(api):
    from rpi.api.air_quality_wiring import get_air_monitor

    monitor = get_air_monitor()
    monitor.check_once()  # 기준(꺼짐)
    _command(api, "set_power", {"power": "POWER_ON"})
    own = _manual_records()  # 직접 명령은 종전대로 한 줄(목적 문장 있음)
    assert [r.purpose for r in own] == ["공기청정기 켜줘"]
    monitor.check_once()
    assert _manual_records() == own  # 판독이 본 같은 변화를 또 세지 않는다
