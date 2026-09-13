"""개발자 모드 Phase 0 — 세션·구조화 명령·모션 어댑터 **계약**만.

하드웨어가 오기 전에 굳혀 두는 것은 "무엇을 허용하고 무엇을 막는가"다.
실제 축 방향·mm당 step·속도·리밋 극성·누름 깊이는 하드웨어 확인 전까지
모르는 값이라 여기서 정하지 않는다. 이 모듈에는

- 허용 목록 기반 명령 파서 (셸·파일·raw 바이트 전송 없음)
- 한 번에 하나의 개발자 세션, heartbeat가 끊기면 스스로 정지
- 짧은 TTL로만 나가는 jog (무기한 이동 명령 없음)
- 세션·인증과 무관하게 항상 먼저 도는 긴급 정지
- 보정 안 된 가전의 press 차단
- request_id로 이어지는 구조화 로그
- 기록만 하는 mock 어댑터

만 있다. **API 경로도, 화면 진입도, 실제 모션 어댑터도 없다.** 일반 사용자에게
노출되지 않으며, 실행기(SimpleLayService)와의 연결은 다음 단계에서 한다.

안전 불변식(계획 문서 3.4)을 테스트가 못 박는다:
`rpi/tests/test_developer_session.py`.
"""

from __future__ import annotations

import re
import threading
import uuid
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from typing import Protocol

# ── 명령 ──────────────────────────────────────────────────────────────────


class DevAxis(str, Enum):
    X = "x"
    Y = "y"
    Z = "z"


class DevCommandKind(str, Enum):
    STATUS = "status"
    HOME = "home"
    JOG = "jog"
    SENSOR_READ = "sensor read"
    PRESS = "press"
    STOP = "stop"


# 한 번의 jog 요청이 움직일 수 있는 상한(mm). **하드웨어 확인 전 임시값**이다 --
# 실제 안전 이동 범위는 H3·H4에서 재고 정한다. 작게 잡는 쪽이 안전하다.
MAX_JOG_MM = 5.0

# 버튼 id는 서버에 등록된 식별자 모양만 받는다. 공백·셸 문자는 들어올 수 없다.
_BUTTON_ID = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
_AMOUNT = re.compile(r"^\d+(\.\d+)?$")


class DevCommandRejected(ValueError):
    """허용 목록 밖이거나 모양이 틀린 명령. 어댑터로 **보내지 않는다.**"""


@dataclass(frozen=True)
class DevCommand:
    kind: DevCommandKind
    axis: DevAxis | None = None
    direction: int = 0  # +1 / -1
    amount_mm: float = 0.0
    button_id: str | None = None

    def normalized(self) -> str:
        """실행 전에 사용자에게 보여줄 정규화 결과."""
        if self.kind is DevCommandKind.JOG:
            sign = "+" if self.direction > 0 else "-"
            return f"jog {self.axis.value} {sign} {self.amount_mm:g}"
        if self.kind is DevCommandKind.PRESS:
            return f"press {self.button_id}"
        return self.kind.value


def parse_dev_command(text: str) -> DevCommand:
    """구조화 명령만 받는다. 알 수 없으면 거절하고, 무엇도 추측하지 않는다.

    허용: ``status`` · ``home`` · ``sensor read`` · ``stop`` ·
    ``jog <x|y|z> <+|-> <mm>`` · ``press <button_id>``
    """
    if not isinstance(text, str):
        raise DevCommandRejected("명령은 글자여야 합니다")
    # 제어 문자·줄바꿈이 섞이면 한 줄에 여러 명령을 숨길 수 있다.
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in text):
        raise DevCommandRejected("제어 문자가 섞인 명령은 받지 않습니다")
    tokens = text.strip().lower().split()
    if not tokens:
        raise DevCommandRejected("빈 명령입니다")

    head = tokens[0]
    if head in ("status", "home", "stop") and len(tokens) == 1:
        return DevCommand(DevCommandKind(head))
    if tokens == ["sensor", "read"]:
        return DevCommand(DevCommandKind.SENSOR_READ)
    if head == "jog":
        return _parse_jog(tokens)
    if head == "press":
        # 버튼 id는 대소문자를 보존해야 한다(BT-05) -- 원문에서 다시 꺼낸다.
        raw = text.strip().split()
        if len(raw) != 2 or not _BUTTON_ID.match(raw[1]):
            raise DevCommandRejected("press <버튼 id> 형식이어야 합니다")
        return DevCommand(DevCommandKind.PRESS, button_id=raw[1])
    raise DevCommandRejected(f"허용 목록에 없는 명령입니다: {head}")


