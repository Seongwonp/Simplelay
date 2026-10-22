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
- **정지는 명령 처리를 기다리지 않지만, 제어권 반납은 기다린다.** 어댑터
  호출은 상태 락 밖에서 하고, 정지는 epoch를 올린 뒤 어댑터에 바로 닿는다.
  정지와 경합해 늦게 나간 명령은 epoch 불일치로 감지해 곧바로 다시 멈추고,
  그 재정지가 확인될 때까지 제어권은 반납되지 않는다(stopping 상태) --
  "마지막 호출이 stop이었다"가 아니라 "이전 명령이 다시 동작할 수 없는
  상태"가 다음 제어권의 조건이다. 어댑터 예외로 끝난 명령도 같은 settle
  경로를 지나 정지로 정리된다.
- **정지 실패는 세션 폐기 ≠ 장치 사용 가능.** ``adapter.stop()``이 실패하면
  세션은 닫되 중재자에 fault(정지 미확인)를 걸어 새 실행·새 세션을 전부
  막는다. 복구는 명시적이다 — 이후 긴급 정지가 **실제로 확인되면** 푼다.
- **만료는 단조 시계(monotonic)로 판정한다.** 시스템 시각 변경(NTP 보정·
  수동 변경)이 heartbeat TTL을 늘리거나 줄이지 못한다.
- **mock 강제.** 실제 어댑터는 ``allow_real_adapter=True``를 명시해야만
  물릴 수 있다(H 주차에 하드웨어 확인 후 연다).
- **실물 경로(2026-10-10).** 서버는 ``SIMPLELAY_DEV_MODE``와 ``SIMPLELAY_DEV_REAL_MOTION``이 둘 다
  켜졌을 때만 RPi4 링크 어댑터(`rpi.services.dev_real_motion.ActDevMotionAdapter`)를
  ``allow_real_adapter=True``로 문다. 어댑터가 움직이기 **전에** 거절하면 `DevAdapterRefused`를 올리고,
  매니저는 그 코드로 거절한다(정지를 따로 보내지 않는다 — 움직이지 않았다). 그 밖의 예외(움직였을 수
  있음)는 종전대로 정지로 정리한다. 실물 어댑터의 한 번 조그 상한은 ``max_step_mm``로 더 작을 수 있다
  (`max_jog_mm`).

API 경로는 rpi/api/dev_router.py, 폰 화면은 app/lib/screens/developer_console_screen.dart.

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


