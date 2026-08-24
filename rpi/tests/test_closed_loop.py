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


# ── on_progress ───────────────────────────────────────────────────────────


def test_on_progress_reports_each_verification_attempt():
    grbl = MockGrblClient()
    verifier = MockVerifier([False, False, True])
    reported: list = []
    controller = ClosedLoopController(
        grbl,
        verifier,
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
        on_progress=reported.append,
    )

    controller.execute(["시작"])

    assert [p.attempt for p in reported] == [1, 2, 3]
    assert [p.button for p in reported] == ["시작", "시작", "시작"]
    # 아직 이 버튼이 완료되지 않았으므로 completed_steps는 계속 0이다.
    assert [p.completed_steps for p in reported] == [0, 0, 0]
    assert [p.verification.pressed for p in reported] == [False, False, True]


def test_on_progress_completed_steps_increments_across_buttons():
    grbl = MockGrblClient()
    verifier = MockVerifier([True, True])
    reported: list = []
    controller = ClosedLoopController(
        grbl, verifier, MockAlertSink(), MockSafetyController(), on_progress=reported.append
    )

    controller.execute(["해동", "시작"])

    assert [p.button for p in reported] == ["해동", "시작"]
    assert [p.completed_steps for p in reported] == [0, 1]


def test_on_progress_reports_none_verification_on_grbl_error():
    grbl = MockGrblClient([RuntimeError("mock GRBL error"), None])
    verifier = MockVerifier([True])
    reported: list = []
    controller = ClosedLoopController(
        grbl, verifier, MockAlertSink(), MockSafetyController(), on_progress=reported.append
    )

    controller.execute(["시작"])

    assert reported[0].verification is None  # GRBL 에러 — 검증 시도조차 못 함
    assert reported[1].verification is not None


def test_on_progress_defaults_to_none_and_does_not_break_execution():
    grbl = MockGrblClient()
    verifier = MockVerifier([True])
    controller = ClosedLoopController(grbl, verifier, MockAlertSink(), MockSafetyController())

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SUCCEEDED


# ── 긴급 정지 (request_stop) ──────────────────────────────────────────────────


def test_emergency_stop_between_buttons():
    verifier = MockVerifier([True, True])
    alerts = MockAlertSink()
    safety = MockSafetyController()
    controller = None

    class StoppingGrbl(MockGrblClient):
        def press(self, command):
            super().press(command)
            controller.request_stop()  # 첫 누름 도중 정지 버튼이 눌린 상황

    grbl = StoppingGrbl()
    controller = ClosedLoopController(
        grbl, verifier, alerts, safety, retry_waiter=MockRetryWaiter()
    )

    result = controller.execute(["시작", "취소"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    # 첫 버튼은 완료로 기록되고, 두 번째 버튼은 아예 시작되지 않는다
    assert [b.button for b in result.buttons] == ["시작"]
    assert result.buttons[0].status is ButtonStatus.SUCCEEDED
    assert len(grbl.commands) == 1
    assert safety.reasons == ["emergency stop requested"]
    # 검증 실패가 아니므로 폐루프 실패 알림은 발생하지 않는다
    assert alerts.failures == []


def test_emergency_stop_between_retries():
    alerts = MockAlertSink()
    safety = MockSafetyController()
    controller = None

    class StopOnFirstFail(MockVerifier):
        def verify(self, button):
            result = super().verify(button)
            if not result.pressed:
                controller.request_stop()  # 1차 검증 실패 직후 정지 요청
            return result

    verifier = StopOnFirstFail([False, True])
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl, verifier, alerts, safety, retry_waiter=MockRetryWaiter()
    )

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    # 재시도 누름은 발생하지 않았다 — 정지는 재시도 경계에서 반영된다
    assert len(grbl.commands) == 1
    assert result.buttons == ()
    assert safety.reasons == ["emergency stop requested"]


def test_reset_stop_discards_stale_request():
    # 토큰 리셋 책임은 '실행을 시작시키는 쪽'에 있다(SimpleLayService._begin_run,
    # ActExecutor). execute()가 스스로 clear하지 않는 이유: job 접수 직후,
    # 실행 스레드가 뜨기 전에 들어온 정지 요청이 시작 시점 clear로 유실된다.
    controller, grbl, _, _, safety, _ = build_controller([True])

    controller.request_stop()  # 이전 세션의 stale 요청
    controller.reset_stop()    # 시작 주체가 명시적으로 리셋
    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert safety.reasons == []


def test_stop_request_before_execute_without_reset_is_honored():
    # 리셋 없이 남아 있는 정지 요청은 실행을 즉시 안전 정지시킨다 —
    # "접수 직후 정지"가 유실되지 않는 방향으로 기본값이 기울어 있다.
    controller, grbl, _, _, safety, _ = build_controller([True])

    controller.request_stop()
    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert grbl.commands == []
