from datetime import time, timedelta
from types import SimpleNamespace

import pytest

from rpi.api.service import SimpleLayService
from rpi.controller import ExecutionMode, ExecutionResult, ExecutionStatus
from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand
from rpi.intent.completed_actions import CompletedActions
from rpi.intent.mock import FixedClock
from rpi.intent.models import UsageSource
from rpi.intent.rules import RuleBasedIntentResolver
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError
from rpi.services.persistence import SimpleLayDb
from rpi.tests.test_learning_evidence import NOW, BAND, record


class Controller:
    execution_mode = ExecutionMode.REAL
    status = ExecutionStatus.SUCCEEDED

    def __init__(self):
        self.calls = []

    def execute(self, buttons):
        self.calls.append(buttons)
        return ExecutionResult(self.status, ())


def setup(*, completions=None, now=NOW, band=BAND, environmental=None):
    clock = FixedClock(now)
    log = InMemoryUsageLog([record(d, occurred_at=now-timedelta(days=d)) for d in (1, 2, 3)])
    rules = RuleBasedIntentResolver()
    controller = Controller()
    executor = SimpleLayService(rules, controller, usage_log=log, clock=clock,
                                completed_actions=completions)
    detector = PatternDetector(log, clock, PatternConfig(3, (band,)))
    suggestions = ProactiveSuggestionService(
        detector, clock, executor, intent_resolver=rules, environmental=environmental,
        completed_actions=executor.completed_actions,
    )
    return suggestions, executor, controller, clock, log


def test_completion_retires_pending_and_prevents_stale_approval():
    suggestions, executor, controller, _, _ = setup()
    card, = suggestions.create_suggestions()
    executor.execute_purpose('밥 데워줘', 'microwave')
    assert suggestions.pending() == ()
    with pytest.raises(UnknownSuggestionError):
        suggestions.approve(card.suggestion_id)
    assert len(controller.calls) == 1
    assert suggestions.create_suggestions() == ()


def test_completion_before_card_creation_blocks_only_current_band():
    suggestions, executor, _, clock, _ = setup()
    executor.execute_purpose('햇반 데워줘', 'microwave')
    assert suggestions.create_suggestions() == ()
    clock.set(clock.now()+timedelta(days=1))
    assert len(suggestions.create_suggestions()) == 1


@pytest.mark.parametrize('purpose,target', [('해동해줘', 'microwave'), ('즉석밥 데워줘', 'other')])
def test_unrelated_completion_does_not_hide_habit(purpose, target):
    suggestions, executor, _, _, _ = setup()
    executor.execute_purpose(purpose, target)
    assert len(suggestions.create_suggestions()) == 1


@pytest.mark.parametrize('mode,status,source', [
    (ExecutionMode.MOCK, ExecutionStatus.SUCCEEDED, UsageSource.DIRECT),
    (ExecutionMode.UNKNOWN, ExecutionStatus.SUCCEEDED, UsageSource.DIRECT),
    (ExecutionMode.REAL, ExecutionStatus.FAILED, UsageSource.DIRECT),
    (ExecutionMode.REAL, ExecutionStatus.SAFETY_STOPPED, UsageSource.DIRECT),
    (ExecutionMode.REAL, ExecutionStatus.SUCCEEDED, UsageSource.DEMO),
    (ExecutionMode.REAL, ExecutionStatus.SUCCEEDED, UsageSource.SUGGESTION),
    (ExecutionMode.REAL, ExecutionStatus.SUCCEEDED, UsageSource.UNKNOWN),
])
def test_only_successful_real_direct_execution_suppresses(mode, status, source):
    suggestions, executor, controller, _, _ = setup()
    controller.execution_mode, controller.status = mode, status
    executor.execute_purpose('즉석밥 데워줘', 'microwave', usage_source=source)
    assert len(suggestions.create_suggestions()) == 1


def test_complete_manual_sequence_suppresses_without_inventing_learning_record():
    suggestions, executor, _, _, log = setup()
    executor.execute_buttons(('즉석밥', '시작'), 'microwave')
    assert suggestions.create_suggestions() == ()
    assert len(log.records()) == 3


@pytest.mark.parametrize('buttons', [('즉석밥',), ('시작',), ('시작', '즉석밥')])
def test_partial_or_reordered_buttons_do_not_count_as_completed_routine(buttons):
    suggestions, executor, _, _, _ = setup()
    executor.execute_buttons(buttons, 'microwave')
    assert len(suggestions.create_suggestions()) == 1


def test_night_completion_spans_midnight_but_not_the_next_night():
    now = NOW.replace(hour=23)
    suggestions, executor, _, clock, _ = setup(now=now, band=TimeBand('밤', time(22), time(2)))
    executor.execute_purpose('즉석밥 데워줘', 'microwave')
    clock.set(now+timedelta(hours=2))
    assert suggestions.create_suggestions() == ()
    clock.set(now+timedelta(days=1))
    assert len(suggestions.create_suggestions()) == 1


