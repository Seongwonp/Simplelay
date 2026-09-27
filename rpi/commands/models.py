"""명령·결과·승인 값 객체 (U1-a, 2026-09-27 결정 반영).

세 축은 서로 독립이다(계약 §1):

- 실행 환경 ``ExecutionMode`` (real/mock/unknown) -- 실행 대상이 스스로 선언.
  기존 ``rpi.controller.models``의 것을 그대로 쓴다. cloud를 추가하지 않는다.
- 제어 경로 ``ControlRoute`` (physical/thinq) -- 명령을 만들 때 확정.
- 확인 수준 ``Confirmation`` -- 어댑터가 결과에 기록. 실행 환경과 무관.

9/27 결정 1: **명령 수신 여부와 동작 확인 수준을 분리한다.** 결과에는 두
필드가 따로 있다 -- ``receipt``(상대가 받았는가)와 ``confirmation``(무엇을
근거로 확인했는가). 하나로 합치면 "가전 상태가 바뀐 것을 봤다"가 "내 명령을
받았다"로 승격된다. 명령 전에 이미 목표 상태였을 수도 있으므로, 상태 관측은
접수의 근거가 아니다. 물리 L1 눌림은 ``PRESS_CONFIRMED``로만 매핑되고 가전
상태 확인이 아니다(``rpi.commands.physical``).

이 모듈은 값 객체와 불변 조건만 담는다. 승인 원장·동시성·서비스 연결·DB·화면은
다음 단계다. 기존 물리 실행 경로(``execute(buttons)``, ``ExecutionResult``)는
바꾸지 않는다 -- 물리 명령은 그 위를 감싸는 기록·승인용 봉투다.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum

from rpi.controller.models import ExecutionMode, ExecutionResult

from .args import NormalizedArgs, fingerprint_of, normalize_args

MAX_TARGET_ID_LEN = 64
MAX_SHOWN_SUMMARY_LEN = 120

#: 동작 이름 규칙 -- 인자 이름과 같다(소문자 영문 시작, 영문·숫자·밑줄, 40자).
ACTION_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,39}$")

#: 물리 경로의 동작 이름은 하나뿐이다. "무엇을 누르는가"는 buttons가 말한다.
PHYSICAL_PRESS_ACTION = "press_buttons"


class ControlRoute(str, Enum):
    PHYSICAL = "physical"
    THINQ = "thinq"


class Receipt(str, Enum):
    """상대(실행기·클라우드)가 이 명령을 **받았는가.** 결과 확인과 별개다."""

    #: 확실히 보내지 않았다(미전송 취소·전송 전 실패). "보냈어요"가 아니다.
    NOT_DISPATCHED = "not_dispatched"
    #: 보냈는지·받았는지 모른다(전송 중 예외·응답 유실). "접수됐어요"라고 하지 않는다.
    UNKNOWN = "unknown"
    #: 상대가 받았다는 것을 확인했다.
    ACCEPTED = "accepted"


class Confirmation(str, Enum):
    """결과를 **무슨 근거로** 확인했나. 수신 여부와 무관하며 실행 환경과도 무관하다.

    ``REPORTED``가 요점이다. 원격 실행기가 "성공"만 집계해 보고하면 우리는
    센서 값을 본 적이 없다. 그것을 ``PRESS_CONFIRMED``로 적으면 집계 보고가
    센서 근거로 둔갑한다.
    """

    #: 확인한 것이 없다.
    NONE = "none"
    #: 상대가 완료를 **보고**했다. 직접 근거(센서·상태)는 여기 없다.
    REPORTED = "reported"
    #: 물리 L1 -- 버튼이 눌린 것을 **이쪽 센서로** 확인했다. 가전 상태 확인이 아니다.
    PRESS_CONFIRMED = "press_confirmed"
    #: 가전이 보고한 상태가 바뀐 것을 확인했다(클라우드 경로).
    STATE_CONFIRMED = "state_confirmed"
    #: 가전이 실제로 동작하는 것을 확인했다(물리 L3).
    OPERATION_CONFIRMED = "operation_confirmed"

    @property
    def has_evidence(self) -> bool:
        """직접 근거(센서·상태)로 확인했나. 보고만 받은 것은 아니다."""
        return self in (
            Confirmation.PRESS_CONFIRMED,
            Confirmation.STATE_CONFIRMED,
            Confirmation.OPERATION_CONFIRMED,
        )

    @property
    def confirms_appliance(self) -> bool:
        """**가전 쪽** 사실(상태 변경 또는 실제 동작)을 확인했나. L1 눌림은 아니다."""
        return self in (Confirmation.STATE_CONFIRMED, Confirmation.OPERATION_CONFIRMED)


class CommandStatus(str, Enum):
    """결과·중단 상태. 확인 수준이 아니다(9/27: ``stopped``는 확인 수준이 아니다)."""

    SUCCEEDED = "succeeded"
    FAILED = "failed"
    STOPPED = "stopped"
    #: 실패가 아니다. 결과를 정해진 시간 안에 확인하지 못했다. 자동 재전송 금지.
    UNCONFIRMED = "unconfirmed"


def _require_aware(name: str, value: datetime | None) -> None:
    if value is not None and value.tzinfo is None:
        raise ValueError(f"{name} must be timezone-aware")


@dataclass(frozen=True)
class Command:
    """기계가 할 일 하나. 목적 문자열·요약·승인·시각은 여기 없다.

    ``args``는 Mapping으로 넘겨도 되지만 저장은 항상 정렬된 튜플이다.
    직접 생성보다 ``Command.physical(...)``·``Command.thinq(...)``를 쓴다.
    """

    target_id: str
    route: ControlRoute
    action: str
    args: NormalizedArgs = ()
    buttons: tuple[str, ...] = ()
    #: route·target_id·action·args·buttons의 sha256. 같은 내용 확인용이며
    #: 인증·승인 토큰이 아니다. 생성 시 계산되고 바꿀 수 없다.
    fingerprint: str = field(init=False, repr=False)

    def __post_init__(self) -> None:
        target = self.target_id
        if not isinstance(target, str) or not target or target != target.strip():
            raise ValueError("target_id must be a non-blank string without surrounding whitespace")
        if len(target) > MAX_TARGET_ID_LEN:
            raise ValueError(f"target_id is {len(target)} chars (limit {MAX_TARGET_ID_LEN})")
        route = ControlRoute(self.route)
        object.__setattr__(self, "route", route)
        if not isinstance(self.action, str) or not ACTION_PATTERN.fullmatch(self.action):
            raise ValueError(
                f"action '{self.action}' must match {ACTION_PATTERN.pattern}"
            )
        object.__setattr__(self, "args", normalize_args(self.args))
        if not isinstance(self.buttons, tuple) or not all(isinstance(b, str) for b in self.buttons):
            raise ValueError("buttons must be a tuple of str")
        if route is ControlRoute.PHYSICAL:
            if self.action != PHYSICAL_PRESS_ACTION:
                raise ValueError(f"physical commands use action '{PHYSICAL_PRESS_ACTION}'")
            if self.args:
                raise ValueError("physical commands carry no args -- the sequence is in buttons")
            self._validate_button_sequence(self.buttons)
        else:
            if self.buttons:
                raise ValueError(f"{route.value} commands carry no buttons")
        object.__setattr__(
            self,
            "fingerprint",
            fingerprint_of(route.value, target, self.action, self.args, self.buttons),
        )

    @staticmethod
    def _validate_button_sequence(buttons: tuple[str, ...]) -> None:
        """기존 실행 상한(개수·라벨 길이·바이트)을 그대로 적용한다.

        새 상한을 만들지 않는다 -- 물리 경로는 ``execute(buttons)``로 그대로
        가므로, 여기서 통과한 것이 저기서 거절되면 봉투와 실행이 어긋난다.
        """
        from rpi.api.schemas import (  # noqa: PLC0415 -- FastAPI 계층을 게으르게
            MAX_BUTTON_LABEL_LEN,
            MAX_BUTTONS_PER_RUN,
            MAX_EXECUTE_PAYLOAD_BYTES,
            execute_payload_bytes,
        )

        if not buttons:
            raise ValueError("physical commands need at least one button")
        if len(buttons) > MAX_BUTTONS_PER_RUN:
            raise ValueError(f"{len(buttons)} buttons (limit {MAX_BUTTONS_PER_RUN})")
        for label in buttons:
            if not label.strip() or label != label.strip():
                raise ValueError(f"button label {label!r} must be non-blank without surrounding whitespace")
            if len(label) > MAX_BUTTON_LABEL_LEN:
                raise ValueError(f"button label {label!r} exceeds {MAX_BUTTON_LABEL_LEN} chars")
        size = execute_payload_bytes(list(buttons))
        if size > MAX_EXECUTE_PAYLOAD_BYTES:
            raise ValueError(f"button sequence is {size} bytes (limit {MAX_EXECUTE_PAYLOAD_BYTES})")

    @classmethod
    def physical(cls, target_id: str, buttons: tuple[str, ...] | list[str]) -> "Command":
        """기존 버튼 시퀀스를 감싸는 물리 명령."""
        return cls(target_id, ControlRoute.PHYSICAL, PHYSICAL_PRESS_ACTION, (), tuple(buttons))

    @classmethod
    def thinq(cls, target_id: str, action: str, args=None) -> "Command":
        """프로필 동작 + 인자. 허용 동작·인자 범위 검사는 U1-b(프로필)에서."""
        return cls(target_id, ControlRoute.THINQ, action, normalize_args(args), ())

    def args_dict(self) -> dict[str, object]:
        """읽기용 사본. 바꿔도 명령에는 영향이 없다."""
        return dict(self.args)

    def same_content(self, other: "Command") -> bool:
        return self.fingerprint == other.fingerprint


@dataclass(frozen=True)
class CommandResult:
    """명령 하나의 결과. 상태·수신·확인 근거는 세 개의 축이다.

    ``physical``에 기존 ``ExecutionResult``를 통째로 보존한다 -- 버튼별 L1
    판정·L2 재입력·L3 판정이 거기 있고, 여기서 요약하면 근거가 사라진다.

    시각은 **아는 것만** 적는다. ``observed_at``은 이 결과를 관측한 시각이고,
    ``accepted_at``은 상대가 받았다고 알려 준 시각이다. 관측 시각으로 접수
    시각을 채우지 않는다.
    """

    command: Command
    status: CommandStatus
    receipt: Receipt
    confirmation: Confirmation
    execution_mode: ExecutionMode
    #: 사람이 읽을 한 줄. 확인 못 한 이유를 포함한다.
    detail: str = ""
    requested_at: datetime | None = None
    #: 상대가 접수를 알린 시각. 모르면 None -- 추정하지 않는다.
    accepted_at: datetime | None = None
    #: 근거를 확인한 시각. 모르면 None.
    confirmed_at: datetime | None = None
    #: 이 결과를 관측(수신·생성)한 시각.
    observed_at: datetime | None = None
    #: 클라우드 메시지 ID 등. 없으면 None.
    provider_ref: str | None = None
    #: 이 실행 중 정지를 **요청**했나. 정지가 **확인**됐다는 뜻이 아니다 --
    #: 그것은 ``status is STOPPED``가 말한다. 원격이 실패만 집계해 보고하면
    #: 요청은 있었지만 확인은 없는 결과가 된다(요청 True, status failed).
    stop_requested: bool = False
    #: 물리 경로만. L1·L2·L3 근거 원본.
    physical: ExecutionResult | None = None

    def __post_init__(self) -> None:
        status = CommandStatus(self.status)
        receipt = Receipt(self.receipt)
        confirmation = Confirmation(self.confirmation)
        mode = ExecutionMode(self.execution_mode)
        object.__setattr__(self, "status", status)
        object.__setattr__(self, "receipt", receipt)
        object.__setattr__(self, "confirmation", confirmation)
        object.__setattr__(self, "execution_mode", mode)
        for name in ("requested_at", "accepted_at", "confirmed_at", "observed_at"):
            _require_aware(name, getattr(self, name))

        # 상태 ↔ 수신 ↔ 확인의 허용 조합. 어긋나면 "받았는지도 모르는데 성공"
        # 같은 결과가 만들어지므로 생성 시점에 막는다.
        if status is CommandStatus.SUCCEEDED and (
            receipt is not Receipt.ACCEPTED or confirmation is Confirmation.NONE
        ):
            raise ValueError("succeeded requires an accepted receipt and a confirmation")
        if receipt is Receipt.UNKNOWN and status is not CommandStatus.UNCONFIRMED:
            raise ValueError("unknown receipt is only reportable as unconfirmed")
        if receipt is Receipt.NOT_DISPATCHED and status not in (
            CommandStatus.FAILED, CommandStatus.STOPPED,
        ):
            raise ValueError("not_dispatched is only reportable as failed or stopped")
        if (status is CommandStatus.UNCONFIRMED and receipt is Receipt.ACCEPTED
                and confirmation is not Confirmation.NONE):
            raise ValueError("accepted and confirmed cannot be unconfirmed")
        if self.accepted_at is not None and receipt is not Receipt.ACCEPTED:
            raise ValueError("accepted_at requires an accepted receipt")
        if self.confirmed_at is not None and confirmation is Confirmation.NONE:
            raise ValueError("confirmed_at requires a confirmation")

        route = self.command.route
        if self.physical is not None and route is not ControlRoute.PHYSICAL:
            raise ValueError("physical evidence belongs to physical commands only")
        if route is ControlRoute.PHYSICAL and confirmation is Confirmation.STATE_CONFIRMED:
            raise ValueError("physical route cannot report state_confirmed -- L1 is press_confirmed")
        if route is not ControlRoute.PHYSICAL and confirmation in (
            Confirmation.PRESS_CONFIRMED, Confirmation.OPERATION_CONFIRMED,
        ):
            raise ValueError(f"{route.value} route cannot report {confirmation.value}")

    @property
    def route(self) -> ControlRoute:
        return self.command.route

    @property
    def buttons(self):
        """물리 경로의 버튼별 결과. 없으면 빈 튜플."""
        return self.physical.buttons if self.physical is not None else ()


@dataclass(frozen=True)
class ApprovedCommand:
    """승인 1건 = 명령 1건. 승인 뒤 목적을 다시 해석하지 않는다.

    실행 직전 재검사(대상·준비·상황)는 이 객체 밖(서비스)에서 하되, 재검사
    결과로 만든 명령이 ``command``와 fingerprint가 다르면 실행하지 않고
    재승인한다. 승인 ID의 중복 사용 차단은 다음 단계의 승인 원장이 맡는다.
    """

    command: Command
    approval_id: str
    approved_at: datetime
    #: 사용자가 실제로 본 문장(예: "공기청정기 풍량 강").
    shown_summary: str
    expires_at: datetime | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.approval_id, str) or not self.approval_id.strip():
            raise ValueError("approval_id must not be blank")
        if not isinstance(self.shown_summary, str) or not self.shown_summary.strip():
            raise ValueError("shown_summary must not be blank -- approval binds to what the user saw")
        if len(self.shown_summary) > MAX_SHOWN_SUMMARY_LEN:
            raise ValueError(f"shown_summary exceeds {MAX_SHOWN_SUMMARY_LEN} chars")
        if self.approved_at.tzinfo is None:
            raise ValueError("approved_at must be timezone-aware")
        _require_aware("expires_at", self.expires_at)
        if self.expires_at is not None and self.expires_at <= self.approved_at:
            raise ValueError("expires_at must be after approved_at")

    def is_expired(self, now: datetime) -> bool:
        if now.tzinfo is None:
            raise ValueError("now must be timezone-aware")
        return self.expires_at is not None and now >= self.expires_at

    def matches(self, command: Command) -> bool:
        """지금 실행하려는 명령이 승인한 그 명령인가(내용 기준)."""
        return self.command.same_content(command)
