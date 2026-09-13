"""개발자 모드 — 세션·구조화 명령·모션 어댑터 계약 + 실행기 연결(Phase 1).

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

가 있다. Phase 1에서 더해진 계약(후속 교차 리뷰 #1~#4):

- **제어권은 ControlArbiter에서 원자적으로 얻는다.** Phase 0의
  ``execution_busy()`` 콜백은 서로의 락을 반대 순서로 잡는 교착 구조라
  제거했다. 락 순서: 개발자 락 → 중재자 락(leaf). 서비스 쪽도 서비스 락 →
  중재자 락이라 역전이 없다.
- **정지는 명령 처리를 기다리지 않는다.** 어댑터 호출은 상태 락 밖에서
  하고, 정지는 epoch를 올린 뒤 어댑터에 바로 닿는다. 정지와 경합해 늦게
  나간 명령은 epoch 불일치로 감지해 곧바로 다시 멈춘다.
- **정지 실패는 세션 폐기 ≠ 장치 사용 가능.** ``adapter.stop()``이 실패하면
  세션은 닫되 중재자에 fault(정지 미확인)를 걸어 새 실행·새 세션을 전부
  막는다. 복구는 명시적이다 — 이후 긴급 정지가 **실제로 확인되면** 푼다.
- **만료는 단조 시계(monotonic)로 판정한다.** 시스템 시각 변경(NTP 보정·
  수동 변경)이 heartbeat TTL을 늘리거나 줄이지 못한다.
- **mock 강제.** 실제 어댑터는 ``allow_real_adapter=True``를 명시해야만
  물릴 수 있다(H 주차에 하드웨어 확인 후 연다).

API 경로·화면 진입은 여전히 없다. 일반 사용자에게 노출되지 않는다.

안전 불변식(계획 문서 3.4)을 테스트가 못 박는다:
`rpi/tests/test_developer_session.py`.
"""

from __future__ import annotations

import logging
import re
import threading
import time
import uuid
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from typing import Protocol

from rpi.services.control_arbiter import ControlArbiter, ControlConflictError

log = logging.getLogger(__name__)

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

    ``stop()``은 **다른 호출이 진행 중이어도 병행 호출될 수 있어야 한다** --
    매니저는 정지를 명령 처리 뒤에 줄 세우지 않는다. 실물 어댑터(GRBL)의
    realtime stop 바이트가 정확히 이 성질을 갖는다.
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