class DevAdapterRefused(RuntimeError):
    """어댑터가 **움직이기 전에** 명령을 거절했다(2026-10-10, 실물 경로).

    ``code``는 API ``detail.code``로 그대로 나간다(``not_homed``·``estop_latched``·``link_down`` 등).
    움직이지 않았으므로 매니저는 정지를 따로 보내지 않고 세션을 유지한다.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class MotionAdapter(Protocol):
    """개발자 도구가 기계에 말하는 유일한 통로.

    jog에는 TTL을 넘긴다. 모의 어댑터는 눌림 갱신에 쓰고, 실물 어댑터는
    한 번의 유한한 상대 이동으로 끝내며 실제 좌표·목표 도착 여부를 돌려줄 수 있다.

    ``stop()``은 **다른 호출이 진행 중이어도 병행 호출될 수 있어야 한다** --
    매니저는 정지를 명령 처리 뒤에 줄 세우지 않는다.
    """

    is_mock: bool

    def jog(
        self, axis: DevAxis, direction: int, amount_mm: float, ttl_s: float
    ) -> dict[str, float] | None: ...

    def home(self) -> None: ...

    def press(self, button_id: str) -> None: ...

    def stop(self, reason: str) -> "dict | None": ...
    # 정지는 확인 단계 ``{"stop_level", "ack_ms"}``를 돌려줄 수 있다(실물 어댑터, 2026-10-13). 모의는 None.

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
    """다른 세션이나 일반 실행이 이미 제어권을 갖고 있다.

    ``code``가 이유를 가른다 -- 같은 거절이라도 화면이 해야 할 말이 다르다:
    ``session_conflict``(다른 개발자 세션) · ``execution_busy``(일반 실행 중) ·
    ``stopping``(이전 세션의 정지 정리 중) · ``shutting_down``(서버 종료 중).
    """

    def __init__(self, message: str, code: str = "session_conflict") -> None:
        super().__init__(message)
        self.code = code


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
    #: 거절 사유의 기계용 이름(accepted면 None). 사람용 문장(reason)을
    #: 화면이 잘라 쓰게 하면 문구가 바뀔 때 조용히 깨진다.
    #: invalid_command · session_expired · wrong_target · unknown_button ·
    #: not_calibrated · stopped · stop_race · command_error · stop_unconfirmed
    code: str | None = None


# 화면·API가 보는 제어 국면. 판정에 쓰지 않는다 -- 제어권 판정은
# ControlArbiter.acquire와 _maybe_release_locked가 원자적으로 한다.
PHASE_IDLE = "idle"
PHASE_ACTIVE = "active"
PHASE_STOPPING = "stopping"
PHASE_FAULT = "fault"
PHASE_EXECUTION_BUSY = "execution_busy"
#: 개발자 세션 밖에서 기계를 움직이는 제어권 이름 — 일반 실행과 확인 주행(자리 확인). 둘 다 ``execution_busy``다.
_MOVING_HOLDERS = frozenset({ControlArbiter.EXECUTION, ControlArbiter.VERIFY_PASS})


@dataclass(frozen=True)
class DevControlState:
    """개발자 제어 상태 한 장(표시용 스냅샷).

    국면 우선순위: fault > stopping > active > execution_busy > idle.
    정지 미확인(fault)은 무엇보다 먼저 보여야 한다 -- 그 상태를 다른
    국면으로 덮으면 사용자는 멈춘 줄 안다.
    """

    phase: str
    session: DevSession | None
    fault_reason: str | None
    mock: bool
    shutting_down: bool


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
        # ── 제어권 반납 판정 상태 (전부 _lock 보호) ──
        # 반납은 조건문을 여기저기 두지 않고 _maybe_release_locked() 한곳이
        # 판정한다(후속 리뷰 1.3): "누가 마지막으로 끝났는가"가 아니라
        # "필요한 안전 조건이 모두 충족됐는가"가 기준이다.
        #
        # 어댑터 모션 호출 + 그 명령의 안전 정리가 진행 중인가. 정지는
        # 이것을 기다리지 않지만 반납은 기다린다(1.1-#1, 1.2).
        self._inflight = False
        # 진행 중인 어댑터 stop 호출 개수. 정지가 "요청됨"과 "확인됨"은
        # 다르다 -- 응답 대기 중인 정지가 있는 동안 반납하면, 그 정지가
        # 늦게 실패했을 때 이미 새 실행이 돌고 있다(1.3).
        self._stops_inflight = 0
        # 세션이 닫혀 제어권을 돌려줘야 한다는 빚(owed). 반납 그 자체가
        # 아니라 "조건이 갖춰지면 반납하라"는 표시다.
        self._release_owed = False
        # 빚이 생긴 뒤(세션 닫힘 이후) 정지가 한 번이라도 **확인**됐는가.
        # 미확인 상태의 반납은 fault가 걸려 있을 때만 허용된다.
        self._stop_confirmed_since_owed = False
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

    @property
    def heartbeat_ttl_s(self) -> float:
        return self._heartbeat_ttl.total_seconds()

    @property
    def is_mock(self) -> bool:
        return bool(getattr(self._adapter, "is_mock", False))

    @property
    def max_jog_mm(self) -> float:
        """한 번 조그 상한(mm). 어댑터가 더 작은 상한(``max_step_mm``)을 밝히면 그것."""
        own = getattr(self._adapter, "max_step_mm", None)
        if isinstance(own, (int, float)) and 0 < own < MAX_JOG_MM:
            return float(own)
        return MAX_JOG_MM

    def adapter_status(self) -> tuple[bool, str | None] | None:
        """실물 어댑터의 준비 상태 ``(준비됨, 이유)`` — 표시용. 모의 어댑터처럼 밝히지 않으면 None."""
        availability = getattr(self._adapter, "availability", None)
        if not callable(availability):
            return None
        try:
            problem = availability()
        except Exception as exc:  # noqa: BLE001 - 상태 조회 고장은 '준비 안 됨'으로 보인다
            log.exception("developer adapter availability failed")
            return False, f"실제 장치 상태를 확인하지 못했어요: {exc}"
        if problem is None:
            return True, None
        return False, problem[1]

    def state(self) -> DevControlState:
        """표시용 스냅샷. 만료된 세션이 있으면 먼저 정리해서, 이미 끊긴
        세션을 '진행 중'으로 보여주지 않는다.

        중재자 상태를 개발자 락 안에서 읽는다 -- 개발자 락 → 중재자 락은
        이 모듈 전체의 락 순서와 같다.
        """
        self.tick()
        with self._lock:
            session = self._session
            stopping = self._release_owed
            shutting_down = self._closed
            fault_reason, _ = self._arbiter.fault_snapshot()
            holder = self._arbiter.holder
        if fault_reason is not None:
            phase = PHASE_FAULT
        elif stopping:
            phase = PHASE_STOPPING
        elif session is not None:
            phase = PHASE_ACTIVE
        elif holder in _MOVING_HOLDERS:
            phase = PHASE_EXECUTION_BUSY
        else:
            phase = PHASE_IDLE
        return DevControlState(
            phase=phase,
            session=session,
            fault_reason=fault_reason,
            mock=self.is_mock,
            shutting_down=shutting_down,
        )

    # ── 세션 수명 ──

    def start(self, appliance_id: str, node_id: str) -> DevSession:
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
            # 종료 판정은 세션 생성과 **같은 락 안**이다 -- 락 밖에서 먼저
            # 읽으면 close()가 그 직후 종료를 마쳐도 세션이 만들어져,
            # 감시자 없는 세션이 종료된 서버에 남는다(후속 리뷰 1.1-#3).
            if self._closed:
                raise DevSessionConflict(
                    "서버가 종료 중이라 세션을 열 수 없습니다",
                    code="shutting_down",
                )
            if self._session is not None:
                self._record("start_rejected", None, "다른 개발자 세션이 열려 있음",
                             appliance_id=appliance_id)
                raise DevSessionConflict(
                    "다른 개발자 세션이 이미 제어권을 갖고 있습니다",
                    code="session_conflict",
                )
            # 확인과 점유가 중재자 안에서 원자적 -- 일반 실행과 경합해도
            # 둘 다 통과하는 창이 없다. ControlFaultedError는 그대로 올린다
            # (정지 미확인 상태에서는 세션도 열 수 없다).
            try:
                self._arbiter.acquire(ControlArbiter.DEVELOPER)
            except ControlConflictError as exc:
                # holder가 DEVELOPER인데 세션이 없다면 stopping 상태다 --
                # 이전 세션의 진행 중 명령이 무효화 확인을 기다리고 있다.
                # 확인 주행(자리 확인)도 일반 실행처럼 기계를 움직이는 중이다(검토 10/19).
                by_execution = exc.holder in _MOVING_HOLDERS
                if exc.holder == ControlArbiter.VERIFY_PASS:
                    busy = "자리 확인이 진행 중"
                elif by_execution:
                    busy = "일반 실행이 진행 중"
                else:
                    busy = "이전 세션의 정지를 정리하는 중"
                self._record("start_rejected", None, busy,
                             appliance_id=appliance_id)
                raise DevSessionConflict(
                    f"{busy}입니다 -- 잠시 후 다시 시도해 주세요",
                    code="execution_busy" if by_execution else "stopping",
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
            if self._session is None or self._deadline is None:
                return None
            if self._monotonic() < self._deadline:
                return None
            session = self._detach_session_locked()
            self._reserve_stop_locked()
        # 정지는 락 밖에서 -- 어댑터가 느려도 다른 정지·조회를 막지 않는다.
        self._send_stop("heartbeat_timeout", session, raise_on_failure=False)
        return "heartbeat_timeout"

    def end(self, session_id: str, reason: str = "session_ended") -> dict | None:
        """세션을 끝내고 정지를 보낸다. 돌려주는 값은 어댑터가 알린 정지 확인 단계(모의면 None, 2026-10-13)."""
        self.tick()
        with self._lock:
            self._require_locked(session_id)
            session = self._detach_session_locked()
            self._reserve_stop_locked()
        return self._send_stop_report(reason, session)

    def _send_stop_report(self, reason: str, session: DevSession | None) -> dict | None:
        holder: dict = {}
        self._send_stop(reason, session, raise_on_failure=True, report=holder)
        info = holder.get("info")
        return dict(info) if isinstance(info, dict) else None

    def emergency_stop(self, reason: str = "emergency_stop") -> dict | None:
        """세션이 있든 없든, 명령이 무엇이었든 **먼저** 멈춘다.

        정지가 실패하면 fault를 걸고 예외를 올린다. 정지가 성공하면 --
        그것이 곧 '기계가 멈췄다'는 확인이므로 -- 이전의 정지 미확인
        fault를 푼다. 이것이 fault의 명시적 복구 절차다.

        어댑터 안에 진행 중인 명령이 있으면 정지는 **즉시** 나가되 제어권
        반납은 그 명령의 정리로 미룬다(stopping 상태) -- 그동안 일반 실행은
        여전히 거절된다.
        """
        with self._lock:
            session = self._detach_session_locked()
            self._reserve_stop_locked()  # 세션이 없어도 정지는 나간다
        return self._send_stop_report(reason, session)

    def close(self) -> None:
        """서버 종료 정리 -- 감시 스레드를 멈추고, 열린 세션이 있으면
        정지를 보낸 뒤 닫는다. 이후 start()는 거절된다."""
        with self._lock:
            # 종료 표시는 start()의 판정과 같은 락으로 직렬화한다
            # (후속 리뷰 1.1-#3).
            self._closed = True
        self._watch_stop.set()
        thread = self._watch_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        try:
            with self._lock:
                if self._session is None:
                    return
                session = self._detach_session_locked()
                self._reserve_stop_locked()
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
                session = self._detach_session_locked()
                self._reserve_stop_locked()
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
                code="stop_unconfirmed",
            )

        try:
            command = parse_dev_command(text)
        except DevCommandRejected as exc:
            return self._reject(
                request_id, str(exc), appliance_id, code="invalid_command"
            )

        self.tick()
        with self._lock:
            session = self._session
            if session is None or session.session_id != session_id:
                return self._reject_locked(
                    request_id, "열린 개발자 세션이 아닙니다", appliance_id,
                    code="session_expired",
                )
            # 매 명령마다 대상을 다시 확인한다 -- 다른 가전을 움직이는 사고를 막는다.
            if session.appliance_id != appliance_id:
                return self._reject_locked(
                    request_id,
                    "세션의 대상 가전과 다릅니다",
                    appliance_id,
                    code="wrong_target",
                )
            if (
                command.kind is DevCommandKind.JOG
                and command.amount_mm > self.max_jog_mm
            ):
                return self._reject_locked(
                    request_id,
                    f"한 번에 {self.max_jog_mm:g}mm까지만 움직여요",
                    appliance_id,
                    code="step_too_large",
                )
            if command.kind is DevCommandKind.PRESS:
                if self._known_button is not None and not self._known_button(
                    appliance_id, command.button_id
                ):
                    return self._reject_locked(
                        request_id,
                        f"이 가전에 등록되지 않은 버튼입니다: {command.button_id}",
                        appliance_id,
                        code="unknown_button",
                    )
                if not self._is_calibrated(appliance_id):
                    return self._reject_locked(
                        request_id,
                        "버튼 위치 보정이 끝나지 않은 가전은 누를 수 없습니다",
                        appliance_id,
                        code="not_calibrated",
                    )
            epoch = self._epoch

        # 어댑터 호출은 상태 락 밖 -- 정지·heartbeat가 이 호출을 기다리지
        # 않는다. dispatch 락은 모션 호출끼리의 직렬화만 담당한다.
        # 정상 반환이든 예외든 반드시 _settle_after_dispatch를 지난다 --
        # 예외 경로가 정리(재정지·반납·잠금)를 건너뛰면 안 된다
        # (후속 리뷰 1.1-#2).
        with self._dispatch_lock:
            with self._lock:
                if self._epoch != epoch:
                    return self._reject_locked(
                        request_id,
                        "정지되어 명령을 보내지 않았습니다",
                        appliance_id,
                        code="stopped",
                    )
                self._inflight = True
            try:
                sensor = self._dispatch(command)
            except DevAdapterRefused as exc:
                return self._settle_refused(
                    request_id, appliance_id, epoch, command, exc
                )
            except Exception as exc:
                log.exception("developer command dispatch failed")
                return self._settle_after_dispatch(
                    request_id, appliance_id, epoch, command,
                    sensor=None, dispatch_failed=True,
                    failure_detail=getattr(exc, "detail", None),
                )
            return self._settle_after_dispatch(
                request_id, appliance_id, epoch, command,
                sensor=sensor, dispatch_failed=False,
            )

    # ── 내부 ──

    def _settle_refused(
        self,
        request_id: str,
        appliance_id: str,
        epoch: int,
        command: DevCommand,
        exc: DevAdapterRefused,
    ) -> DevResult:
        """어댑터가 움직이기 전에 거절했다(2026-10-10). 정지와 경합했으면 종전 경합 정리(재정지)를 지나고,
        아니면 그 코드로 거절한다 — 정지를 보내지 않고 세션을 유지한다. 출구는 언제나 _finish_settle."""
        with self._lock:
            stale = self._epoch != epoch
            if not stale:
                self._record(
                    "command_rejected", request_id,
                    f"{command.normalized()}: {exc.code}",
                    appliance_id=appliance_id,
                )
        if stale:
            return self._settle_after_dispatch(
                request_id, appliance_id, epoch, command,
                sensor=None, dispatch_failed=True,
            )
        return self._finish_settle(
            DevResult(False, request_id, normalized=command.normalized(),
                      reason=exc.message, code=exc.code)
        )

    def _settle_after_dispatch(
        self,
        request_id: str,
        appliance_id: str,
        epoch: int,
        command: DevCommand,
        *,
        sensor: dict[str, float] | None,
        dispatch_failed: bool,
        failure_detail: str | None = None,
    ) -> DevResult:
        """모든 디스패치의 단일 종착점 -- 정상 반환·예외 공통.

        여기서 정하는 것:
        - epoch가 그대로고 예외도 없었으면 성공.
        - 정지와 경합했으면(stale) 재정지로 최종 상태를 '멈춤'으로 만든다
          -- 이전 명령이 다시 동작할 수 없음을 확인한 다음에만 다음
          제어권이 나간다(반납 자체는 _maybe_release_locked가 판정).
        - 예외로 끝난 명령은 장치에 닿았는지 모른다 -- 확인 대신 정지로
          정리하고, 그 정지도 확인 못 하면 세션 폐기 + fault.
        """
        # **_inflight는 여기서 내리지 않는다.** "아직 끝나지 않은 작업"에는
        # 명령 자체뿐 아니라 그 명령의 안전 정리(복구 정지)까지 포함된다
        # (후속 리뷰 1.2). 정리가 진행 중일 때 들어온 별도 정지는 여전히
        # _inflight=True를 보고 반납을 이쪽에 위임해야 한다 -- 안 그러면
        # 정리 stop이 어댑터 안에 살아 있는 채로 제어권이 넘어간다.
        # _inflight 해제와 위임 소비는 마지막의 _finish_settle이 한다.
        with self._lock:
            stale = self._epoch != epoch
            if not stale and not dispatch_failed:
                self._record(
                    "command_accepted",
                    request_id,
                    command.normalized(),
                    appliance_id=appliance_id,
                )
        if not stale and not dispatch_failed:
            return self._finish_settle(
                DevResult(
                    True, request_id,
                    normalized=command.normalized(), sensor=sensor,
                )
            )

        if stale:
            # 명령이 정지와 경합해 정지 **뒤에** 어댑터에 닿았을 수 있다
            # (예외로 끝났어도 마찬가지 -- 전달 여부를 모른다). 어댑터의
            # 명령 흐름에서 이 stop이 그 명령보다 뒤이므로, 기계는 멈춘
            # 채로 끝난다. 재정지가 실패하면 기계 상태를 모르므로 잠근다.
            ok = self._try_stop_confirm(
                "stop_after_late_command", request_id, trip_on_failure=True
            )
            reason = (
                "정지 요청과 겹쳐 명령을 취소하고 다시 멈췄습니다"
                if ok
                else "정지 요청과 겹쳤고 재정지도 확인하지 못했습니다 -- 기기를 잠갔습니다"
            )
            return self._finish_settle(
                DevResult(
                    False, request_id, reason=reason,
                    code="stop_race" if ok else "stop_unconfirmed",
                )
            )

        # 예외로 끝났고 (판정 시점 기준) 정지 경합은 없었다.
        ok = self._try_stop_confirm(
            "command_error", request_id, trip_on_failure=False
        )
        if ok:
            # 정지가 확인됐으니 세션은 유지 -- 사용자가 다시 시도할 수 있다.
            reason = (
                "명령 전달 중 오류가 나 안전을 위해 정지를 보냈습니다 "
                "-- 다시 시도해 주세요"
            )
            if failure_detail:
                # 실물 어댑터가 밝힌 원인(알람·기한 초과 등)을 덧붙인다(2026-10-10).
                reason = f"{reason} ({failure_detail})"
            return self._finish_settle(
                DevResult(
                    False, request_id,
                    reason=reason,
                    code="command_error",
                )
            )
        # 명령 결과도, 정지도 확인하지 못했다 -- 장치 잠금. 세션 폐기는
        # **우리 세대일 때만**: 정리가 지연되는 동안 별도 정지가 이미 이
        # 세션을 닫았다면(epoch 증가) 지금의 self._session은 우리 것이
        # 아닐 수 있다 -- 남의 세션을 닫으면 안 된다(후속 리뷰 1.2).
        self._arbiter.trip_fault("stop_unconfirmed:command_error")
        closed_by_us = False
        with self._lock:
            if self._epoch == epoch and self._session is not None:
                self._close_session_locked()
                closed_by_us = True
        return self._finish_settle(
            DevResult(
                False, request_id,
                reason="명령 오류 후 정지도 확인하지 못했습니다 -- 기기를 잠갔습니다",
                code="stop_unconfirmed",
            ),
            force_release=closed_by_us,
        )

    def _finish_settle(
        self, result: DevResult, *, force_release: bool = False
    ) -> DevResult:
        """settle의 단일 출구 -- 여기서만 _inflight를 내린다.

        force_release는 settle이 자기 세션을 직접 닫은 경우다(정리 정지
        미확인 → fault). 반납 여부는 언제나 _maybe_release_locked()가
        판정한다 -- 진행 중인 별도 정지가 있으면 그쪽 완료가 반납한다.
        """
        with self._lock:
            self._inflight = False
            if force_release:
                self._release_owed = True
            self._maybe_release_locked()
        return result

    def _maybe_release_locked(self) -> bool:
        """제어권 반납의 **단일 판정점이자 실행점** (후속 리뷰 1.3·1.5).
        _lock 안 전용.

        기준은 "누가 마지막으로 끝났는가"가 아니라 "필요한 안전 조건이
        모두 충족됐는가"다:

        1. 돌려줄 빚이 있는가(_release_owed -- 세션이 닫혔다)
        2. 그 세대의 명령·안전 정리가 모두 끝났는가(_inflight)
        3. 진행 중인 정지 요청이 없는가(_stops_inflight -- "요청됨"은
           "확인됨"이 아니다)
        4. 빚이 생긴 뒤 정지가 확인됐는가 -- 아니면 fault가 신규 획득을
           차단하고 있는가

        판정·상태 갱신·중재자 반환을 **같은 임계구역에서 끝낸다**(1.5):
        판정만 하고 락을 놓은 뒤 반환하면, 그 사이에 예약된 새 정지를
        모른 채 과거 판정대로 반환한다 -- 판정 당시의 안전이 반환
        시점까지 유지된다는 보장이 없다. 중재자 락은 콜백 없는
        최내곽(leaf)이라 개발자 락 → 중재자 락 순서가 안전하다(start()의
        acquire와 같은 순서). 반환했으면 True.
        """
        if not self._release_owed:
            return False
        if self._inflight or self._stops_inflight > 0:
            return False
        if (
            not self._stop_confirmed_since_owed
            and self._arbiter.fault_reason is None
        ):
            return False
        self._release_owed = False
        self._stop_confirmed_since_owed = False
        self._arbiter.release(ControlArbiter.DEVELOPER)
        return True

    def _try_stop_confirm(
        self, reason: str, request_id: str | None, *, trip_on_failure: bool
    ) -> bool:
        """어댑터에 정지를 보내고 확인 여부만 돌려준다. 락 밖 전용.

        _send_stop과 달리 세션·제어권을 건드리지 않고, **fault도 해제하지
        않는다** -- 정리가 지연되는 사이에 다른 주체가 건 fault를 오래된
        정리의 성공이 풀어 버리면 안 된다(후속 리뷰 1.2). fault 해제는
        사용자의 긴급 정지가 확인되는 경로(_send_stop) 하나뿐이다.
        """
        with self._lock:
            self._stops_inflight += 1
        try:
            self._adapter.stop(reason)
        except Exception:
            with self._lock:
                self._stops_inflight -= 1
            if trip_on_failure:
                self._arbiter.trip_fault(f"stop_unconfirmed:{reason}")
            with self._lock:
                self._record("stop_unconfirmed", request_id, reason)
            log.exception("developer stop unconfirmed (reason=%s)", reason)
            return False
        with self._lock:
            self._stops_inflight -= 1
            self._stop_confirmed_since_owed = True
            self._record("stopped", request_id, reason)
        return True

    def _reserve_stop_locked(self) -> None:
        """전송 **예정**인 정지를 카운터에 미리 올린다. _lock 안 전용.

        세션 무효화와 같은 임계구역에서 불러야 한다 -- 무효화와 예약이
        떨어져 있으면 그 사이의 settle 완료가 "진행 중 정지 없음"으로
        판정해 제어권을 내준다(후속 리뷰 1.4-#2). 실제 전송(_send_stop)이
        완료 시점에 내린다.
        """
        self._stops_inflight += 1

    def _detach_session_locked(self) -> DevSession | None:
        """세션을 떼어내고 반납 빚을 기록한다. _lock 안 전용.

        반납 시점은 여기서 정하지 않는다 -- _send_stop·settle의 완료
        지점들이 _maybe_release_locked()로 판정한다. 세션이 닫히는 순간
        '정지 확인' 기록을 리셋한다: 이 빚에는 **이후의** 확인만 유효하다.
        """
        session = self._session
        if session is None:
            return None
        self._close_session_locked()
        self._release_owed = True
        self._stop_confirmed_since_owed = False
        return session

    def _dispatch(self, command: DevCommand) -> dict[str, float] | None:
        match command.kind:
            case DevCommandKind.JOG:
                result = self._adapter.jog(
                    command.axis,
                    command.direction,
                    command.amount_mm,
                    self._jog_ttl_s,
                )
                if isinstance(result, dict):
                    return result
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
        report: dict | None = None,
    ) -> bool:
        """어댑터에 정지를 보내고 결과를 fault/복구/반납 판정으로 옮긴다.
        락 밖 전용.

        - 성공: '기계가 멈췄다'는 확인. 이전 fault(정지 미확인)를 풀되,
          **이 정지가 시작된 뒤 새로 걸린 fault는 풀지 않는다**(fault_seq
          대조, 후속 리뷰 1.3) -- 오래 걸린 정지의 성공 응답이 그 사이
          사건을 덮으면 안 된다.
        - 실패 + 세션이 있었음(기계가 움직였을 수 있음): fault를 걸어
          새 실행·새 세션을 막는다.
        - 실패 + 움직이던 주체 없음: 잠그지 않고 실패만 기록한다(유휴
          상태의 어댑터 단절로 시스템 전체가 잠기면 안 된다).

        제어권 반납은 여기서 직접 정하지 않는다 -- 이 정지의 완료를
        _stops_inflight에 반영한 뒤 _maybe_release_locked()가 판정한다.
        응답 대기 중인 정지가 남아 있는 동안은 누구도 반납하지 못한다.

        **호출 전에 _reserve_stop_locked()로 예약돼 있어야 한다** -- 세션
        무효화와 같은 락 안에서. 등록을 여기서 하면 무효화와 등록 사이의
        빈틈에 이전 명령의 settle이 "진행 중 정지 없음"으로 판정해 아직
        전송도 안 된 정지를 모른 채 반납한다(후속 리뷰 1.4-#2).
        """
        fault_reason_at_start, fault_seq_at_start = (
            self._arbiter.fault_snapshot()
        )
        try:
            info = self._adapter.stop(reason)
            if report is not None:
                # 정지 확인 단계(2026-10-13) — 호출자(API)가 '보냄'과 '확인'을 가른다. 아래 판정은 종전과 같다:
                # 어댑터가 예외 없이 돌아오면 RPi4에 닿은 것이고, 잠금(fault)은 닿지 못했을 때만이다.
                report["info"] = info
        except Exception:
            if session is not None:
                # 반납 판정보다 fault가 먼저다 -- 둘 사이에 실행이
                # 제어권을 얻는 창을 만들지 않는다.
                self._arbiter.trip_fault(f"stop_unconfirmed:{reason}")
            with self._lock:
                self._stops_inflight -= 1
                self._record(
                    "stop_unconfirmed", request_id, reason, session=session,
                    appliance_id=session.appliance_id if session else None,
                )
                # 판정과 반환이 같은 임계구역이다(후속 리뷰 1.5).
                self._maybe_release_locked()
            if raise_on_failure:
                raise
            log.exception("developer stop unconfirmed (reason=%s)", reason)
            return False
        else:
            # 시작 시점에 본 그 세대의 fault만 푼다 -- 비교와 해제는 중재자
            # 안의 같은 락에서 원자적이다(후속 리뷰 1.4-#1). 정지 도중에
            # 걸린 새 fault는 seq가 달라 지워지지 않는다.
            if (fault_reason_at_start or "").startswith(
                "stop_unconfirmed:"
            ) and self._arbiter.clear_fault_if_matches(fault_seq_at_start):
                with self._lock:
                    self._record(
                        "fault_cleared", request_id,
                        f"정지 확인됨({reason})", session=session,
                    )
            with self._lock:
                self._stops_inflight -= 1
                self._stop_confirmed_since_owed = True
                self._record(
                    "stopped", request_id, reason, session=session,
                    appliance_id=session.appliance_id if session else None,
                )
                # 판정과 반환이 같은 임계구역이다(후속 리뷰 1.5).
                self._maybe_release_locked()
            return True

    def _ensure_watchdog(self) -> None:
        if self._watchdog_interval_s is None:
            return
        with self._lock:
            if self._closed:
                return
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
        self, request_id: str, reason: str, appliance_id: str | None,
        *, code: str,
    ) -> DevResult:
        with self._lock:
            return self._reject_locked(
                request_id, reason, appliance_id, code=code
            )

    def _reject_locked(
        self, request_id: str, reason: str, appliance_id: str | None,
        *, code: str,
    ) -> DevResult:
        self._record(
            "command_rejected", request_id, reason, appliance_id=appliance_id
        )
        return DevResult(False, request_id, reason=reason, code=code)

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
