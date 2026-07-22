from rpi.controller import ButtonStatus, ClosedLoopController, ExecutionStatus
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.verifier import MockVerifier


def build_controller(outcomes):
    grbl = MockGrblClient()
    verifier = MockVerifier(outcomes)
    alerts = MockAlertSink()
    safety = MockSafetyController()
    waiter = MockRetryWaiter()
    controller = ClosedLoopController(grbl, verifier, alerts, safety, retry_waiter=waiter)
    return controller, grbl, verifier, alerts, safety, waiter


def test_succeeds_on_first_attempt():
    controller, grbl, verifier, alerts, safety, waiter = build_controller([True])

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.buttons[0].status is ButtonStatus.SUCCEEDED
    assert result.buttons[0].attempts == 1
    assert len(grbl.commands) == 1
    assert grbl.commands[0].correction is None
    assert verifier.calls == ["시작"]
    assert alerts.failures == []
    assert safety.reasons == []
    assert waiter.calls == []


def test_recovers_on_third_attempt_with_corrections():
    controller, grbl, _, alerts, safety, waiter = build_controller([False, False, True])

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.buttons[0].attempts == 3
    assert [command.correction is None for command in grbl.commands] == [True, False, False]
    assert [command.correction.retry_number for command in grbl.commands[1:]] == [1, 2]
    assert all(command.correction.xy_adjustment_required for command in grbl.commands[1:])
    assert all(command.correction.increase_press_depth for command in grbl.commands[1:])
    assert alerts.failures == []
    assert safety.reasons == []
    assert waiter.calls == [("시작", 1), ("시작", 2)]


def test_stops_and_alerts_after_all_attempts_fail():
    controller, grbl, verifier, alerts, safety, waiter = build_controller([False, False, False])

    result = controller.execute(["시작", "취소"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.buttons[0].status is ButtonStatus.FAILED
    assert result.buttons[0].attempts == 3
    assert len(grbl.commands) == 3
    assert verifier.calls == ["시작", "시작", "시작"]
    assert alerts.failures == [("시작", 3)]
    assert len(safety.reasons) == 1
    assert "시작" in safety.reasons[0]
    assert waiter.calls == [("시작", 1), ("시작", 2)]


def test_retries_after_mock_grbl_error_without_verifying_failed_command():
    grbl = MockGrblClient([RuntimeError("mock GRBL error"), None])
    verifier = MockVerifier([True])
    controller = ClosedLoopController(
        grbl, verifier, MockAlertSink(), MockSafetyController()
    )

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.buttons[0].attempts == 2
    assert result.buttons[0].errors == ("mock GRBL error",)
    assert verifier.calls == ["시작"]
