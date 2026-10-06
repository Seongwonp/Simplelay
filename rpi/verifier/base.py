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


class SensorUnavailable(RuntimeError):
    """센서를 읽을 수 없다(단절·장치 오류·프레임 없음).

    '눌리지 않음'(전류 0·무음)과 다르다 — 무엇이 일어났는지 볼 수 없으니
    다시 눌러 확인하지 않고 멈춘다(`ClosedLoopController`가 재시도 없이 안전 정지).
    """
