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


class ExecutionMode(str, Enum):
    """이 실행이 실제 하드웨어를 움직였나.

    **실행 대상 자신이 말한다.** 서버 전역 플래그로 정하면, 가전별
    원격 노드로 라우팅된 실행이 로컬 설정값으로 기록된다 — 실제로
    누른 실행이 mock 통계에 섞이는 것이다.

    전송이 원격이라는 사실은 물리적으로 눌렸는지에 대해 아무것도
    말해주지 않는다(저쪽 보드가 mock을 돌리고 있을 수 있다). 그래서
    모르면 UNKNOWN이다 — 기본값을 REAL이나 MOCK으로 두는 순간
    통계가 조용히 한쪽으로 기운다.
    """

    REAL = "real"
    MOCK = "mock"
    UNKNOWN = "unknown"


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