def _parse_jog(tokens: list[str]) -> DevCommand:
    if len(tokens) != 4:
        raise DevCommandRejected("jog <x|y|z> <+|-> <mm> 형식이어야 합니다")
    _, axis, sign, amount = tokens
    try:
        dev_axis = DevAxis(axis)
    except ValueError as exc:
        raise DevCommandRejected(f"축은 x·y·z만 됩니다: {axis}") from exc
    if sign not in ("+", "-"):
        raise DevCommandRejected("방향은 + 또는 - 입니다")
    if not _AMOUNT.match(amount):
        raise DevCommandRejected("이동량은 양의 숫자(mm)여야 합니다")
    mm = float(amount)
    if mm <= 0 or mm > MAX_JOG_MM:
        raise DevCommandRejected(
            f"이동량은 0보다 크고 {MAX_JOG_MM:g}mm 이하여야 합니다"
        )
    return DevCommand(
        DevCommandKind.JOG,
        axis=dev_axis,
        direction=1 if sign == "+" else -1,
        amount_mm=mm,
    )


# ── 모션 어댑터 ───────────────────────────────────────────────────────────


class MotionAdapter(Protocol):
    """개발자 도구가 기계에 말하는 유일한 통로.

    jog에는 **TTL이 반드시** 붙는다. 어댑터는 TTL이 지나면 새 명령이 없어도
    스스로 멈춰야 한다(누르고 있는 동안만 갱신). 실제 어댑터는 하드웨어 수령
    뒤에 만든다 -- 그 전까지는 이 계약과 아래 mock만 있다.
    """

    is_mock: bool

    def jog(
        self, axis: DevAxis, direction: int, amount_mm: float, ttl_s: float
    ) -> None: ...

    def home(self) -> None: ...

    def press(self, button_id: str) -> None: ...

    def stop(self, reason: str) -> None: ...

    def read_sensor(self) -> dict[str, float]: ...


@dataclass
class MockMotionAdapter:
    """아무것도 움직이지 않고 받은 호출만 기록한다."""

    is_mock: bool = True
    calls: list[tuple] = field(default_factory=list)

    def jog(
        self, axis: DevAxis, direction: int, amount_mm: float, ttl_s: float
    ) -> None:
        self.calls.append(("jog", axis, direction, amount_mm, ttl_s))

    def home(self) -> None:
        self.calls.append(("home",))

    def press(self, button_id: str) -> None:
        self.calls.append(("press", button_id))

    def stop(self, reason: str) -> None:
        self.calls.append(("stop", reason))

    def read_sensor(self) -> dict[str, float]:
        self.calls.append(("sensor",))
        return {"current_ma": 0.0, "sound_db": 0.0}

    def stops(self) -> list[str]:
        return [c[1] for c in self.calls if c[0] == "stop"]

    def motion_calls(self) -> list[tuple]:
        return [c for c in self.calls if c[0] in ("jog", "home", "press")]


# ── 세션 ──────────────────────────────────────────────────────────────────


class DevSessionConflict(RuntimeError):
    """다른 세션이나 일반 실행이 이미 제어권을 갖고 있다."""


class DevSessionExpired(RuntimeError):
    """세션이 없거나 heartbeat가 끊겨 이미 정지·종료됐다."""


@dataclass(frozen=True)
class DevSession:
    session_id: str
    appliance_id: str
    node_id: str
    started_at: datetime
    last_heartbeat: datetime
    expires_at: datetime


@dataclass(frozen=True)
class DevLogEntry:
    at: datetime
    event: str
    request_id: str | None
    session_id: str | None
    appliance_id: str | None
    detail: str
    mock: bool


@dataclass(frozen=True)
class DevResult:
    accepted: bool
    request_id: str
    normalized: str | None = None
    reason: str | None = None
    sensor: dict[str, float] | None = None


class _Clock(Protocol):
    def now(self) -> datetime: ...


