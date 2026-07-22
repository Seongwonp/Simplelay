"""Ports implemented later by real GRBL, alert, and safety adapters."""

from abc import ABC, abstractmethod

from .models import PressCommand


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