class DevTargetUnknownError(ValueError):
    """등록되지 않은 가전을 대상으로 세션을 열 수 없다."""


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

    - 제어권은 ControlArbiter에서 원자적으로 얻는다 -- 일반 실행이 돌고
      있으면 acquire가 거절되고, 세션이 열려 있으면 실행기의 acquire가
      거절된다. 확인과 점유 사이의 창이 없다.
    - heartbeat가 ``heartbeat_ttl`` 동안 없으면 정지를 보내고 세션을 닫는다.
      판정은 단조 시계다 -- 시스템 시각을 바꿔도 TTL은 흔들리지 않는다.
      ``watchdog_interval_s``를 주면 자체 감시 스레드가 주기적으로
      :meth:`tick` 을 돈다(외부 호출 의존 없음).
    - :meth:`emergency_stop` 은 세션·명령 검증보다 먼저, 항상 어댑터에
      닿는다. 정지가 실패하면 fault를 걸어 장치를 잠그고, 이후 정지가
      실제로 확인될 때만 푼다.
    """

    DEFAULT_HEARTBEAT_TTL = timedelta(seconds=2)
    # jog 한 번이 유효한 시간. 누르고 있는 동안 화면이 이보다 자주 다시 보낸다.
    DEFAULT_JOG_TTL_S = 0.3
    LOG_LIMIT = 200

    def __init__(
        self,
        adapter: MotionAdapter,
        clock: _Clock,
        arbiter: ControlArbiter,
        is_calibrated: Callable[[str], bool],
        *,
        known_appliance: Callable[[str], bool] | None = None,
        known_button: Callable[[str, str], bool] | None = None,
        heartbeat_ttl: timedelta | None = None,
        jog_ttl_s: float | None = None,
        monotonic: Callable[[], float] = time.monotonic,
        watchdog_interval_s: float | None = None,
        allow_real_adapter: bool = False,
    ) -> None:
        # Phase 1은 mock 전용이다. 실물 어댑터는 하드웨어 검증(H 주차) 후
        # 호출부가 **명시적으로** allow_real_adapter=True를 줘야 물릴 수 있다.
        if not getattr(adapter, "is_mock", False) and not allow_real_adapter:
            raise RuntimeError(
                "개발자 모드 Phase 1은 mock 어댑터 전용입니다 -- 실물 어댑터는 "
                "하드웨어 검증 후 allow_real_adapter=True로만 연결합니다"
            )
        self._adapter = adapter
        self._clock = clock
        self._arbiter = arbiter
        self._is_calibrated = is_calibrated
        self._known_appliance = known_appliance
        self._known_button = known_button
        self._heartbeat_ttl = heartbeat_ttl or self.DEFAULT_HEARTBEAT_TTL
        self._jog_ttl_s = jog_ttl_s or self.DEFAULT_JOG_TTL_S
        self._monotonic = monotonic
        self._session: DevSession | None = None
        # 정지가 올라갈 때마다 1 증가 -- 락 밖에서 진행 중이던 명령이
        # "내가 검증받은 세대"와 대조해 정지 이후의 자신을 알아챈다.
        self._epoch = 0
        # heartbeat 만료 기준(단조 시계). datetime(expires_at)은 표시용이다.
        self._deadline: float | None = None
        self._log: deque[DevLogEntry] = deque(maxlen=self.LOG_LIMIT)
        self._lock = threading.Lock()
        # 어댑터 모션 호출(jog/home/press)의 직렬화 전용. 상태 락과 분리해
        # 정지·heartbeat·조회가 느린 어댑터 호출을 기다리지 않게 한다.
        # stop은 이 락을 잡지 않는다 -- 어댑터 계약이 병행 stop을 요구한다.
        self._dispatch_lock = threading.Lock()
        self._watchdog_interval_s = watchdog_interval_s
        self._watch_stop = threading.Event()
        self._watch_thread: threading.Thread | None = None
        self._closed = False

    # ── 조회 ──

    @property
    def session(self) -> DevSession | None:
        with self._lock:
            return self._session

    def blocks_execution(self) -> bool:
        """세션이 제어권을 갖고 있는가 -- 표시용. **실행 판정에 쓰지 않는다**:
        판정은 ControlArbiter.acquire가 원자적으로 한다."""
        with self._lock:
            return self._session is not None

    def log(self) -> list[DevLogEntry]:
        with self._lock:
            return list(self._log)

    # ── 세션 수명 ──

    def start(self, appliance_id: str, node_id: str) -> DevSession:
        if self._closed:
            raise DevSessionConflict("서버가 종료 중이라 세션을 열 수 없습니다")
        # 대상 검증이 제일 먼저다 -- 없는 가전의 세션은 제어권을 잡기 전에
        # 거절해야 중재자에 점유 흔적조차 남지 않는다.
        if self._known_appliance is not None and not self._known_appliance(
            appliance_id
        ):
            raise DevTargetUnknownError(
                f"등록되지 않은 가전입니다: {appliance_id}"
            )
        self.tick()  # 만료된 이전 세션이 있으면 정지·정리부터
        with self._lock:
            if self._session is not None:
                self._record("start_rejected", None, "다른 개발자 세션이 열려 있음",
                             appliance_id=appliance_id)
                raise DevSessionConflict("다른 개발자 세션이 이미 제어권을 갖고 있습니다")
            # 확인과 점유가 중재자 안에서 원자적 -- 일반 실행과 경합해도
            # 둘 다 통과하는 창이 없다. ControlFaultedError는 그대로 올린다
            # (정지 미확인 상태에서는 세션도 열 수 없다).
            try:
                self._arbiter.acquire(ControlArbiter.DEVELOPER)
            except ControlConflictError as exc:
                self._record("start_rejected", None, "일반 실행이 진행 중",
                             appliance_id=appliance_id)
                raise DevSessionConflict(
                    "일반 실행이 끝난 뒤에 시작할 수 있습니다"
                ) from exc
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
            self._deadline = (
                self._monotonic() + self._heartbeat_ttl.total_seconds()
            )
            self._record("session_started", None, f"node={node_id}")
        self._ensure_watchdog()
        return session

    def heartbeat(self, session_id: str) -> DevSession:
        self.tick()
        with self._lock:
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
            self._deadline = (
                self._monotonic() + self._heartbeat_ttl.total_seconds()
            )
            return refreshed

    def tick(self) -> str | None:
        """heartbeat가 끊긴 세션을 멈추고 닫는다. watchdog 스레드가 주기로
        부르고, 모든 진입점도 검증 전에 부른다(감시 주기 사이의 공백 방지)."""
        with self._lock:
            session = self._session
            if session is None or self._deadline is None:
                return None
            if self._monotonic() < self._deadline:
                return None
            self._close_session_locked()
        # 정지는 락 밖에서 -- 어댑터가 느려도 다른 정지·조회를 막지 않는다.
        self._send_stop("heartbeat_timeout", session, raise_on_failure=False)
        return "heartbeat_timeout"

    def end(self, session_id: str, reason: str = "session_ended") -> None:
        self.tick()
        with self._lock:
            session = self._require_locked(session_id)
            self._close_session_locked()
        self._send_stop(reason, session, raise_on_failure=True)

    def emergency_stop(self, reason: str = "emergency_stop") -> None:
        """세션이 있든 없든, 명령이 무엇이었든 **먼저** 멈춘다.

        정지가 실패하면 fault를 걸고 예외를 올린다. 정지가 성공하면 --
        그것이 곧 '기계가 멈췄다'는 확인이므로 -- 이전의 정지 미확인
        fault를 푼다. 이것이 fault의 명시적 복구 절차다.
        """
        with self._lock:
            session = self._session
            if session is not None:
                self._close_session_locked()
        self._send_stop(reason, session, raise_on_failure=True)

    def close(self) -> None:
        """서버 종료 정리 -- 감시 스레드를 멈추고, 열린 세션이 있으면
        정지를 보낸 뒤 닫는다. 이후 start()는 거절된다."""
        self._closed = True
        self._watch_stop.set()
        thread = self._watch_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        try:
            with self._lock:
                session = self._session
                if session is None:
                    return
                self._close_session_locked()
            self._send_stop("server_shutdown", session, raise_on_failure=False)
        except Exception:  # 종료 절차는 서로를 막지 않는다
            log.exception("developer session shutdown stop failed")

    # ── 명령 ──

    def submit(
        self,
        session_id: str,
        appliance_id: str,
        text: str,
        request_id: str | None = None,
    ) -> DevResult:
        request_id = request_id or uuid.uuid4().hex[:12]
        # 정지는 세션 검증보다 앞선다 -- 멈추라는 말은 언제나 통한다.
        if isinstance(text, str) and text.strip().lower() == "stop":
            with self._lock:
                session = self._session
                if session is not None:
                    self._close_session_locked()
            ok = self._send_stop(
                "user_stop", session, raise_on_failure=False,
                request_id=request_id,
            )
            if ok:
                return DevResult(True, request_id, normalized="stop")
            return DevResult(
                False,
                request_id,
                normalized="stop",
                reason="정지를 보냈지만 확인하지 못했어요 -- 기기를 잠갔습니다. "
                "긴급 정지로 정지를 확인해 주세요.",
            )

        try:
            command = parse_dev_command(text)
        except DevCommandRejected as exc:
            return self._reject(request_id, str(exc), appliance_id)

        self.tick()
        with self._lock:
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
            if command.kind is DevCommandKind.PRESS:
                if self._known_button is not None and not self._known_button(
                    appliance_id, command.button_id
                ):
                    return self._reject_locked(
                        request_id,
                        f"이 가전에 등록되지 않은 버튼입니다: {command.button_id}",
                        appliance_id,
                    )
                if not self._is_calibrated(appliance_id):
                    return self._reject_locked(
                        request_id,
                        "버튼 위치 보정이 끝나지 않은 가전은 누를 수 없습니다",
                        appliance_id,
                    )
            epoch = self._epoch

        # 어댑터 호출은 상태 락 밖 -- 정지·heartbeat가 이 호출을 기다리지
        # 않는다. dispatch 락은 모션 호출끼리의 직렬화만 담당한다.
        with self._dispatch_lock:
            with self._lock:
                if self._epoch != epoch:
                    return self._reject_locked(
                        request_id,
                        "정지되어 명령을 보내지 않았습니다",
                        appliance_id,
                    )
            sensor = self._dispatch(command)

        with self._lock:
            stale = self._epoch != epoch
            if not stale:
                self._record(
                    "command_accepted",
                    request_id,
                    command.normalized(),
                    appliance_id=appliance_id,
                )
        if stale:
            # 명령이 정지와 경합해 정지 **뒤에** 어댑터에 닿았을 수 있다.
            # 최종 상태를 '멈춤'으로 만든다 -- 어댑터의 명령 흐름에서 이
            # stop이 그 명령보다 뒤이므로, 기계는 멈춘 채로 끝난다.
            ok = self._send_stop(
                "stop_after_late_command", None, raise_on_failure=False,
                request_id=request_id,
                # 늦은 명령이 어댑터에 닿았을 수 있다 -- 재정지가 실패하면
                # 기계 상태를 모르는 것이므로 잠근다.
                trip_on_failure=True,
            )
            reason = (
                "정지 요청과 겹쳐 명령을 취소하고 다시 멈췄습니다"
                if ok
                else "정지 요청과 겹쳤고 재정지도 확인하지 못했습니다 -- 기기를 잠갔습니다"
            )
            return DevResult(False, request_id, reason=reason)
        return DevResult(
            True, request_id, normalized=command.normalized(), sensor=sensor
        )

    # ── 내부 ──

    def _dispatch(self, command: DevCommand) -> dict[str, float] | None:
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

    def _close_session_locked(self) -> None:
        """세션 해제 + epoch 증가. **어댑터를 부르지 않는다** -- 정지 전송은
        락 밖의 _send_stop이 한다. 제어권 반납도 거기서(정지 시도 후) 한다:
        여기서 먼저 반납하면 기계가 아직 멈추지 않았는데 일반 실행이
        제어권을 얻는 창이 생긴다."""
        self._session = None
        self._deadline = None
        self._epoch += 1

    def _send_stop(
        self,
        reason: str,
        session: DevSession | None,
        *,
        raise_on_failure: bool,
        request_id: str | None = None,
        trip_on_failure: bool | None = None,
    ) -> bool:
        """어댑터에 정지를 보내고 결과를 fault/복구로 옮긴다. 락 밖 전용.

        - 성공: '기계가 멈췄다'는 확인이므로 이전 fault(정지 미확인)를 푼다.
        - 실패 + 기계가 움직였을 수 있음(세션이 있었거나 늦은 명령이 나감):
          fault를 걸어 새 실행·새 세션을 막는다.
        - 실패 + 움직이던 주체 없음: 잠그지 않고 실패만 기록한다(유휴
          상태의 어댑터 단절로 시스템 전체가 잠기면 안 된다).

        제어권 반납은 정지 시도 **후**, 그리고 **이 호출이 세션을 닫았을
        때만** 한다 -- 무조건 반납하면 그 사이 새로 열린 세션의 제어권을
        벗겨내, 세션은 있는데 중재자는 비어 있는 상태(일반 실행과 동시
        조작 가능)가 된다.
        """
        should_trip = (
            trip_on_failure if trip_on_failure is not None
            else session is not None
        )
        try:
            self._adapter.stop(reason)
        except Exception:
            if should_trip:
                # 반납보다 fault가 먼저다 -- 둘 사이에 실행이 제어권을
                # 얻는 창을 만들지 않는다.
                self._arbiter.trip_fault(f"stop_unconfirmed:{reason}")
            with self._lock:
                self._record(
                    "stop_unconfirmed", request_id, reason, session=session,
                    appliance_id=session.appliance_id if session else None,
                )
            if session is not None:
                self._arbiter.release(ControlArbiter.DEVELOPER)
            if raise_on_failure:
                raise
            log.exception("developer stop unconfirmed (reason=%s)", reason)
            return False
        else:
            if (self._arbiter.fault_reason or "").startswith(
                "stop_unconfirmed:"
            ):
                self._arbiter.clear_fault()
                with self._lock:
                    self._record(
                        "fault_cleared", request_id,
                        f"정지 확인됨({reason})", session=session,
                    )
            with self._lock:
                self._record(
                    "stopped", request_id, reason, session=session,
                    appliance_id=session.appliance_id if session else None,
                )
            if session is not None:
                self._arbiter.release(ControlArbiter.DEVELOPER)
            return True

    def _ensure_watchdog(self) -> None:
        if self._watchdog_interval_s is None or self._closed:
            return
        with self._lock:
            if self._watch_thread is not None and self._watch_thread.is_alive():
                return
            self._watch_thread = threading.Thread(
                target=self._watch_loop,
                daemon=True,
                name="simplelay-dev-watchdog",
            )
            self._watch_thread.start()

    def _watch_loop(self) -> None:
        interval = self._watchdog_interval_s or 0.5
        while not self._watch_stop.wait(interval):
            try:
                self.tick()
            except Exception:  # 감시 실패가 감시를 죽여선 안 된다
                log.exception("developer session watchdog tick failed")

    def _require_locked(self, session_id: str) -> DevSession:
        session = self._session
        if session is None or session.session_id != session_id:
            raise DevSessionExpired("열린 개발자 세션이 아닙니다")
        return session

    def _reject(
        self, request_id: str, reason: str, appliance_id: str | None
    ) -> DevResult:
        with self._lock:
            return self._reject_locked(request_id, reason, appliance_id)

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
