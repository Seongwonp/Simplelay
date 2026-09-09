"""Hardware-free controller adapters; all behavior is injected and recorded."""

from collections import deque
from collections.abc import Iterable

from .models import ExecutionMode, PressCommand
from .ports import AlertSink, GrblClient, RetryWaiter, SafetyController


class MockGrblClient(GrblClient):
    execution_mode = ExecutionMode.MOCK

    """Fake GRBL client where ``None`` means ok and an exception means error."""

    def __init__(self, responses: Iterable[Exception | None] = ()) -> None:
        self._responses = deque(responses)
        self.commands: list[PressCommand] = []

    def press(self, command: PressCommand) -> None:
        self.commands.append(command)
        if self._responses:
            response = self._responses.popleft()
            if response is not None:
                raise response


class MockAlertSink(AlertSink):
    def __init__(self) -> None:
        self.failures: list[tuple[str, int]] = []

    def notify_failure(self, button: str, attempts: int) -> None:
        self.failures.append((button, attempts))


class MockSafetyController(SafetyController):
    def __init__(self) -> None:
        self.reasons: list[str] = []

    def stop(self, reason: str) -> None:
        self.reasons.append(reason)


class MockRetryWaiter(RetryWaiter):
    """Records response-window waits without sleeping."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, int]] = []

    def wait(self, button: str, retry_number: int) -> None:
        self.calls.append((button, retry_number))
