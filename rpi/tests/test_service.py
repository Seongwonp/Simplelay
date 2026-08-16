from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import InMemoryUsageLog, RuleBasedIntentResolver, UnknownIntentError
from rpi.verifier import MockVerifier


def test_rule_based_intent_executes_full_sequence():
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl, MockVerifier([True, True, True]), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(RuleBasedIntentResolver(), controller)

    result = service.execute_purpose("우유 데워줘")

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["해동", "시간 90초", "시작"]
    assert service.status().last_result is result
    assert service.status().running is False


def test_unknown_intent_does_not_leave_service_running():
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([]), MockAlertSink(), MockSafetyController()
        ),
    )

    try:
        service.execute_purpose("지원하지 않는 목적")
    except UnknownIntentError:
        pass
    else:
        raise AssertionError("UnknownIntentError was not raised")

    assert service.status().running is False


# ── execute_buttons (의도 해석 우회, 사용자 정의 가전용) ──────────────────────


def test_execute_buttons_runs_sequence_without_intent_resolution():
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl, MockVerifier([True, True]), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(RuleBasedIntentResolver(), controller)

    result = service.execute_buttons(("커스텀버튼A", "커스텀버튼B"))

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["커스텀버튼A", "커스텀버튼B"]
    assert service.status().last_result is result
    assert service.status().running is False


def test_execute_buttons_does_not_pollute_usage_log():
    usage_log = InMemoryUsageLog()
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([True]), MockAlertSink(), MockSafetyController()
        ),
        usage_log=usage_log,
    )

    service.execute_buttons(("버튼1",))

    # 목적 문자열이 없으므로 패턴 학습용 사용 로그에는 아무것도 안 남는다.
    assert usage_log.records() == ()


def test_execute_buttons_rejects_concurrent_execution():
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([True]), MockAlertSink(), MockSafetyController()
        ),
    )
    service._running = True

    try:
        service.execute_buttons(("버튼1",))
    except RuntimeError:
        pass
    else:
        raise AssertionError("RuntimeError was not raised")
