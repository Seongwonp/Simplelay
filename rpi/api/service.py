from dataclasses import dataclass

from rpi.controller import ClosedLoopController, ExecutionResult, ExecutionStatus
from rpi.intent import IntentResolver


@dataclass(frozen=True)
class StatusSnapshot:
    running: bool
    last_result: ExecutionResult | None


class SimpleLayService:
    """Small framework-neutral API suitable for wrapping with FastAPI later."""

    def __init__(self, intent: IntentResolver, controller: ClosedLoopController) -> None:
        self._intent = intent
        self._controller = controller
        self._running = False
        self._last_result: ExecutionResult | None = None

    def execute_purpose(self, purpose: str) -> ExecutionResult:
        if self._running:
            raise RuntimeError("an execution is already in progress")
        self._running = True
        try:
            buttons = self._intent.resolve(purpose)
            self._last_result = self._controller.execute(buttons)
            return self._last_result
        finally:
            self._running = False

    def status(self) -> StatusSnapshot:
        return StatusSnapshot(self._running, self._last_result)
