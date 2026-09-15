"""Closed-loop orchestration with bounded recovery and fail-safe behavior."""

import threading
from collections.abc import Callable

from rpi.verifier import VerificationResult, Verifier

from .layered import (
    DEFAULT_ACCEPTANCE_REINPUTS,
    AcceptanceVerifier,
    OperationVerifier,
)
from .models import (
    ButtonResult,
    ButtonStatus,
    ExecutionMode,
    ExecutionProgress,
    ExecutionResult,
    ExecutionStatus,
    PressCommand,
    VerificationLayer,
)
from .ports import AlertSink, GrblClient, NoOpRetryWaiter, RetryWaiter, SafetyController
from .progress import ProgressCallback
from .retry import DocumentedRetryPolicy, RetryPolicy


class _EmergencyStopRequested(Exception):
    """Internal control-flow signal: a stop was requested mid-execution."""


class ClosedLoopController:
    def __init__(
        self,
        grbl: GrblClient,
        verifier: Verifier,
        alerts: AlertSink,
        safety: SafetyController,
        retry_policy: RetryPolicy | None = None,
        retry_waiter: RetryWaiter | None = None,
        on_progress: ProgressCallback | None = None,
        step_pacer: Callable[[str, int], None] | None = None,
        acceptance: AcceptanceVerifier | None = None,
        operation: OperationVerifier | None = None,
        acceptance_reinputs: int = DEFAULT_ACCEPTANCE_REINPUTS,
    ) -> None:
        if acceptance_reinputs < 0:
            raise ValueError("acceptance_reinputs must not be negative")
        self._grbl = grbl
        self._verifier = verifier
        self._alerts = alerts
        self._safety = safety
        self._retry_policy = retry_policy or DocumentedRetryPolicy()
        self._retry_waiter = retry_waiter or NoOpRetryWaiter()
        self._on_progress = on_progress
        self._step_pacer = step_pacer
        # L2·L3 검증기는 선택이다(layered.py). 없으면 L1만 쓰는 종전 동작.
        self._acceptance = acceptance
        self._operation = operation
        self._acceptance_reinputs = acceptance_reinputs
        # /stop(긴급 정지)용. 실행은 별도 스레드(asyncio.to_thread)에서 돌고
        # 정지 요청은 FastAPI 요청 스레드에서 오므로 threading.Event를 쓴다.
        self._stop_requested = threading.Event()

    @property
    def execution_mode(self) -> ExecutionMode:
        """이 컨트롤러가 실제 액추에이터를 움직였는가.

        판단은 **자기가 쥔 클라이언트**에게 묻는다. 서버 전역 설정으로
        정하면, 같은 서버가 로컬 mock과 원격 실기기를 함께 쓰는 통합
        기간에 이력이 둘을 섞어버린다.
        """
        return getattr(
            self._grbl, "execution_mode", ExecutionMode.UNKNOWN
        )

    def request_stop(self) -> None:
        """Ask a running execute() to safety-stop at the next button/attempt
        boundary."""
        self._stop_requested.set()

    def reset_stop(self) -> None:
        """Discard any stale stop request. 호출 책임은 '실행을 시작시키는 쪽'
        (SimpleLayService._begin_run, ActExecutor)에 있다 — execute()가
        스스로 clear하면, job 접수 직후 스레드가 뜨기 전에 들어온 정지
        요청이 시작 시점에 지워져 유실된다(리뷰 지적 #5)."""
        self._stop_requested.clear()

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult:
        results: list[ButtonResult] = []
        completed_steps = 0
        for button in buttons:
            try:
                self._check_stop()
                result = self._execute_button(button, completed_steps)
            except _EmergencyStopRequested:
                self._safety.stop("emergency stop requested")
                return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, tuple(results))
            results.append(result)
            if result.status is ButtonStatus.SUCCEEDED:
                completed_steps += 1
            if result.status is ButtonStatus.FAILED:
                if result.failed_layer is VerificationLayer.ACCEPTANCE:
                    reason = (
                        f"L2 appliance did not accept {button} after "
                        f"{result.reinputs} re-input(s)"
                    )
                else:
                    reason = f"verification failed for {button} after {result.attempts} attempts"
                self._safety.stop(reason)
                self._alerts.notify_failure(button, result.attempts)
                return ExecutionResult(
                    ExecutionStatus.SAFETY_STOPPED,
                    tuple(results),
                    failed_layer=result.failed_layer,
                )
        return self._verify_operation(tuple(buttons), tuple(results))

    def _verify_operation(
        self, buttons: tuple[str, ...], results: tuple[ButtonResult, ...]
    ) -> ExecutionResult:
        """L3 — 시퀀스를 다 넣은 뒤 한 번만 판정한다. 실패해도 다시 누르지 않는다."""
        if self._operation is None:
            return ExecutionResult(ExecutionStatus.SUCCEEDED, results)
        try:
            self._check_stop()
        except _EmergencyStopRequested:
            self._safety.stop("emergency stop requested")
            return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, results)
        outcome = self._operation.verify_operation(buttons)
        if outcome.passed:
            return ExecutionResult(
                ExecutionStatus.SUCCEEDED, results, operation=outcome
            )
        self._safety.stop(f"L3 operation not confirmed: {outcome.detail}")
        self._alerts.notify_operation_unconfirmed(outcome.detail)
        return ExecutionResult(
            ExecutionStatus.SAFETY_STOPPED,
            results,
            failed_layer=VerificationLayer.OPERATION,
            operation=outcome,
        )

    def _execute_button(self, button: str, completed_steps: int) -> ButtonResult:
        """버튼 하나: L1(보정 재시도) → L2(불수용이면 같은 입력 재입력).

        누름 횟수 상한은 ``max_attempts × (1 + acceptance_reinputs)``다 --
        재입력 한 번은 L1 보정 루프를 한 번 더 도는 것이라, 재입력 중에
        미끄러진 누름도 보정된다. L2 검증기가 없으면 상한은 종전대로
        ``max_attempts``다.
        """
        errors: list[str] = []
        last_verification = None
        presses = 0
        reinputs = 0
        while True:
            pressed = False
            for attempt in range(1, self._retry_policy.max_attempts + 1):
                if presses > 0:
                    self._check_stop()  # 재시도·재입력 경계에서도 정지 요청 반영
                    self._retry_waiter.wait(button, presses)
                correction = (
                    None
                    if attempt == 1
                    else self._retry_policy.correction_for(attempt - 1)
                )
                presses += 1
                try:
                    self._grbl.press(PressCommand(button, correction))
                except Exception as exc:  # adapter errors are recoverable within the hard limit
                    errors.append(str(exc))
                    self._report_progress(button, presses, completed_steps, None)
                    continue

                last_verification = self._verifier.verify(button)
                self._report_progress(button, presses, completed_steps, last_verification)
                if last_verification.pressed:
                    pressed = True
                    break

            if not pressed:
                return ButtonResult(
                    button,
                    ButtonStatus.FAILED,
                    presses,
                    last_verification,
                    tuple(errors),
                    failed_layer=VerificationLayer.PRESS,
                    reinputs=reinputs,
                )

            if self._acceptance is None:
                self._pace(button, completed_steps)
                return ButtonResult(
                    button,
                    ButtonStatus.SUCCEEDED,
                    presses,
                    last_verification,
                    tuple(errors),
                    reinputs=reinputs,
                )

            accepted = self._acceptance.verify_acceptance(button)
            if accepted.passed:
                self._pace(button, completed_steps)
                return ButtonResult(
                    button,
                    ButtonStatus.SUCCEEDED,
                    presses,
                    last_verification,
                    tuple(errors),
                    reinputs=reinputs,
                )
            errors.append(f"L2: {accepted.detail}" if accepted.detail else "L2: not accepted")
            if reinputs >= self._acceptance_reinputs:
                return ButtonResult(
                    button,
                    ButtonStatus.FAILED,
                    presses,
                    last_verification,
                    tuple(errors),
                    failed_layer=VerificationLayer.ACCEPTANCE,
                    reinputs=reinputs,
                )
            reinputs += 1

    def _check_stop(self) -> None:
        if self._stop_requested.is_set():
            raise _EmergencyStopRequested()

    def _report_progress(
        self,
        button: str,
        attempt: int,
        completed_steps: int,
        verification: VerificationResult | None,
    ) -> None:
        if self._on_progress is None:
            return
        self._on_progress(
            ExecutionProgress(button, attempt, completed_steps, verification)
        )

    def _pace(self, button: str, completed_steps: int) -> None:
        """데모 페이싱 훅 -- 기본 None이면 지연 0(실동작·테스트 불변).
        SIMPLELAY_DEMO_PACING이 켜지면 컨트롤러 팩토리가 sleep을 주입한다.
        진행 이벤트는 그대로 두고(on_progress 시퀀스 불변) 방금 보고한
        상태를 잠깐 유지시켜, 폐루프(누름->검증->다음)가 화면에 보이게 한다."""
        if self._step_pacer is not None:
            self._step_pacer(button, completed_steps)
