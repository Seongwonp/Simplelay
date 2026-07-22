"""Data exchanged across the closed-loop controller boundary."""

from dataclasses import dataclass
from enum import Enum

from rpi.verifier import VerificationResult


@dataclass(frozen=True)
class Correction:
    """Qualitative correction request; hardware profiles choose safe distances."""

    retry_number: int
    xy_adjustment_required: bool
    increase_press_depth: bool


@dataclass(frozen=True)
class PressCommand:
    button: str
    correction: Correction | None = None


class ButtonStatus(str, Enum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"


@dataclass(frozen=True)
class ButtonResult:
    button: str
    status: ButtonStatus
    attempts: int
    verification: VerificationResult | None
    errors: tuple[str, ...] = ()


class ExecutionStatus(str, Enum):
    SUCCEEDED = "succeeded"
    SAFETY_STOPPED = "safety_stopped"


@dataclass(frozen=True)
class ExecutionResult:
    status: ExecutionStatus
    buttons: tuple[ButtonResult, ...]
