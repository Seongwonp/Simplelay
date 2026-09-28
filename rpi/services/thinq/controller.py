"""ThinQ 경로 실행기 — ``Command`` → 클라이언트 제어 호출 → ``CommandResult``.

**왜 ``ButtonSequenceController``를 구현하지 않나.** 그 프로토콜은
``execute(buttons)``이고, 동작명을 버튼 라벨 자리에 밀어 넣으면 풍량·온도처럼
인자와 허용값이 있는 동작을 표현할 수 없다(계약 §2·§7 "문자열 동작명 금지").
그래서 옆에 ``CommandController``(``execute_command(cmd) -> CommandResult``)를 둔다.
서비스의 잠금·이력·정지 흐름은 그대로 재사용한다.

확인 수준(계약 §3, 9/27 결정 1 — 수신과 확인을 분리):

| 상황                                              | status      | receipt        | confirmation     |
|---------------------------------------------------|-------------|----------------|------------------|
| 보냈고 상한 안에 조회 상태가 요청 값이 됨          | succeeded   | accepted       | state_confirmed  |
| 보냈고 접수 응답은 받았지만 상태를 못 봄           | unconfirmed | accepted       | none  (접수됨)   |
| 명령 전부터 이미 그 값이었다(변경을 볼 수 없음)    | unconfirmed | accepted       | none             |
| 보내는 중 끊김·응답 유실                           | unconfirmed | unknown        | none  (접수 불명)|
| 클라우드가 거절 응답                               | failed      | accepted       | none             |
| 보내기 전에 미연결 확인 / 정지로 전송 취소          | failed/stopped | not_dispatched | none          |

``unconfirmed``는 실패가 아니다. 자동으로 다시 보내지 않는다(중복 실행).

정지(결정 5): ``request_stop()``은 **아직 보내지 않은** 명령만 취소한다. 이미 보낸
명령은 취소할 수 없으므로 ``sent_uncancellable``로 보고하고, 확인 대기만 끊는다.
가전 운전 정지(전원 끄기) 명령은 자동으로 보내지 않는다 -- 그것은 별도 승인 동작이다.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Protocol

from rpi.commands import (
    Command,
    CommandResult,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)
from rpi.controller.models import ExecutionMode

from .bindings import CapabilityError, ThinqBinding
from .client import (
    NOT_IMPLEMENTED_MESSAGE,
    ThinqClientError,
    ThinqClientPort,
    ThinqCommandRejected,
    ThinqOfflineError,
)
from .config import ThinqMode


class CommandController(Protocol):
    """제어 경로가 버튼 시퀀스가 아닌 실행기(계약 §2)."""

    route: ControlRoute
    execution_mode: ExecutionMode

    def execute_command(self, command: Command) -> CommandResult: ...


class StopOutcome(str, Enum):
    #: 진행 중인 ThinQ 명령이 없었다.
    IDLE = "idle"
    #: 보내기 전이라 취소했다(전송 안 됨).
    CANCELLED_BEFORE_DISPATCH = "cancelled_before_dispatch"
    #: 이미 보냈다. 취소할 수 없다 -- 가전은 받았을 수 있다.
    SENT_UNCANCELLABLE = "sent_uncancellable"


@dataclass(frozen=True)
class ThinqReadiness:
    """ThinQ 경로 준비 상태(U1-b). 확인 못 한 필수 조건은 준비 안 됨이다."""

    appliance_id: str
    mode: str
    client_reachable: bool
    device_present: bool
    device_online: bool
    reasons: tuple[str, ...] = ()
    read_only: bool = False

    @property
    def can_execute(self) -> bool:
        return (self.client_reachable and self.device_present and self.device_online
                and not self.read_only and not self.reasons)

    @property
    def state(self) -> str:
        if not self.client_reachable or not self.device_present or not self.device_online:
            return "disconnected"
        return "operable" if self.can_execute else "needs_setup"


def _read(state: dict, resource: str, prop: str):
    section = state.get(resource) if isinstance(state, dict) else None
    return section.get(prop) if isinstance(section, dict) else None


class ThinqController:
    route = ControlRoute.THINQ

    def __init__(
        self,
        client: ThinqClientPort,
        binding_of: Callable[[str], ThinqBinding | None],
        *,
        mode: ThinqMode,
        confirm_seconds: float = 3.0,
        poll_interval: float = 0.25,
        sleep: Callable[[float], None] | None = None,
        monotonic: Callable[[], float] | None = None,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self._client = client
        self._binding_of = binding_of
        self.mode = mode
        self._confirm_seconds = confirm_seconds
        self._poll_interval = poll_interval
        self._sleep = sleep or time.sleep
        self._monotonic = monotonic or time.monotonic
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()
        #: idle | pending | dispatched
        self._phase = "idle"
        self._cancel = False
        self._stop_during_confirm = False

    @property
    def client(self) -> ThinqClientPort:
        return self._client

    @property
    def execution_mode(self) -> ExecutionMode:
        return getattr(self._client, "execution_mode", ExecutionMode.UNKNOWN)

    # ── 준비 상태 ─────────────────────────────────────────────────────────
    def readiness(self, appliance_id: str) -> ThinqReadiness:
        binding = self._binding_of(appliance_id)
        if binding is None:
            return ThinqReadiness(appliance_id, self.mode.value, False, False, False,
                                  ("ThinQ 기기가 등록되지 않았어요",))
        try:
            devices = self._client.list_devices()
        except NotImplementedError:
            return ThinqReadiness(appliance_id, self.mode.value, False, False, False,
                                  (NOT_IMPLEMENTED_MESSAGE,))
        except ThinqClientError:
            return ThinqReadiness(appliance_id, self.mode.value, False, False, False,
                                  ("ThinQ 클라우드에 연결되지 않았어요",))
        except Exception:  # noqa: BLE001 -- 모르는 실패도 준비 안 됨이다
            return ThinqReadiness(appliance_id, self.mode.value, False, False, False,
                                  ("ThinQ 상태를 확인하지 못했어요",))
        device = next((d for d in devices if d.device_id == binding.device_id), None)
        if device is None:
            return ThinqReadiness(appliance_id, self.mode.value, True, False, False,
                                  ("ThinQ 계정에서 이 기기를 찾지 못했어요",))
        if not device.online:
            return ThinqReadiness(appliance_id, self.mode.value, True, True, False,
                                  ("가전이 오프라인이에요 — 전원·Wi-Fi를 확인해 주세요",))
        if binding.read_only:
            return ThinqReadiness(appliance_id, self.mode.value, True, True, True,
                                  ("상태만 읽을 수 있는 가전이에요",), read_only=True)
        return ThinqReadiness(appliance_id, self.mode.value, True, True, True)

    # ── 정지 ──────────────────────────────────────────────────────────────
    def reset_stop(self) -> None:
        with self._lock:
            self._cancel = False
            self._stop_during_confirm = False

    def request_stop(self) -> StopOutcome:
        with self._lock:
            if self._phase == "pending":
                self._cancel = True
                return StopOutcome.CANCELLED_BEFORE_DISPATCH
            if self._phase == "dispatched":
                self._stop_during_confirm = True
                return StopOutcome.SENT_UNCANCELLABLE
            return StopOutcome.IDLE

    # ── 실행 ──────────────────────────────────────────────────────────────
    def _result(self, command, status, receipt, confirmation, detail, requested_at,
                accepted_at=None, confirmed_at=None, provider_ref=None, stop_requested=False):
        return CommandResult(
            command=command, status=status, receipt=receipt, confirmation=confirmation,
            execution_mode=self.execution_mode, detail=detail, requested_at=requested_at,
            accepted_at=accepted_at, confirmed_at=confirmed_at, observed_at=self._now(),
            provider_ref=provider_ref, stop_requested=stop_requested,
        )

    def execute_command(self, command: Command) -> CommandResult:
        if command.route is not ControlRoute.THINQ:
            raise ValueError("ThinqController runs thinq commands only")
        requested_at = self._now()
        with self._lock:
            self._phase = "pending"
        try:
            return self._execute(command, requested_at)
        finally:
            with self._lock:
                self._phase = "idle"

    def _execute(self, command: Command, requested_at: datetime) -> CommandResult:
        failed, not_sent = CommandStatus.FAILED, Receipt.NOT_DISPATCHED
        none = Confirmation.NONE
        binding = self._binding_of(command.target_id)
        if binding is None:
            return self._result(command, failed, not_sent, none,
                                "ThinQ 기기가 등록되지 않아 보내지 않았어요", requested_at)
        try:
            cap = binding.validate_command(command)
        except CapabilityError as exc:
            return self._result(command, failed, not_sent, none, f"보내지 않았어요: {exc}", requested_at)
        target = command.args_dict()[cap.arg]

        # 보내기 전 상태 -- 이미 목표 값이면 나중에 "바뀐 것을 봤다"고 말할 수 없다.
        try:
            before = _read(self._client.get_status(binding.device_id), cap.resource, cap.property)
        except NotImplementedError:
            return self._result(command, failed, not_sent, none, NOT_IMPLEMENTED_MESSAGE, requested_at)
        except ThinqOfflineError:
            return self._result(command, failed, not_sent, none,
                                "가전·클라우드에 연결되지 않아 보내지 않았어요", requested_at)
        except ThinqClientError as exc:
            return self._result(command, failed, not_sent, none,
                                f"상태를 읽지 못해 보내지 않았어요 ({type(exc).__name__})", requested_at)

        with self._lock:
            if self._cancel:
                return self._result(command, CommandStatus.STOPPED, not_sent, none,
                                    "보내기 전에 정지 요청을 받아 보내지 않았어요", requested_at,
                                    stop_requested=True)
            self._phase = "dispatched"
        try:
            response = self._client.post_control(binding.device_id, cap.payload(target))
        except ThinqCommandRejected as exc:
            return self._result(command, failed, Receipt.ACCEPTED, none,
                                f"클라우드가 명령을 거절했어요 (코드 {exc.code}) — 실행되지 않았어요",
                                requested_at)
        except ThinqOfflineError:
            return self._result(command, failed, not_sent, none,
                                "가전·클라우드에 연결되지 않아 보내지 않았어요", requested_at)
        except Exception:  # noqa: BLE001 -- 전송 중 끊김·응답 유실·모르는 오류
            return self._result(command, CommandStatus.UNCONFIRMED, Receipt.UNKNOWN, none,
                                "보냈는지 확인하지 못했어요 — 자동으로 다시 보내지 않아요. "
                                "가전을 직접 확인하거나 다시 조회해 주세요", requested_at,
                                stop_requested=self._stop_during_confirm)
        accepted_at = self._now()
        ref = response.get("messageId") if isinstance(response, dict) else None
        ref = str(ref) if ref else None

        if before == target:
            return self._result(command, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, none,
                                "명령을 보냈어요 — 보내기 전에도 같은 값이라 변경을 확인할 수 없어요",
                                requested_at, accepted_at=accepted_at, provider_ref=ref,
                                stop_requested=self._stop_during_confirm)

        deadline = self._monotonic() + self._confirm_seconds
        while True:
            with self._lock:
                stop = self._stop_during_confirm
            if stop:
                return self._result(command, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, none,
                                    "명령은 이미 보내 취소할 수 없어요 — 정지 요청으로 확인을 멈췄어요",
                                    requested_at, accepted_at=accepted_at, provider_ref=ref,
                                    stop_requested=True)
            try:
                now_value = _read(self._client.get_status(binding.device_id),
                                  cap.resource, cap.property)
            except Exception:  # noqa: BLE001 -- 조회 실패는 확인 못 함일 뿐
                now_value = None
            if now_value == target:
                return self._result(command, CommandStatus.SUCCEEDED, Receipt.ACCEPTED,
                                    Confirmation.STATE_CONFIRMED,
                                    "명령을 보냈고 상태가 바뀐 것을 확인했어요",
                                    requested_at, accepted_at=accepted_at,
                                    confirmed_at=self._now(), provider_ref=ref)
            if self._monotonic() >= deadline:
                return self._result(command, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, none,
                                    "명령을 보냈어요 — 아직 상태를 확인하지 못했어요",
                                    requested_at, accepted_at=accepted_at, provider_ref=ref)
            self._sleep(self._poll_interval)
