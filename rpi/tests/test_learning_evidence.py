from dataclasses import replace
from datetime import datetime, time, timedelta, timezone

import pytest

from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand, UsageRecord, UsageOutcome, ProactiveSuggestionService
from rpi.intent.models import ExecutionMode, UsageSource
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.services.persistence import SimpleLayDb
from rpi.tests.test_usage_appliance import _service

NOW = datetime(2026, 9, 21, 8, tzinfo=timezone(timedelta(hours=9)))
BAND = TimeBand('아침', time(6), time(10))


def record(days=1, **changes):
    return replace(UsageRecord(NOW - timedelta(days=days), '즉석밥 데워줘',
                              UsageOutcome.SUCCEEDED, 'microwave',
                              ExecutionMode.REAL, UsageSource.DIRECT), **changes)


def detector(records, now=NOW, band=BAND, **config):
    return PatternDetector(InMemoryUsageLog(records), FixedClock(now),
                           PatternConfig(3, (band,), **config))


def test_many_repeats_in_one_day_are_not_a_habit():
    assert detector([record()] * 20).candidates() == ()


def test_counts_and_distinct_days_are_separate_and_reason_matches():
    d = detector([record(1), record(1), record(2), record(3)])
    candidate, = d.candidates()
    assert (candidate.occurrences, candidate.distinct_days) == (4, 3)
    service = ProactiveSuggestionService(d, FixedClock(NOW), MockPurposeExecutor())
    suggestion, = service.create_suggestions()
    # 평가 14차(10/18) — 번역투('하셔서 여쭤봐요') 없이 본 사실만.
    assert suggestion.reason == '최근 28일 중 3일, 아침에 하셨어요'
    assert '여쭤' not in suggestion.reason


def test_old_and_future_records_cannot_supply_missing_days():
    assert detector([record(1), record(2), record(29), record(-1)]).candidates() == ()


def test_window_boundary_is_inclusive():
    assert len(detector([record(1), record(2), record(28)]).candidates()) == 1
    assert detector([record(1), record(2), record(28, occurred_at=NOW-timedelta(days=28, seconds=1))]).candidates() == ()


@pytest.mark.parametrize('changes', [
    {'execution_mode': ExecutionMode.MOCK},
    {'execution_mode': ExecutionMode.UNKNOWN},
    {'source': UsageSource.SUGGESTION},
    {'source': UsageSource.DEMO},
    {'source': UsageSource.UNKNOWN},
    {'outcome': UsageOutcome.FAILED},
])
def test_non_independent_real_success_is_excluded(changes):
    assert detector([record(1), record(2), record(3, **changes)]).candidates() == ()


def test_same_purpose_on_two_appliances_produces_two_habits():
    records = [record(d, appliance_id=a) for a in ('a', 'b') for d in (1, 2, 3)]
    assert [(c.appliance_id, c.occurrences) for c in detector(records).candidates()] == [('a', 3), ('b', 3)]


def test_midnight_does_not_turn_one_night_into_two_days():
    night = TimeBand('밤', time(22), time(2))
    now = NOW.replace(hour=1)
    records = [record(occurred_at=now-timedelta(hours=h)) for h in (0, 2, 24)]
    assert detector(records, now, night).candidates() == ()


def test_day_count_uses_local_time_even_with_utc_records():
    records = [record(d, occurred_at=(NOW-timedelta(days=d)).astimezone(timezone.utc)) for d in (1, 2, 3)]
    assert detector(records).candidates()[0].distinct_days == 3


@pytest.mark.parametrize('config', [{'window_days': 0}, {'minimum_days': 0}, {'window_days': 2}])
def test_invalid_day_limits_are_rejected(config):
    with pytest.raises(ValueError):
        detector([], **config)


def test_legacy_db_keeps_unknown_provenance(tmp_path):
    import sqlite3
    path = tmp_path / 'old.db'
    with sqlite3.connect(path) as conn:
        conn.execute('CREATE TABLE usage_log (id INTEGER PRIMARY KEY, occurred_at TEXT, purpose TEXT, outcome TEXT, appliance_id TEXT)')
        conn.execute('INSERT INTO usage_log VALUES (1, ?, ?, ?, ?)', (NOW.isoformat(), 'rice', 'succeeded', 'mw'))
    db = SimpleLayDb(str(path))
    old, = db.usage_records()
    assert old.execution_mode is ExecutionMode.UNKNOWN
    assert old.source is UsageSource.UNKNOWN
    db.append_usage(record())
    db.close()
    db = SimpleLayDb(str(path))
    assert db.usage_records() == (old, record())
    db.close()


@pytest.mark.parametrize('asynchronous', [False, True])
@pytest.mark.parametrize('source', list(UsageSource))
def test_execution_preserves_source_and_actual_controller_mode(asynchronous, source):
    from time import sleep
    log = InMemoryUsageLog()
    service = _service(log, FixedClock(NOW))
    execute = service.submit_purpose if asynchronous else service.execute_purpose
    execute('즉석밥 데워줘', 'microwave', usage_source=source)
    for _ in range(200):
        if log.records():
            break
        sleep(.01)
    actual, = log.records()
    assert actual.source is source
    assert actual.execution_mode is ExecutionMode.MOCK
    assert detector(log.records(), minimum_days=1).candidates() == ()


@pytest.mark.parametrize('asynchronous', [False, True])
def test_demo_approval_keeps_demo_source(asynchronous):
    from time import sleep
    log = InMemoryUsageLog()
    executor = _service(log, FixedClock(NOW))
    service = ProactiveSuggestionService(detector([]), FixedClock(NOW), executor)
    suggestion = service.create_demo_suggestion('즉석밥 데워줘', appliance_id='microwave')
    approve = service.approve_submit if asynchronous else service.approve
    approve(suggestion.suggestion_id)
    for _ in range(200):
        if log.records():
            break
        sleep(.01)
    assert log.records()[0].source is UsageSource.DEMO


@pytest.mark.parametrize('asynchronous', [False, True])
def test_natural_approval_does_not_reinforce_its_own_habit(asynchronous):
    from time import sleep
    log = InMemoryUsageLog([record(d) for d in (1, 2, 3)])
    clock = FixedClock(NOW)
    patterns = PatternDetector(log, clock, PatternConfig(3, (BAND,)))
    executor = _service(log, clock)
    service = ProactiveSuggestionService(patterns, clock, executor)
    suggestion, = service.create_suggestions()
    approve = service.approve_submit if asynchronous else service.approve
    approve(suggestion.suggestion_id)
    for _ in range(200):
        if len(log.records()) == 4:
            break
        sleep(.01)
    assert log.records()[-1].source is UsageSource.SUGGESTION
    assert patterns.candidates()[0].occurrences == 3
