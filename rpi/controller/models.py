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


class VerificationLayer(str, Enum):
    """실행 검증의 세 층 — **무엇이 실패했느냐에 따라 복구 방법이 다르다.**

    - L1 눌렀는가: 좌표·깊이 문제다. 보정해서 다시 누르면 된다.
    - L2 가전이 받아들였는가: 눌렸는데 가전이 입력을 안 받았다(잠금·타이밍).
      같은 입력을 한 번 더 넣어 보고, 그래도 안 되면 사람에게 넘긴다.
    - L3 실제로 동작했는가: 버튼은 다 들어갔는데 가전이 돌지 않는다. 여기서
      자동으로 다시 누르면 이미 반쯤 설정된 가전에 입력이 겹친다 -- 멈추고
      사람에게 확인받는다.

    값은 외부(이력·화면)에 그대로 나가는 짧은 이름이다.
    """

    PRESS = "L1"
    ACCEPTANCE = "L2"
    OPERATION = "L3"


@dataclass(frozen=True)
class LayerOutcome:
    """L2·L3 판정 하나. L1은 기존 VerificationResult가 맡는다."""

    layer: VerificationLayer
    passed: bool
    detail: str = ""


@dataclass(frozen=True)
class ButtonResult:
    button: str
    status: ButtonStatus
    #: 이 버튼을 **실제로 누른 횟수**(첫 누름·보정 재시도·L2 재입력 모두 포함).
    attempts: int
    verification: VerificationResult | None
    errors: tuple[str, ...] = ()
    #: 실패했다면 어느 층에서 멈췄나. 성공이면 None.
    failed_layer: VerificationLayer | None = None
    #: L2 불수용으로 같은 입력을 다시 넣은 횟수.
    reinputs: int = 0


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
    #: 안전 정지로 끝났다면 어느 층 때문인가. 사용자 긴급 정지·성공이면 None.
    failed_layer: VerificationLayer | None = None
    #: 시퀀스 끝의 L3 판정. L3 검증기가 없는 구성이면 None -- '확인 안 함'과
    #: '확인했는데 안 돌았다'를 섞지 않는다.
    operation: LayerOutcome | None = None


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
