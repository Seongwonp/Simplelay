from datetime import datetime, time, timedelta, timezone

from rpi.intent.models import ExecutionMode, UsageSource

import pytest

from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import (
    InMemoryUsageLog,
    PatternConfig,
    PatternDetector,
    ProactiveSuggestionService,
    RuleBasedIntentResolver,
    SuggestionAlreadyApprovedError,
    TimeBand,
    UsageOutcome,
    UsageRecord,
)
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.verifier import MockVerifier


KST = timezone(timedelta(hours=9))
MORNING = TimeBand("아침", time(6, 0), time(10, 0))
CONFIG = PatternConfig(minimum_occurrences=3, time_bands=(MORNING,))


def at_morning(day: int) -> datetime:
    return datetime(2026, 7, day, 8, 0, tzinfo=KST)


def build_detector(records: tuple[UsageRecord, ...] = ()):
    clock = FixedClock(at_morning(23))
    usage_log = InMemoryUsageLog(records)
    return PatternDetector(usage_log, clock, CONFIG), clock, usage_log


def test_repeated_same_purpose_in_same_time_band_creates_suggestion():
    records = tuple(
        UsageRecord(at_morning(day), "즉석밥 데워줘", UsageOutcome.SUCCEEDED, execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for day in (20, 21, 22)
    )
    detector, clock, _ = build_detector(records)
    suggestions = ProactiveSuggestionService(
        detector, clock, MockPurposeExecutor()
    ).create_suggestions()

    assert len(suggestions) == 1
    assert suggestions[0].purpose == "즉석밥 데워줘"
    assert suggestions[0].time_band == "아침"
    assert suggestions[0].occurrences == 3


def test_one_off_usage_does_not_create_suggestion():
    detector, clock, _ = build_detector(
        (UsageRecord(at_morning(22), "즉석밥 데워줘", UsageOutcome.SUCCEEDED, execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT),)
    )

    suggestions = ProactiveSuggestionService(
        detector, clock, MockPurposeExecutor()
    ).create_suggestions()

    assert suggestions == ()


def test_suggestion_never_executes_before_approval_and_approval_is_one_time():
    # 실행까지 가는 제안은 대상 가전이 있어야 한다(B10) — 실사용 기록은
    # 폰이 항상 appliance_id를 실어 보내므로 여기서도 명시한다.
    records = tuple(
        UsageRecord(
            at_morning(day), "즉석밥 데워줘", UsageOutcome.SUCCEEDED,
            appliance_id="microwave",
            execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT,
        )
        for day in (20, 21, 22)
    )
    detector, clock, _ = build_detector(records)
    executor = MockPurposeExecutor(result="executed")
    service = ProactiveSuggestionService(detector, clock, executor)

    suggestion = service.create_suggestions()[0]

    assert executor.purposes == []
    assert service.pending() == (suggestion,)
    assert service.approve(suggestion.suggestion_id) == "executed"
    assert executor.purposes == ["즉석밥 데워줘"]
    assert service.pending() == ()
    with pytest.raises(SuggestionAlreadyApprovedError):
        service.approve(suggestion.suggestion_id)
    assert executor.purposes == ["즉석밥 데워줘"]


def test_approval_uses_existing_intent_and_closed_loop_controller():
    records = tuple(
        UsageRecord(
            at_morning(day), "즉석밥 데워줘", UsageOutcome.SUCCEEDED,
            appliance_id="microwave",
            execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT,
        )
        for day in (20, 21, 22)
    )
    detector, clock, usage_log = build_detector(records)
    grbl = MockGrblClient()
    normal_service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            grbl,
            MockVerifier([True, True, True]),
            MockAlertSink(),
            MockSafetyController(),
        ),
        usage_log=usage_log,
        clock=clock,
    )
    suggestions = ProactiveSuggestionService(detector, clock, normal_service)

    suggestion = suggestions.create_suggestions()[0]
    assert grbl.commands == []

    result = suggestions.approve(suggestion.suggestion_id)

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["즉석밥", "시작"]
    assert usage_log.records()[-1] == UsageRecord(
        at_morning(23), "즉석밥 데워줘", UsageOutcome.SUCCEEDED,
        appliance_id="microwave",
        execution_mode=ExecutionMode.MOCK, source=UsageSource.SUGGESTION,
    )


