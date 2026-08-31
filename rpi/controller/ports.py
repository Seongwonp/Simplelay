"""Ports implemented later by real GRBL, alert, and safety adapters."""

import time
from abc import ABC, abstractmethod
from collections.abc import Callable
from typing import Protocol

from .models import ExecutionResult, PressCommand


class ButtonSequenceController(Protocol):
    """Structural type for whatever runs a whole button sequence and reports
    back an ExecutionResult — satisfied by both ClosedLoopController (local,
    per-button closed loop) and ActClientController (dispatches the whole
    sequence to a real RPi4 board over UART; see rpi/services/). Callers like
    SimpleLayService only need this shape, not a specific implementation.
    """

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult: ...


class GrblClient(ABC):
    @abstractmethod
    def press(self, command: PressCommand) -> None:
        """Move and press, or raise an exception for error/alarm responses."""


class AlertSink(ABC):
    @abstractmethod
    def notify_failure(self, button: str, attempts: int) -> None:
        """Notify the app/user that closed-loop recovery was exhausted."""


class SafetyController(ABC):
    @abstractmethod
    def stop(self, reason: str) -> None:
        """Request a safe stop; a physical E-STOP remains authoritative."""


class RetryWaiter(ABC):
    @abstractmethod
    def wait(self, button: str, retry_number: int) -> None:
        """Wait for the appliance response window before retrying."""


class NoOpRetryWaiter(RetryWaiter):
    """Hardware-free default that deliberately performs no real-time delay."""

    def wait(self, button: str, retry_number: int) -> None:
        return None


class SleepingRetryWaiter(RetryWaiter):
    """데모/실기 응답창 흉내 -- 재시도 사이에 실제로 잠깐 쉬어 "재시도 중"을
    화면에 보이게 한다. 기본 경로는 여전히 NoOpRetryWaiter(지연 0)."""

    def __init__(
        self, seconds: float, sleep: Callable[[float], None] | None = None
    ) -> None:
        self._seconds = seconds
        self._sleep = sleep or time.sleep

    def wait(self, button: str, retry_number: int) -> None:
        self._sleep(self._seconds)
