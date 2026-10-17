"""Data exchanged across the closed-loop controller boundary."""

import math
from dataclasses import dataclass
from enum import Enum

from rpi.verifier import VerificationResult


# R1: 명시적으로 재누름을 허용한 버튼만 폐루프 재시도한다.
BUTTON_BEHAVIORS = frozenset({"toggle", "idempotent", "unknown"})
RETRY_UNCONFIRMED = "press_unconfirmed"
# 10/18 쉬운 말: 결과 한 줄 + 할 일 한 줄. 자동으로 다시 누르지 않는다는 사실(R1)은 그대로 말한다.
PRESS_UNCONFIRMED_DETAIL = "눌렸는지 몰라요. 다시 누르지 않았으니 가전을 직접 봐 주세요."


def button_behavior(value: object) -> str:
    return value if isinstance(value, str) and value in BUTTON_BEHAVIORS else "unknown"


@dataclass(frozen=True)
class Correction:
    """Qualitative correction request; hardware profiles choose safe distances."""

    retry_number: int
    xy_adjustment_required: bool
    increase_press_depth: bool


def _check_xy_pair(owner: str, x_mm: float | None, y_mm: float | None) -> None:
    if (x_mm is None) != (y_mm is None):
        raise ValueError(f"{owner}: x_mm와 y_mm는 함께 주거나 함께 비워야 합니다")
    for label, value in (("x_mm", x_mm), ("y_mm", y_mm)):
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"{owner}: {label}는 유한한 수여야 합니다: {value!r}")


def _check_press_ms(owner: str, press_ms: int | None) -> None:
    if press_ms is None:
        return
    if isinstance(press_ms, bool) or not isinstance(press_ms, int) or press_ms <= 0:
        raise ValueError(f"{owner}: press_ms는 1 이상의 정수여야 합니다: {press_ms!r}")


@dataclass(frozen=True)
class ButtonTarget:
    """버튼 하나의 갠트리 좌표(mm)와 누름 유지 시간.

    보정(`rpi/calibration/transform.py` → 가전 레지스트리 ``x_mm``·``y_mm``)에서
    온 값만 싣는다. 격자 칸 번호에서 계산하지 않는다.
    """

    x_mm: float
    y_mm: float
    #: 버튼맵의 누름 유지 시간. None이면 모션 어댑터 설정값을 쓴다.
    press_ms: int | None = None

    def __post_init__(self) -> None:
        _check_xy_pair("ButtonTarget", self.x_mm, self.y_mm)
        if self.x_mm is None:
            raise ValueError("ButtonTarget: x_mm·y_mm가 필요합니다")
        _check_press_ms("ButtonTarget", self.press_ms)


@dataclass(frozen=True)
class PressCommand:
    button: str
    correction: Correction | None = None
    #: 갠트리 좌표(mm). 둘 다 None이면 좌표 없는 종전 명령 — mock 경로는 그대로
    #: 동작하고, 실제 모션 어댑터(serial_motion)는 누름을 거절한다.
    x_mm: float | None = None
    y_mm: float | None = None
    #: 누름 유지 시간(ms). None이면 어댑터 설정값.
    press_ms: int | None = None

    def __post_init__(self) -> None:
        _check_xy_pair("PressCommand", self.x_mm, self.y_mm)
        _check_press_ms("PressCommand", self.press_ms)

    @property
    def has_coordinates(self) -> bool:
        return self.x_mm is not None and self.y_mm is not None


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
    #: 판정 근거가 **합성 입력**(모의 전력 센서 등)인가. True면 통과해도 실제 동작
    #: 근거가 아니다 -- 확인 수준을 ``operation_confirmed``로 올리지 않는다.
    mock: bool = False


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
    #: 재시도 누름마다 요청한 정성 보정(첫 누름은 보정이 없어 빠진다).
    corrections: tuple[Correction, ...] = ()


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