class DeveloperSessionManager:
    """개발자 제어권을 한 번에 하나만 내준다.

    - 일반 실행이 돌고 있으면 세션을 열지 않고, 세션 중에 일반 실행이 시작돼도
      명령을 받지 않는다(동시에 두 주체가 기계를 움직이지 않는다).
      세션이 열려 있다는 사실은 :meth:`blocks_execution` 으로 실행기에 알린다.
    - heartbeat가 ``heartbeat_ttl`` 동안 없으면 :meth:`tick` 이 정지를 보내고
      세션을 닫는다. 성공을 추측하지 않는다 -- 모르면 멈춘다.
    - :meth:`emergency_stop` 은 세션·명령 검증보다 먼저, 항상 어댑터에 닿는다.
    """

    DEFAULT_HEARTBEAT_TTL = timedelta(seconds=2)
    # jog 한 번이 유효한 시간. 누르고 있는 동안 화면이 이보다 자주 다시 보낸다.
    DEFAULT_JOG_TTL_S = 0.3
    LOG_LIMIT = 200

    def __init__(
        self,
        adapter: MotionAdapter,
        clock: _Clock,
        execution_busy: Callable[[], bool],
        is_calibrated: Callable[[str], bool],
        heartbeat_ttl: timedelta | None = None,
        jog_ttl_s: float | None = None,
    ) -> None:
        self._adapter = adapter
        self._clock = clock
        self._execution_busy = execution_busy
        self._is_calibrated = is_calibrated
        self._heartbeat_ttl = heartbeat_ttl or self.DEFAULT_HEARTBEAT_TTL
        self._jog_ttl_s = jog_ttl_s or self.DEFAULT_JOG_TTL_S
        self._session: DevSession | None = None
        self._log: deque[DevLogEntry] = deque(maxlen=self.LOG_LIMIT)
        self._lock = threading.Lock()

    # ── 조회 ──

    @property
    def session(self) -> DevSession | None:
        with self._lock:
            return self._session

    def blocks_execution(self) -> bool:
        """개발자 세션이 제어권을 갖고 있는가 -- 실행기는 이때 일반 실행을 거절한다."""
        with self._lock:
            return self._session is not None

    def log(self) -> list[DevLogEntry]:
        with self._lock:
            return list(self._log)

    # ── 세션 수명 ──

    def start(self, appliance_id: str, node_id: str) -> DevSession:
        with self._lock:
            self._expire_locked()
            if self._session is not None:
                self._record("start_rejected", None, "다른 개발자 세션이 열려 있음",
                             appliance_id=appliance_id)
                raise DevSessionConflict("다른 개발자 세션이 이미 제어권을 갖고 있습니다")
            if self._execution_busy():
                self._record("start_rejected", None, "일반 실행이 진행 중",
                             appliance_id=appliance_id)
                raise DevSessionConflict("일반 실행이 끝난 뒤에 시작할 수 있습니다")
            now = self._clock.now()
            session = DevSession(
                session_id=uuid.uuid4().hex[:12],
                appliance_id=appliance_id,
                node_id=node_id,
                started_at=now,
                last_heartbeat=now,
                expires_at=now + self._heartbeat_ttl,
            )
            self._session = session
            self._record("session_started", None, f"node={node_id}")
            return session

    def heartbeat(self, session_id: str) -> DevSession:
        with self._lock:
            self._expire_locked()
            current = self._require_locked(session_id)
            now = self._clock.now()
            refreshed = DevSession(
                session_id=current.session_id,
                appliance_id=current.appliance_id,
                node_id=current.node_id,
                started_at=current.started_at,
                last_heartbeat=now,
                expires_at=now + self._heartbeat_ttl,
            )
            self._session = refreshed
            return refreshed

    def tick(self) -> str | None:
        """주기적으로 불린다. heartbeat가 끊긴 세션을 멈추고 닫는다."""
        with self._lock:
            return self._expire_locked()

    def end(self, session_id: str, reason: str = "session_ended") -> None:
        with self._lock:
            self._require_locked(session_id)
            self._stop_and_close_locked(reason)

    def emergency_stop(self, reason: str = "emergency_stop") -> None:
        """세션이 있든 없든, 명령이 무엇이었든 **먼저** 멈춘다."""
        with self._lock:
            self._stop_and_close_locked(reason)

    # ── 명령 ──

    def submit(
        self,
        session_id: str,
        appliance_id: str,
        text: str,
        request_id: str | None = None,
    ) -> DevResult:
        request_id = request_id or uuid.uuid4().hex[:12]
        with self._lock:
            # 정지는 세션 검증보다 앞선다 -- 멈추라는 말은 언제나 통한다.
            if isinstance(text, str) and text.strip().lower() == "stop":
                self._stop_and_close_locked("user_stop", request_id=request_id)
                return DevResult(True, request_id, normalized="stop")

            try:
                command = parse_dev_command(text)
            except DevCommandRejected as exc:
                return self._reject_locked(request_id, str(exc), appliance_id)

            self._expire_locked()
            session = self._session
            if session is None or session.session_id != session_id:
                return self._reject_locked(
                    request_id, "열린 개발자 세션이 아닙니다", appliance_id
                )
            # 매 명령마다 대상을 다시 확인한다 -- 다른 가전을 움직이는 사고를 막는다.
            if session.appliance_id != appliance_id:
                return self._reject_locked(
                    request_id,
                    "세션의 대상 가전과 다릅니다",
                    appliance_id,
                )
            if self._execution_busy():
                return self._reject_locked(
                    request_id, "일반 실행이 진행 중입니다", appliance_id
                )
            if command.kind is DevCommandKind.PRESS and not self._is_calibrated(
                appliance_id
            ):
                return self._reject_locked(
                    request_id,
                    "버튼 위치 보정이 끝나지 않은 가전은 누를 수 없습니다",
                    appliance_id,
                )

            sensor = self._dispatch_locked(command)
            self._record(
                "command_accepted",
                request_id,
                command.normalized(),
                appliance_id=appliance_id,
            )
            return DevResult(
                True, request_id, normalized=command.normalized(), sensor=sensor
            )

    # ── 내부 ──

    def _dispatch_locked(self, command: DevCommand) -> dict[str, float] | None:
        match command.kind:
            case DevCommandKind.JOG:
                self._adapter.jog(
                    command.axis,
                    command.direction,
                    command.amount_mm,
                    self._jog_ttl_s,
                )
            case DevCommandKind.HOME:
                self._adapter.home()
            case DevCommandKind.PRESS:
                self._adapter.press(command.button_id)
            case DevCommandKind.SENSOR_READ:
                return self._adapter.read_sensor()
            case DevCommandKind.STATUS | DevCommandKind.STOP:
                pass
        return None

    def _require_locked(self, session_id: str) -> DevSession:
        session = self._session
        if session is None or session.session_id != session_id:
            raise DevSessionExpired("열린 개발자 세션이 아닙니다")
        return session

    def _expire_locked(self) -> str | None:
        session = self._session
        if session is None:
            return None
        if self._clock.now() < session.expires_at:
            return None
        self._stop_and_close_locked("heartbeat_timeout")
        return "heartbeat_timeout"

    def _stop_and_close_locked(
        self, reason: str, request_id: str | None = None
    ) -> None:
        session = self._session
        # 멈춤 요청이 실패해도 세션은 닫는다. 기계 상태를 모르는 채로 제어권을
        # 남겨 두면, 다음 명령이 멈춘 줄 아는 기계를 움직인다.
        try:
            self._adapter.stop(reason)
        finally:
            self._session = None
            self._record(
                "stopped",
                request_id,
                reason,
                session=session,
                appliance_id=session.appliance_id if session else None,
            )

    def _reject_locked(
        self, request_id: str, reason: str, appliance_id: str | None
    ) -> DevResult:
        self._record(
            "command_rejected", request_id, reason, appliance_id=appliance_id
        )
        return DevResult(False, request_id, reason=reason)

    def _record(
        self,
        event: str,
        request_id: str | None,
        detail: str,
        *,
        session: DevSession | None = None,
        appliance_id: str | None = None,
    ) -> None:
        current = session if session is not None else self._session
        self._log.append(
            DevLogEntry(
                at=self._clock.now(),
                event=event,
                request_id=request_id,
                session_id=current.session_id if current else None,
                appliance_id=appliance_id
                or (current.appliance_id if current else None),
                detail=detail,
                mock=bool(getattr(self._adapter, "is_mock", False)),
            )
        )
