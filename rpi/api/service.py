from dataclasses import dataclass

from rpi.controller import ClosedLoopController, ExecutionResult, ExecutionStatus
from rpi.intent import (
    Clock,
    IntentResolver,
    PurposeExecutor,
    SystemClock,
    UsageLog,
    UsageOutcome,
    UsageRecord,
)


@dataclass(frozen=True)
class StatusSnapshot:
    running: bool
    last_result: ExecutionResult | None


class SimpleLayService(PurposeExecutor):
    """Small framework-neutral API suitable for wrapping with FastAPI later."""

    def __init__(
        self,
        intent: IntentResolver,
        controller: ClosedLoopController,
        usage_log: UsageLog | None = None,
        clock: Clock | None = None,
    ) -> None:
        self._intent = intent
        self._controller = controller
        self._usage_log = usage_log
        self._clock = clock or SystemClock()
        self._running = False
        self._last_result: ExecutionResult | None = None

    def execute_purpose(self, purpose: str) -> ExecutionResult:
        if self._running:
            raise RuntimeError("an execution is already in progress")
        self._running = True
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

    def status(self) -> StatusSnapshot:
        return StatusSnapshot(self._running, self._last_result)
