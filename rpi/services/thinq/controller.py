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
| 보내기 전 조회에서 이미 그 값(보내지 않음)          | succeeded   | not_dispatched | already_at_target|
| 보내기 전 값 모름(조회 실패·값 없음) → 보낸 뒤 목표값 | succeeded | accepted   | state_confirmed_unknown_before |
| 보내는 중 끊김·응답 유실                           | unconfirmed | unknown        | none  (접수 불명)|
| 클라우드가 거절 응답                               | failed      | accepted       | none             |
| 보내기 전에 미연결 확인 / 정지로 전송 취소          | failed/stopped | not_dispatched | none          |

``unconfirmed``는 실패가 아니다. 자동으로 다시 보내지 않는다(중복 실행).

이미 목표값(2026-10-14 보드 날 발견 3): 보내기 전 조회에서 확인할 속성이 이미 목표값이면 보내지 않고
``already_at_target``("이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요.")로 끝낸다. 조회가 실패했거나 값이
없으면(불확실) 보내고(최대 1회), 보낸 뒤 목표값이면 ``state_confirmed_unknown_before``("강풍으로 설정된 것을
확인했어요." — '바꿨어요' 금지). 정지(미전송 취소)·전송 직전 재판정·전송권 확인을 모두 지난 뒤에만 이 결과를 낸다.
문장은 :mod:`.wording`.

정지(결정 5): ``request_stop()``은 **아직 보내지 않은** 명령만 취소한다. 이미 보낸
명령은 취소할 수 없으므로 ``sent_uncancellable``로 보고하고, 확인 대기만 끊는다.
가전 운전 정지(전원 끄기) 명령은 자동으로 보내지 않는다 -- 그것은 별도 승인 동작이다.
"""

from __future__ import annotations

import logging
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

from .bindings import CapabilityError, ThinqBinding, ThinqCapability
from .client import (
    ThinqClientError,
    ThinqClientPort,
    ThinqCommandRejected,
    ThinqOfflineError,
    ThinqTransportError,
)
from .config import ThinqMode
from .profile import DeviceProfile, read_state
from .wording import UNCONFIRMED_SENTENCE, already_sentence, changed_sentence, target_seen_sentence

log = logging.getLogger(__name__)

REMOTE_OFF_REASON = "가전의 원격 제어가 꺼져 있어요. 가전에서 원격 제어를 켜 주세요."
REMOTE_UNKNOWN_REASON = "가전의 원격 제어가 켜져 있는지 몰라요. 가전을 봐 주세요."


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


def _with_result(reason: str, result: str) -> str:
    """이유 문장 바로 뒤에 결과 문장을 넣는다 — '이유. 결과. 할 일.'(10/18 쉬운 말: 오류 이유에 할 일이 붙어 온다)."""
    reason = reason.strip()
    head, sep, tail = reason.partition(". ")
    if not sep:
        return f"{reason.rstrip('.')}. {result}"
    return f"{head}. {result} {tail}"


def _not_sent(exc: Exception, fallback: str) -> str:
    """보내지 않은 이유 한 줄 + '그래서 보내지 않았어요'. 예외 클래스 이름은 내지 않는다(10/17 쉬운 말)."""
    return _with_result(_reason(exc, fallback), "그래서 보내지 않았어요.")


def _rejected_sentence(exc: Exception) -> str:
    """클라우드 거절 — 이유 한 줄 + 실행되지 않았다는 결과. 코드 번호는 기록에만 남긴다."""
    log.info("thinq command rejected: code=%s", getattr(exc, "code", None))
    reason = _reason(exc, "")
    return _with_result(reason, "그래서 바뀌지 않았어요.") if reason else "가전이 명령을 받지 않았어요. 바뀌지 않았어요."


def _josa_eul(word: str) -> str:
    last = word.strip()[-1:]
    if "가" <= last <= "힣":
        return "을" if (ord(last) - 0xAC00) % 28 else "를"
    return "을"


def _reason(exc: Exception, fallback: str) -> str:
    """사람 말 이유. 클라우드 오류면 그 이유(토큰 없음), 아니면 대체 문장."""
    reason = getattr(exc, "reason", None)
    return reason if isinstance(reason, str) and reason else fallback


def _read(state: dict, resource: str, prop: str):
    section = state.get(resource) if isinstance(state, dict) else None
    return section.get(prop) if isinstance(section, dict) else None


class ThinqController:
    route = ControlRoute.THINQ
    #: ``execute_command(..., dispatch_guard=)``를 받는다 — 조회를 마친 뒤 전송 직전에 부른다(3차 평가 H1).
    supports_dispatch_guard = True

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
        observe_state: Callable[[str, ThinqBinding, object], None] | None = None,
    ) -> None:
        self._client = client
        #: 상태 조회 결과를 넘겨받는 곳(전원 기억, :mod:`.power`). 상태 ``None``은 '지금은 모름'. 실패해도 실행을 막지 않는다.
        self._observe_state = observe_state
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

    def _observe(self, appliance_id: str, binding: ThinqBinding, state) -> None:
        if self._observe_state is None:
            return
        try:
            self._observe_state(appliance_id, binding, state)
        except Exception:  # noqa: BLE001 -- 표시용 기억이 실행을 막지 않는다
            pass

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
                                  ("LG 가전이 등록되지 않았어요.",))
        try:
            devices = self._client.list_devices()
        except ThinqClientError as exc:
            return ThinqReadiness(appliance_id, self.mode.value, False, False, False,
                                  (_reason(exc, "LG 가전에 연결되지 않았어요."),))
        except Exception:  # noqa: BLE001 -- 모르는 실패도 준비 안 됨이다
            return ThinqReadiness(appliance_id, self.mode.value, False, False, False,
                                  ("LG 가전 상태를 알 수 없어요.",))
        device = next((d for d in devices if d.device_id == binding.device_id), None)
        if device is None:
            return ThinqReadiness(appliance_id, self.mode.value, True, False, False,
                                  ("LG 계정에서 이 가전을 찾지 못했어요.",))
        online = device.online
        probe = getattr(self._client, "probe_online", None)
        if online and probe is not None:
            # SDK 목록에는 온라인 여부가 없다 -- 상태 조회(짧게 캐시)로 본다.
            try:
                online = probe(binding.device_id)
            except ThinqClientError as exc:
                return ThinqReadiness(appliance_id, self.mode.value, False, True, False,
                                      (_reason(exc, "LG 가전 상태를 알 수 없어요."),))
        if not online:
            return ThinqReadiness(appliance_id, self.mode.value, True, True, False,
                                  ("가전이 연결되지 않았어요. 가전 전원과 와이파이를 봐 주세요.",))
        if binding.read_only:
            return ThinqReadiness(appliance_id, self.mode.value, True, True, True,
                                  ("상태만 읽을 수 있는 가전이에요",), read_only=True)
        reasons = self._setup_reasons(binding)
        return ThinqReadiness(appliance_id, self.mode.value, True, True, True, reasons)

    def _setup_reasons(self, binding: ThinqBinding) -> tuple[str, ...]:
        """프로필에서 쓸 수 있는 동작이 하나도 없거나, 원격 제어가 꺼져 있으면 준비 안 됨."""
        try:
            profile = self._profile(binding.device_id)
        except ThinqClientError as exc:
            return (_reason(exc, "기기 프로필을 읽지 못했어요"),)
        if profile is not None and not any(
                self._resolve(profile, cap)[0] is not None for cap in binding.capabilities):
            return ("이 모델 프로필에서 쓸 수 있는 동작이 없어요 — 프로필을 확인해 주세요",)
        remote_caps = [c for c in binding.capabilities if c.requires_remote is not None]
        if not remote_caps:
            return ()
        cap = remote_caps[0]
        try:
            state = self._status_for_readiness(binding.device_id)
        except ThinqClientError as exc:
            return (_reason(exc, "가전 상태를 읽지 못했어요"),)
        remote = read_state(state, *cap.requires_remote, location=cap.location)
        if remote is not True:
            return (REMOTE_OFF_REASON if remote is False else REMOTE_UNKNOWN_REASON,)
        return ()

    def _status_for_readiness(self, device_id: str):
        cached = getattr(self._client, "cached_status", None)
        return cached(device_id) if cached is not None else self._client.get_status(device_id)

    # ── 프로필 ────────────────────────────────────────────────────────────
    def _profile(self, device_id: str) -> DeviceProfile | None:
        """기기 프로필. 클라이언트가 프로필을 주지 않으면 None(판정 생략 -- 옛 대역 호환)."""
        get_profile = getattr(self._client, "get_profile", None)
        if get_profile is None:
            return None
        return DeviceProfile(get_profile(device_id))

    @staticmethod
    def _resolve(profile: DeviceProfile | None, cap: ThinqCapability):
        """(쓸 속성 이름, 판정 사양, 거절 이유). 프로필이 없으면 기본 이름을 그대로 쓴다."""
        if profile is None:
            return cap.property, None, None
        key = profile.resolve_key(cap.resource, cap.keys, location=cap.location)
        if key is None:
            return None, None, (f"이 모델 프로필에 '{cap.label}' 속성이 없어 보내지 않았어요 "
                                f"({cap.resource}.{'/'.join(cap.keys)})")
        spec = profile.spec(cap.resource, key, location=cap.location)
        if spec is None or not spec.writable:
            return None, spec, f"이 모델 프로필에서 '{cap.label}'은(는) 쓸 수 없는 속성이라 보내지 않았어요"
        return key, spec, None

    def profile_support(self, appliance_id: str) -> dict[str, dict]:
        """동작별로 이 모델 프로필이 허용하는 값(우리 후보 ∩ 프로필 쓰기 값). 프로필 모르면 {}."""
        binding = self._binding_of(appliance_id)
        if binding is None:
            return {}
        try:
            profile = self._profile(binding.device_id)
        except ThinqClientError:
            return {}
        if profile is None:
            return {}
        support = {}
        for cap in binding.capabilities:
            key, spec, _ = self._resolve(profile, cap)
            allowed = [v for v in cap.allowed if spec is not None and key is not None and spec.accepts(v)]
            support[cap.action] = {"property": key, "allowed": allowed}
        return support

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

    def execute_command(self, command: Command, *,
                        dispatch_guard: Callable[[ThinqBinding], None] | None = None) -> CommandResult:
        """``dispatch_guard``(선택, 3차 평가 H1): 프로필·상태 조회(네트워크 대기)를 **마친 뒤**, 클라우드로 보내기 직전에
        이번 전송 대상 바인딩을 넘겨 부른다. 예외를 올리면 보내지 않는다(``not_dispatched``, 예외 문장).
        이 확인은 이 실행기의 잠금 밖에서 부른다 — 정지(``request_stop``)가 그 확인을 기다리지 않는다.
        확인이 함수(전송권 확인, 4차 평가 H-N1)를 돌려주면 POST 바로 앞, 정지 확인과 같은 잠금 안에서 부르고, 예외면 보내지
        않는다 — 메모리 판정이라 짧다."""
        if command.route is not ControlRoute.THINQ:
            raise ValueError("ThinqController runs thinq commands only")
        requested_at = self._now()
        with self._lock:
            self._phase = "pending"
        try:
            return self._execute(command, requested_at, dispatch_guard)
        finally:
            with self._lock:
                self._phase = "idle"

    def _execute(self, command: Command, requested_at: datetime,
                 dispatch_guard: Callable[[ThinqBinding], None] | None = None) -> CommandResult:
        failed, not_sent = CommandStatus.FAILED, Receipt.NOT_DISPATCHED
        none = Confirmation.NONE
        binding = self._binding_of(command.target_id)
        if binding is None:
            return self._result(command, failed, not_sent, none,
                                "LG 가전이 등록되지 않아 보내지 않았어요.", requested_at)
        try:
            cap = binding.validate_command(command)
        except CapabilityError as exc:
            return self._result(command, failed, not_sent, none, f"보내지 않았어요: {exc}", requested_at)
        target = command.args_dict()[cap.arg]

        # 1) 기기 프로필 -- 그 속성이 있고, 쓰기 모드이고, 그 값을 쓸 수 있을 때만 보낸다.
        try:
            profile = self._profile(binding.device_id)
        except ThinqOfflineError as exc:
            return self._result(command, failed, not_sent, none,
                                _not_sent(exc, "가전에 연결되지 않았어요."), requested_at)
        except ThinqClientError as exc:
            return self._result(command, failed, not_sent, none,
                                _not_sent(exc, "가전 정보를 읽지 못했어요."),
                                requested_at)
        key, spec, refusal = self._resolve(profile, cap)
        if refusal is not None:
            return self._result(command, failed, not_sent, none, refusal, requested_at)
        if spec is not None and not spec.accepts(target):
            allowed = [cap.value_label(str(v)) for v in cap.allowed if spec.accepts(v)]
            return self._result(
                command, failed, not_sent, none,
                # 10/18 쉬운 말: 프로필 허용값 목록은 기록(로그)에만.
                f"이 가전은 {cap.setting_phrase(str(target))}{_josa_eul(cap.setting_phrase(str(target)))} 쓸 수 없어요. "
                "그래서 보내지 않았어요.", requested_at)
        confirm_resource, confirm_prop = cap.confirm or (cap.resource, key)
        confirmable = True
        if profile is not None:
            confirm_spec = profile.spec(confirm_resource, confirm_prop, location=cap.location)
            confirmable = confirm_spec is not None and confirm_spec.readable

        # 2) 보내기 전 상태 -- 이미 목표 상태면 보내지 않는다(아래 4). 값을 모르면(조회 실패·값 없음) 보내되(최대 1회),
        #    보낸 뒤 목표값을 봐도 '바꿨어요'가 아니라 '설정된 것을 확인했어요'(state_confirmed_unknown_before)다.
        #    원격 제어 허용을 먼저 봐야 하는 동작(세탁기)은 조회 없이 보내지 않는다.
        try:
            state = self._client.get_status(binding.device_id)
        except ThinqOfflineError as exc:
            self._observe(command.target_id, binding, None)
            return self._result(command, failed, not_sent, none,
                                _not_sent(exc, "가전에 연결되지 않았어요."), requested_at)
        except ThinqClientError as exc:
            # 값을 모른 채 보내는 것은 '읽는 중 끊김·응답 해석 실패'(ThinqTransportError)일 때뿐이다. 클라우드가
            # 코드로 거절한 조회(인증·권한·약관·국가·호출 한도 등)는 보내도 같은 이유로 막히거나 막혀야 하므로 보내지 않는다.
            if cap.requires_remote is not None or not isinstance(exc, ThinqTransportError):
                return self._result(command, failed, not_sent, none,
                                    _not_sent(exc, "가전 상태를 읽지 못했어요."),
                                    requested_at)
            state = None
        self._observe(command.target_id, binding, state)
        before = (read_state(state, confirm_resource, confirm_prop, location=cap.location)
                  if state is not None else None)
        if cap.requires_remote is not None:
            remote = read_state(state, *cap.requires_remote, location=cap.location)
            if remote is not True:
                reason = REMOTE_OFF_REASON if remote is False else REMOTE_UNKNOWN_REASON
                return self._result(command, failed, not_sent, none,
                                    f"{reason} 그래서 보내지 않았어요.", requested_at)

        # 3) 전송 직전 재판정(3차 평가 H1) -- 위 조회를 기다리는 동안 자동 실행 규칙이 꺼지거나 바뀌거나 지워졌으면,
        #    또는 대상 바인딩이 판단 때와 다르면 보내지 않는다. 메모리 판정만(입출력 없음), 이 실행기 잠금 밖.
        commit = None
        if dispatch_guard is not None:
            try:
                commit = dispatch_guard(binding)
            except Exception as exc:  # noqa: BLE001 -- 재판정에 걸림: 보내지 않는다
                return self._result(command, failed, not_sent, none,
                                    str(exc) or "보내기 직전 확인에 걸려 보내지 않았어요", requested_at)

        with self._lock:
            if self._cancel:
                return self._result(command, CommandStatus.STOPPED, not_sent, none,
                                    "정지를 눌러서 보내지 않았어요.", requested_at,
                                    stop_requested=True)
            # 4) 이미 목표값(2026-10-14) -- 확인할 속성을 읽을 수 있고 조회 값이 목표와 같으면 보내지 않는다. 정지·재판정을
            #    지난 뒤에만 이 결과를 낸다. 전송권 확인도 같은 자리에서 거친다(철회·꺼짐·정지 세대가 먼저면 '걸림') — 다만
            #    보내지 않으므로 '전송 개시'로 표시하지 않는다(``will_send=False``, 철회가 '이미 보내는 중'으로 보지 않게).
            already = confirmable and before is not None and cap.confirmed_by(target, before)
            if callable(commit):
                try:
                    if already:
                        commit(will_send=False)
                    else:
                        commit()
                except Exception as exc:  # noqa: BLE001 -- 전송권 없음: 보내지 않는다
                    return self._result(command, failed, not_sent, none,
                                        str(exc) or "보내기 직전 확인에 걸려 보내지 않았어요", requested_at)
            if already:
                return self._result(command, CommandStatus.SUCCEEDED, not_sent, Confirmation.ALREADY_AT_TARGET,
                                    already_sentence(cap.setting_phrase(str(target))),
                                    requested_at, confirmed_at=self._now())
            self._phase = "dispatched"
        # 보낸 뒤에는 이전 조회의 전원 값이 맞는지 모른다 — 확인 조회가 다시 적을 때까지 지운다.
        self._observe(command.target_id, binding, None)
        try:
            response = self._client.post_control(binding.device_id, cap.payload_for(target, key))
        except ThinqCommandRejected as exc:
            return self._result(command, failed, Receipt.ACCEPTED, none,
                                # 거절 코드는 화면에 내지 않는다(10/17 쉬운 말) — 기록에만.
                                _rejected_sentence(exc), requested_at)
        except ThinqOfflineError as exc:
            return self._result(command, failed, not_sent, none,
                                _not_sent(exc, "가전에 연결되지 않았어요."), requested_at)
        except Exception:  # noqa: BLE001 -- 전송 중 끊김·응답 유실·모르는 오류
            return self._result(command, CommandStatus.UNCONFIRMED, Receipt.UNKNOWN, none,
                                "보냈는지 몰라요. 가전을 봐 주세요.", requested_at,
                                stop_requested=self._stop_during_confirm)
        accepted_at = self._now()
        ref = response.get("messageId") if isinstance(response, dict) else None
        ref = str(ref) if ref else None

        if not confirmable:
            return self._result(command, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, none,
                                "보냈지만 이 가전은 결과를 알려 주지 않아요. 가전을 봐 주세요.",
                                requested_at, accepted_at=accepted_at, provider_ref=ref,
                                stop_requested=self._stop_during_confirm)
        deadline = self._monotonic() + self._confirm_seconds
        while True:
            with self._lock:
                stop = self._stop_during_confirm
            if stop:
                return self._result(command, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, none,
                                    "명령은 이미 보냈어요. 정지를 눌러서 확인은 멈췄어요.",
                                    requested_at, accepted_at=accepted_at, provider_ref=ref,
                                    stop_requested=True)
            try:
                seen = self._client.get_status(binding.device_id)
                self._observe(command.target_id, binding, seen)
                now_value = read_state(seen, confirm_resource, confirm_prop, location=cap.location)
            except Exception:  # noqa: BLE001 -- 조회 실패는 확인 못 함일 뿐
                now_value = None
            if now_value is not None and cap.confirmed_by(target, now_value):
                # 보내기 전 다른 값을 봤을 때만 '바꿨어요'. 전 값을 몰랐으면 원래 그 값이었을 수 있다.
                phrase = cap.setting_phrase(str(target))
                changed = before is not None
                return self._result(command, CommandStatus.SUCCEEDED, Receipt.ACCEPTED,
                                    Confirmation.STATE_CONFIRMED if changed
                                    else Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE,
                                    changed_sentence(phrase) if changed else target_seen_sentence(phrase),
                                    requested_at, accepted_at=accepted_at,
                                    confirmed_at=self._now(), provider_ref=ref)
            if self._monotonic() >= deadline:
                return self._result(command, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, none,
                                    f"보냈지만 {UNCONFIRMED_SENTENCE} 가전을 봐 주세요.",
                                    requested_at, accepted_at=accepted_at, provider_ref=ref)
            self._sleep(self._poll_interval)