def test_failed_usage_is_logged_but_not_counted_as_learned_success():
    clock = FixedClock(at_morning(23))
    usage_log = InMemoryUsageLog()
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(),
            MockVerifier([False, False, False]),
            MockAlertSink(),
            MockSafetyController(),
        ),
        usage_log=usage_log,
        clock=clock,
    )

    result = service.execute_purpose("즉석밥 데워줘")

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert usage_log.records() == (
        UsageRecord(at_morning(23), "즉석밥 데워줘", UsageOutcome.FAILED, execution_mode=ExecutionMode.MOCK, source=UsageSource.DIRECT),
    )
    detector = PatternDetector(usage_log, clock, PatternConfig(1, (MORNING,)))
    assert detector.candidates() == ()


# ── 제안 미리보기 (steps) ────────────────────────────────────────────────


def test_suggestion_has_no_step_preview_without_a_resolver():
    records = tuple(
        UsageRecord(at_morning(day), "즉석밥 데워줘", UsageOutcome.SUCCEEDED, execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for day in (20, 21, 22)
    )
    detector, clock, _ = build_detector(records)

    suggestion = ProactiveSuggestionService(
        detector, clock, MockPurposeExecutor()
    ).create_suggestions()[0]

    assert suggestion.steps == ()


def test_suggestion_previews_steps_when_resolver_is_injected():
    records = tuple(
        UsageRecord(at_morning(day), "즉석밥 데워줘", UsageOutcome.SUCCEEDED, execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for day in (20, 21, 22)
    )
    detector, clock, _ = build_detector(records)

    suggestion = ProactiveSuggestionService(
        detector,
        clock,
        MockPurposeExecutor(),
        intent_resolver=RuleBasedIntentResolver(),
    ).create_suggestions()[0]

    assert suggestion.steps == ("즉석밥", "시작")


def test_suggestion_preview_failure_does_not_block_suggestion_creation():
    records = tuple(
        UsageRecord(at_morning(day), "규칙에 없는 목적", UsageOutcome.SUCCEEDED, execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for day in (20, 21, 22)
    )
    detector, clock, _ = build_detector(records)

    suggestions = ProactiveSuggestionService(
        detector,
        clock,
        MockPurposeExecutor(),
        intent_resolver=RuleBasedIntentResolver(),
    ).create_suggestions()

    assert len(suggestions) == 1
    assert suggestions[0].purpose == "규칙에 없는 목적"
    assert suggestions[0].steps == ()  # 미리보기만 실패, 제안 자체는 그대로 생성됨


def test_approve_still_reresolves_independently_of_the_preview():
    # 승인 시점의 실제 실행은 항상 SimpleLayService의 RuleBasedIntentResolver로
    # 다시 해석된다 — 미리보기에 쓴 리졸버가 승인 실행 결과를 대신하지 않는다.
    records = tuple(
        UsageRecord(
            at_morning(day), "즉석밥 데워줘", UsageOutcome.SUCCEEDED,
            appliance_id="microwave",
            execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT,
        )
        for day in (20, 21, 22)
    )
    detector, clock, usage_log = build_detector(records)
    grbl = MockGrblClient()
    normal_service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            grbl,
            MockVerifier([True, True, True]),
            MockAlertSink(),
            MockSafetyController(),
        ),
        usage_log=usage_log,
        clock=clock,
    )
    suggestions = ProactiveSuggestionService(
        detector, clock, normal_service, intent_resolver=RuleBasedIntentResolver()
    )

    suggestion = suggestions.create_suggestions()[0]
    assert suggestion.steps == ("즉석밥", "시작")  # 미리보기

    result = suggestions.approve(suggestion.suggestion_id)

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["즉석밥", "시작"]