def test_persisted_completion_survives_reopen(tmp_path):
    path = str(tmp_path/'state.db')
    def store(db):
        return CompletedActions(lambda: db.load_setting('completed_actions'),
                                lambda value: db.save_setting('completed_actions', value))
    db = SimpleLayDb(path)
    _, executor, _, _, _ = setup(completions=store(db))
    executor.execute_purpose('밥 데워줘', 'microwave')
    db.close()
    db = SimpleLayDb(path)
    suggestions, _, _, _, _ = setup(completions=store(db))
    assert suggestions.create_suggestions() == ()
    db.close()


def test_demo_card_remains_available_for_explicit_rehearsal():
    suggestions, executor, controller, _, _ = setup()
    executor.execute_purpose('즉석밥 데워줘', 'microwave')
    card = suggestions.create_demo_suggestion('즉석밥 데워줘', appliance_id='microwave')
    suggestions.approve(card.suggestion_id)
    assert len(controller.calls) == 2


def test_persistence_failure_does_not_turn_physical_success_into_failure():
    def fail(_):
        raise OSError('disk full')
    suggestions, executor, _, _, _ = setup(completions=CompletedActions(save=fail))
    result = executor.execute_purpose('즉석밥 데워줘', 'microwave')
    assert result.status is ExecutionStatus.SUCCEEDED
    assert suggestions.create_suggestions() == ()


@pytest.mark.parametrize('asynchronous', [False, True])
def test_completion_during_approval_resolution_cannot_execute_again(asynchronous):
    suggestions, executor, controller, clock, _ = setup()
    card, = suggestions.create_suggestions()
    class RaceResolver(RuleBasedIntentResolver):
        def resolve(self, purpose):
            # Deterministic simulation of a direct run completing after the
            # suggestion claim but before the atomic execution-start gate.
            executor.completed_actions.remember('microwave', '즉석밥 데워줘',
                                                ('즉석밥', '시작'), clock.now())
            return super().resolve(purpose)
    executor._intent = RaceResolver()
    approve = suggestions.approve_submit if asynchronous else suggestions.approve
    with pytest.raises(UnknownSuggestionError):
        approve(card.suggestion_id)
    assert controller.calls == []
    assert suggestions.pending() == ()
    assert executor._running is False


def test_environment_recommendation_waits_after_direct_completion():
    env = SimpleNamespace(candidate=lambda: SimpleNamespace(
        purpose='에어컨 켜줘', appliance_id='aircon', reason='더워요'))
    suggestions, executor, _, clock, _ = setup(environmental=env)
    executor.execute_purpose('에어컨 켜줘', 'aircon')
    assert all(s.time_band != '환경' for s in suggestions.create_suggestions())
    clock.set(clock.now()+timedelta(minutes=15))
    assert any(s.time_band == '환경' for s in suggestions.create_suggestions())


def test_stop_request_prevents_success_from_becoming_completion_or_learning():
    suggestions, executor, controller, _, log = setup()
    def stopped(buttons):
        executor.emergency_stop_report()
        return ExecutionResult(ExecutionStatus.SUCCEEDED, ())
    controller.execute = stopped
    executor.execute_purpose('즉석밥 데워줘', 'microwave')
    assert log.records()[-1].outcome.value == 'failed'
    assert len(suggestions.create_suggestions()) == 1


def test_completed_at_exact_band_start_is_included_but_future_is_not():
    completions = CompletedActions()
    completions.remember('microwave', '즉석밥 데워줘', ('즉석밥', '시작'), NOW.replace(hour=6))
    suggestions, _, _, _, _ = setup(completions=completions)
    assert suggestions.create_suggestions() == ()
    future = CompletedActions()
    future.remember('microwave', '즉석밥 데워줘', ('즉석밥', '시작'), NOW+timedelta(minutes=1))
    suggestions, _, _, _, _ = setup(completions=future)
    assert len(suggestions.create_suggestions()) == 1


def test_expiration_during_resolution_is_checked_at_execution_gate():
    suggestions, executor, controller, clock, _ = setup()
    card, = suggestions.create_suggestions()
    class SlowResolver(RuleBasedIntentResolver):
        def resolve(self, purpose):
            clock.set(NOW.replace(hour=10))
            return super().resolve(purpose)
    executor._intent = SlowResolver()
    with pytest.raises(UnknownSuggestionError):
        suggestions.approve_submit(card.suggestion_id)
    assert controller.calls == []


def test_async_manual_completion_blocks_existing_card():
    from time import sleep
    suggestions, executor, _, _, _ = setup()
    card, = suggestions.create_suggestions()
    executor.submit_buttons(('즉석밥', '시작'), 'microwave')
    for _ in range(200):
        if not executor._running:
            break
        sleep(.01)
    assert executor._running is False
    assert suggestions.pending() == ()
    with pytest.raises(UnknownSuggestionError):
        suggestions.approve_submit(card.suggestion_id)


def test_success_during_preview_does_not_leave_a_new_card():
    suggestions, executor, _, _, _ = setup()
    class SlowPreview(RuleBasedIntentResolver):
        def resolve(self, purpose):
            executor.execute_purpose('즉석밥 데워줘', 'microwave')
            return super().resolve(purpose)
    suggestions._intent_resolver = SlowPreview()
    assert suggestions.create_suggestions() == ()
    assert suggestions.pending() == ()
