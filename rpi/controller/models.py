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
    # 컨트롤러가 결과를 만들지 못하고 예외로 죽은 경우(UART 타임아웃 등) —
    # 비동기 job 모델에서 예외를 삼키지 않고 /status로 실패를 노출하기 위한 값
    FAILED = "failed"


@dataclass(frozen=True)
class ExecutionResult:
    status: ExecutionStatus
    buttons: tuple[ButtonResult, ...]


@dataclass(frozen=True)
class ExecutionProgress:
    """Live snapshot reported mid-execution, before the final ExecutionResult exists.

    ``verification`` is ``None`` when this snapshot was reported right after a
    failed press attempt (GRBL raised) rather than after a verification check.
    """

    button: str
    attempt: int
    completed_steps: int
    verification: VerificationResult | None
