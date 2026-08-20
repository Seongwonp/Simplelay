"""Closed-loop orchestration with bounded recovery and fail-safe behavior."""

import threading

from rpi.verifier import VerificationResult, Verifier

from .models import (
    ButtonResult,
    ButtonStatus,
    ExecutionProgress,
    ExecutionResult,
    ExecutionStatus,
    PressCommand,
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
    ) -> None:
        self._grbl = grbl
        self._verifier = verifier
        self._alerts = alerts
        self._safety = safety
        self._retry_policy = retry_policy or DocumentedRetryPolicy()
        self._retry_waiter = retry_waiter or NoOpRetryWaiter()
        self._on_progress = on_progress
        # /stop(긴급 정지)용. 실행은 별도 스레드(asyncio.to_thread)에서 돌고
        # 정지 요청은 FastAPI 요청 스레드에서 오므로 threading.Event를 쓴다.
        self._stop_requested = threading.Event()

    def request_stop(self) -> None:
        """Ask a running execute() to safety-stop at the next button/attempt
        boundary. Idle-time requests are discarded by execute()'s clear() --
        a stale stop must never eat the *next* run."""
        self._stop_requested.set()

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult:
        self._stop_requested.clear()
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
                reason = f"verification failed for {button} after {result.attempts} attempts"
                self._safety.stop(reason)
                self._alerts.notify_failure(button, result.attempts)
                return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, tuple(results))
        return ExecutionResult(ExecutionStatus.SUCCEEDED, tuple(results))

    def _execute_button(self, button: str, completed_steps: int) -> ButtonResult:
        errors: list[str] = []
        last_verification = None
        for attempt in range(1, self._retry_policy.max_attempts + 1):
            if attempt > 1:
                self._check_stop()  # 재시도 경계에서도 정지 요청 반영
                self._retry_waiter.wait(button, attempt - 1)
            correction = (
                None if attempt == 1 else self._retry_policy.correction_for(attempt - 1)
            )
            try:
                self._grbl.press(PressCommand(button, correction))
            except Exception as exc:  # adapter errors are recoverable within the hard limit
                errors.append(str(exc))
                self._report_progress(button, attempt, completed_steps, None)
                continue

            last_verification = self._verifier.verify(button)
            self._report_progress(button, attempt, completed_steps, last_verification)
            if last_verification.pressed:
                return ButtonResult(
                    button,
                    ButtonStatus.SUCCEEDED,
                    attempt,
                    last_verification,
                    tuple(errors),
                )

        return ButtonResult(
            button,
            ButtonStatus.FAILED,
            self._retry_policy.max_attempts,
            last_verification,
            tuple(errors),
        )

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