class ExecutionOutcome(str, Enum):
    """실행이 **어떻게** 끝났나 — 화면이 "정지됨"과 "실패"를 가르는 값.

    ``ExecutionStatus.SAFETY_STOPPED`` 하나에 두 사건이 섞여 있다. 폐루프는
    정지 요청을 받아 멈춰도, 검증 실패로 스스로 안전 정지해도 같은 상태로
    끝낸다. UART 결과 프레임도 ``success=false`` 하나뿐이라 RPi5는 둘을 가를
    수 없었다(본선 준비 결함 목록 P1, docs/protocol.md ``outcome``).

    - ``success``: 시퀀스를 끝까지 성공.
    - ``stopped``: 정지 요청(긴급 정지·abort)을 받아 멈췄다. 실패가 아니다.
    - ``safety_stop``: 검증 실패·센서 불가 등으로 컨트롤러가 스스로 안전 정지.
    - ``failed``: 그 밖의 실패, 또는 **실패만 알고 이유는 모르는** 경우
      (outcome을 보내지 않는 옛 RPi4·ESP 노드의 ``success=false``).

    물리 정지 확인이 아니다 — 실행 루프가 어떤 이유로 끝났는지다.
    """

    SUCCESS = "success"
    FAILED = "failed"
    STOPPED = "stopped"
    SAFETY_STOP = "safety_stop"


@dataclass(frozen=True)
class ExecutionResult:
    status: ExecutionStatus
    buttons: tuple[ButtonResult, ...]
    #: 안전 정지로 끝났다면 어느 층 때문인가. 사용자 긴급 정지·성공이면 None.
    failed_layer: VerificationLayer | None = None
    #: 시퀀스 끝의 L3 판정. L3 검증기가 없는 구성이면 None -- '확인 안 함'과
    #: '확인했는데 안 돌았다'를 섞지 않는다.
    operation: LayerOutcome | None = None
    #: 원격 실행기가 **보고한** 종료 방식. 로컬 폐루프는 None이고
    #: `outcome_of`가 status·버튼 결과에서 유도한다. 원격 집계 결과는 버튼별
    #: 값이 추정이라 유도하면 안 되므로 합성하는 쪽이 반드시 채운다.
    outcome: ExecutionOutcome | None = None
    #: 원격 실행기가 **보고한** 실행 환경(real/mock/unknown). 로컬은 None --
    #: 컨트롤러가 밝힌 값을 쓴다. 원격 링크(UART)는 저쪽이 실물을 돌렸는지
    #: 스스로 알 수 없으므로 이 보고가 유일한 근거다.
    execution_mode: ExecutionMode | None = None
    #: 모션 장치 쪽 이유로 재시도 없이 멈췄다면 그 원인(2026-10-14) — ``motion_alarm: stall``·``motion_reset``·
    #: ``motion_timeout``·``motion_not_ready``·``motion_position_mismatch``·``motion_link_error``. 눌림(L1) 확인
    #: 실패와 가르는 근거다. 그 밖의 결과는 None.
    abort_reason: str | None = None
    #: 정지 요청으로 **실행 대상에 보내지 않았다**(2026-10-15 G2) — 누른 버튼이 없다는 것을 이쪽이 안다.
    #: 수신 ``not_dispatched``의 근거다(`rpi.commands.physical.receipt_of`). `stopped_before_dispatch`로만 만든다.
    not_dispatched: bool = False


def stopped_before_dispatch() -> ExecutionResult:
    """정지 요청이 접수 뒤·보내기 전에 와서 실행 대상(RPi4 링크·노드)에 넘기지 않은 실행(2026-10-15 G2).

    정지로 끝났고(``stopped``) 누른 버튼은 없다. '성공'도 '실패'도 아니다."""
    return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (), outcome=ExecutionOutcome.STOPPED,
                           not_dispatched=True)


def outcome_of(result: ExecutionResult) -> ExecutionOutcome:
    """결과의 종료 방식. 보고된 값이 있으면 그것, 없으면 로컬 폐루프 규칙으로 유도.

    로컬 ``SAFETY_STOPPED``는 실패한 버튼이나 실패 층(``failed_layer``)이
    있으면 스스로 멈춘 안전 정지, 없으면 정지 요청으로 멈춘 것이다
    (ClosedLoopController의 반환 경로가 이 둘뿐이다).
    """
    reported = getattr(result, "outcome", None)
    if reported is not None:
        return reported
    if result.status is ExecutionStatus.SUCCEEDED:
        return ExecutionOutcome.SUCCESS
    if result.status is ExecutionStatus.SAFETY_STOPPED:
        if getattr(result, "failed_layer", None) is not None or any(
            b.status is ButtonStatus.FAILED for b in result.buttons
        ):
            return ExecutionOutcome.SAFETY_STOP
        return ExecutionOutcome.STOPPED
    return ExecutionOutcome.FAILED


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
