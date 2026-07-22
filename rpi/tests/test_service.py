from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver, UnknownIntentError
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
