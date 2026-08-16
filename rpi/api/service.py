from dataclasses import dataclass

from rpi.controller import (
    ClosedLoopController,
    ExecutionProgress,
    ExecutionProgressTracker,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.intent import (
    Clock,
    IntentResolver,
    PurposeExecutor,
    SystemClock,
    UsageLog,
    UsageOutcome,
    UsageRecord,
)


class ServiceNotReadyError(RuntimeError):
    """Raised when execute_purpose is called before startup completes or after shutdown."""


@dataclass(frozen=True)
class StatusSnapshot:
    running: bool
    ready: bool
    last_result: ExecutionResult | None
    progress: ExecutionProgress | None = None


class SimpleLayService(PurposeExecutor):
    """Small framework-neutral API suitable for wrapping with FastAPI later.

    Readiness is tracked separately from "process started": a caller that
    wants to confirm hardware dependencies (controller, verifier) before
    accepting commands can construct with ``start_ready=False`` and call
    ``mark_ready()`` once that check passes. ``request_shutdown()`` stops new
    purposes from being accepted while leaving an already-running execution
    (tracked by ``_running``) to finish normally rather than being torn down
    mid-retry.

    ``progress_tracker``, when given, must be the same
    ``ExecutionProgressTracker`` instance the caller wired into the
    ``ClosedLoopController`` passed as ``controller`` (via its
    ``on_progress`` callback) -- that's how ``status()`` can report live
    progress while ``execute_purpose`` is still running on another thread.
    """

    def __init__(
        self,
        intent: IntentResolver,
        controller: ClosedLoopController,
        usage_log: UsageLog | None = None,
        clock: Clock | None = None,
        start_ready: bool = True,
        progress_tracker: ExecutionProgressTracker | None = None,
    ) -> None:
        self._intent = intent
        self._controller = controller
        self._usage_log = usage_log
        self._clock = clock or SystemClock()
        self._running = False
        self._ready = start_ready
        self._shutting_down = False
        self._last_result: ExecutionResult | None = None
        self._progress_tracker = progress_tracker

    def mark_ready(self) -> None:
        """Declare that hardware dependencies finished initializing."""
        self._ready = True

    def request_shutdown(self) -> None:
        """Stop accepting new purposes; a running execution still completes."""
        self._shutting_down = True

    def execute_purpose(self, purpose: str) -> ExecutionResult:
        if not self._ready:
            raise ServiceNotReadyError(
                "service has not completed startup (call mark_ready() first)"
            )
        if self._shutting_down:
            raise ServiceNotReadyError(
                "service is shutting down and no longer accepts new purposes"
            )
        if self._running:
            raise RuntimeError("an execution is already in progress")
        self._running = True
        if self._progress_tracker is not None:
            self._progress_tracker.clear()
        try:
            buttons = self._intent.resolve(purpose)
            self._last_result = self._controller.execute(buttons)
            if self._usage_log is not None:
                outcome = (
                    UsageOutcome.SUCCEEDED
                    if self._last_result.status is ExecutionStatus.SUCCEEDED
                    else UsageOutcome.FAILED
                )
                self._usage_log.append(
                    UsageRecord(self._clock.now(), purpose.strip(), outcome)
                )
            return self._last_result
        finally:
            self._running = False
            if self._progress_tracker is not None:
                self._progress_tracker.clear()

    def status(self) -> StatusSnapshot:
        ready = self._ready and not self._shutting_down
        progress = self._progress_tracker.current() if self._progress_tracker else None
        return StatusSnapshot(self._running, ready, self._last_result, progress)
