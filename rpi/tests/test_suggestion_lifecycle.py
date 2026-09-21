"""제안의 시간 경계·거절·재시작 계약. 실제 실행 없이 고정 시계로 검증."""
from datetime import datetime, time, timedelta, timezone

from rpi.intent.models import ExecutionMode, UsageSource

import pytest

from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand
from rpi.intent import UsageOutcome, UsageRecord
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError


def setup_service(*, band=None, now=None, executor=None, **kwargs):
    now = now or datetime(2026, 9, 21, 8, tzinfo=timezone(timedelta(hours=9)))
    clock = FixedClock(now)
    band = band or TimeBand('morning', time(6), time(10))
    log = InMemoryUsageLog(tuple(
        UsageRecord(now - timedelta(days=d), 'rice', UsageOutcome.SUCCEEDED, 'mw', execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for d in (1, 2, 3)
    ))
    detector = PatternDetector(log, clock, PatternConfig(3, (band,)))
    executor = executor or MockPurposeExecutor()
    return ProactiveSuggestionService(detector, clock, executor, **kwargs), clock, executor


def test_skip_blocks_same_band_but_allows_next_day():
    svc, clock, _ = setup_service()
    first, = svc.create_suggestions()
    svc.reject(first.suggestion_id)
    assert svc.create_suggestions() == ()
    clock.set(clock.now() + timedelta(days=1))
    assert len(svc.create_suggestions()) == 1


def test_expired_card_cannot_be_listed_or_approved():
    svc, clock, executor = setup_service()
    first, = svc.create_suggestions()
    clock.set(clock.now().replace(hour=10))
    with pytest.raises(UnknownSuggestionError):
        svc.approve(first.suggestion_id)
    assert executor.purposes == []
    assert svc.pending() == ()


def test_approved_routine_is_not_immediately_resuggested():
    svc, _, executor = setup_service()
    first, = svc.create_suggestions()
    svc.approve(first.suggestion_id)
    assert svc.create_suggestions() == ()
    assert executor.purposes == ['rice']


def test_night_band_skip_survives_midnight_and_expires_at_end():
    svc, clock, _ = setup_service(
        band=TimeBand('night', time(22), time(2)),
        now=datetime(2026, 9, 21, 23, tzinfo=timezone.utc),
    )
    first, = svc.create_suggestions()
    svc.reject(first.suggestion_id)
    clock.set(clock.now() + timedelta(hours=2))
    assert svc.create_suggestions() == ()
    clock.set(clock.now().replace(hour=23))
    assert len(svc.create_suggestions()) == 1


def test_full_day_band_expires_at_next_midnight():
    svc, clock, _ = setup_service(band=TimeBand('all', time(0), time(0)))
    first, = svc.create_suggestions()
    clock.set(clock.now() + timedelta(days=1))
    assert svc.pending() == ()
    assert svc.create_suggestions()[0].suggestion_id != first.suggestion_id


def test_demo_card_has_bounded_lifetime_and_restart_unique_id():
    svc, clock, _ = setup_service()
    first = svc.create_demo_suggestion('rice', appliance_id='mw')
    other, _, _ = setup_service()
    assert other.create_demo_suggestion('rice', appliance_id='mw').suggestion_id != first.suggestion_id
    clock.set(clock.now() + timedelta(minutes=15))
    assert svc.pending() == ()


def test_failed_submission_keeps_card_and_allows_retry():
    class Failing(MockPurposeExecutor):
        def execute_purpose(self, purpose, appliance_id=None, *, usage_source=UsageSource.DIRECT):
            raise RuntimeError('busy')
    svc, _, _ = setup_service(executor=Failing())
    first, = svc.create_suggestions()
    with pytest.raises(RuntimeError):
        svc.approve(first.suggestion_id)
    assert svc.pending() == (first,)
    assert svc.create_suggestions() == (first,)


def test_skip_survives_database_reopen(tmp_path):
    from rpi.intent.cooldowns import SuggestionCooldowns
    from rpi.services.persistence import SimpleLayDb

    path = str(tmp_path / 'state.db')
    def store(db):
        return SuggestionCooldowns(
            load=lambda: db.load_setting('suggestion_cooldowns'),
            save=lambda value: db.save_setting('suggestion_cooldowns', value),
        )
    db = SimpleLayDb(path)
    svc, _, _ = setup_service(cooldowns=store(db))
    svc.reject(svc.create_suggestions()[0].suggestion_id)
    db.close()
    db = SimpleLayDb(path)
    try:
        restored, clock, _ = setup_service(cooldowns=store(db))
        assert restored.create_suggestions() == ()
        clock.set(clock.now() + timedelta(days=1))
        assert len(restored.create_suggestions()) == 1
    finally:
        db.close()


def test_failed_cooldown_save_does_not_drop_card_or_execute():
    from rpi.intent.cooldowns import SuggestionCooldowns
    def fail(value):
        raise OSError('disk full')
    svc, _, executor = setup_service(cooldowns=SuggestionCooldowns(save=fail))
    first, = svc.create_suggestions()
    with pytest.raises(OSError):
        svc.reject(first.suggestion_id)
    assert svc.pending() == (first,)
    with pytest.raises(OSError):
        svc.approve(first.suggestion_id)
    assert executor.purposes == []
    assert svc.pending() == (first,)


def test_environment_skip_is_temporary_and_appliance_specific():
    from rpi.intent.environment import EnvironmentalCandidate
    class Environment:
        appliance = 'ac1'
        def candidate(self):
            return EnvironmentalCandidate('cool', 'hot', self.appliance)
    env = Environment()
    svc, clock, _ = setup_service(environmental=env)
    first = next(s for s in svc.create_suggestions() if s.time_band == '환경')
    svc.reject(first.suggestion_id)
    assert not any(s.time_band == '환경' for s in svc.create_suggestions())
    env.appliance = 'ac2'
    assert any(s.appliance_id == 'ac2' for s in svc.create_suggestions())
    clock.set(clock.now() + timedelta(minutes=15))
    env.appliance = 'ac1'
    assert any(s.appliance_id == 'ac1' for s in svc.create_suggestions())


def test_concurrent_approvals_only_execute_once():
    from concurrent.futures import ThreadPoolExecutor
    from rpi.intent.suggestions import SuggestionAlreadyApprovedError
    svc, _, executor = setup_service()
    first, = svc.create_suggestions()
    def approve():
        try:
            svc.approve(first.suggestion_id)
            return True
        except SuggestionAlreadyApprovedError:
            return False
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: approve(), range(2)))
    assert results.count(True) == 1
    assert executor.purposes == ['rice']


def test_slow_preview_does_not_create_a_card_after_band_end():
    svc, clock, _ = setup_service()
    class SlowResolver:
        def resolve(self, purpose):
            clock.set(clock.now().replace(hour=10))
            return ('start',)
    svc._intent_resolver = SlowResolver()
    assert svc.create_suggestions() == ()
