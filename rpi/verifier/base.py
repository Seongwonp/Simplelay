"""Hardware-independent verification contract."""

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass(frozen=True)
class VerificationResult:
    """Result of checking whether an appliance accepted a button press."""

    pressed: bool
    confidence: float
    detail: str = ""

    def __post_init__(self) -> None:
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError("confidence must be between 0.0 and 1.0")


class Verifier(ABC):
    """Converts sensor evidence into a press/no-press decision."""

    @abstractmethod
    def verify(self, button: str) -> VerificationResult:
        """Verify the most recent press of ``button``."""
