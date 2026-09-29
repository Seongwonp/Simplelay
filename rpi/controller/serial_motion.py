"""실제 모션 MCU용 GrblClient 어댑터 뼈대 — **실물 미검증**.

하드웨어(FIT0482 ×3, JMOD-MOTOR-1 ×2, 제어 MCU 미정)가 도착하기 전에 쓴 코드다.
메모리 파이프와 가짜 MCU로만 시험했다. 실제 모터·엔코더·MCU 펌웨어와 맞춰 본 적이
없으므로 "모터가 움직인다"는 근거로 쓰지 않는다.

구조(하드웨어 기술 조사 보고서 C절 후보 구조): RPi4는 목표 위치·누름 명령·타임아웃·
상태 판정만 맡고, 엔코더 계수·PWM·위치 제어·하드 리밋은 MCU가 맡는다. 이 어댑터는
RPi4 쪽 절반이다.

전송: **줄 단위 JSON** (한 줄 = 한 메시지, UTF-8, ``\\n`` 종료)
  G-code 대신 JSON을 고른 이유
  - 이 프로젝트의 다른 링크(ESP32↔RPi5, RPi5↔RPi4)가 이미 줄 단위 JSON이다.
    파서·로그·테스트 도구를 같이 쓴다.
  - 엔코더 DC 모터 + 자체 MCU 구조라 GRBL(스테퍼용)을 그대로 쓰지 않는다
    (firmware/README.md: GRBL 설계 폐기). G-code를 흉내 내려면 누름 방식·
    모터별 카운트·오류 코드를 어차피 비표준 확장으로 넣어야 한다.
  - 요청 ``id``로 응답을 짝지어, 시간 초과로 버린 요청의 늦은 응답을 다음
    요청의 응답으로 오인하지 않는다.
  전송 계층은 `LineTransport`(``write_line``/``read_line``)로 주입한다. 시험은
  `InMemoryLinePipe`, 실기기는 `PySerialLineTransport`.

호스트 → MCU                                         MCU → 호스트(응답)
  {"id":1,"cmd":"status"}                              {"id":1,"ok":true,"state":"idle","homed":false,
                                                         "a":0,"b":0,"z":0,"alarm":null}
  {"id":2,"cmd":"home"}                                {"id":2,"ok":true}   (홈 완료 뒤)
  {"id":3,"cmd":"move","a":123,"b":-45,
   "x_mm":10.0,"y_mm":5.0}                             {"id":3,"ok":true}   (도착 뒤)
  {"id":4,"cmd":"press","mode":"depth",
   "z_counts":80,"dwell_ms":150}                       {"id":4,"ok":true}   (복귀 뒤)
  {"id":5,"cmd":"press","mode":"duration",
   "drive_ms":120,"dwell_ms":150}
  {"id":6,"cmd":"stop"}                                {"id":6,"ok":true}
  {"id":7,"cmd":"ping"}                                {"id":7,"ok":true}   (즉시, 동작 방해 없음)
  {"id":8,"cmd":"limits"}                              {"id":8,"ok":true,
                                                         "raw":{"x":false,"y":false,"z":false},
                                                         "debounced":{"x":false,"y":false,"z":false}}
  실패 응답: {"id":N,"ok":false,"error":"<코드>"}
MCU → 호스트(자발 이벤트, id 없음)
  {"event":"alarm","reason":"limit|stall|home_not_found|..."}
  {"event":"press_start"} / {"event":"press_end"}  (원시 기록기 시각축용)
  {"event":"position","a":..,"b":..,"z":..}          (선택, 2026-09-30)

heartbeat(2026-09-30): home·move·press 응답을 기다리는 동안 ``heartbeat_ms``(기본 500ms)마다
``ping``을 따로 보낸다. MCU 워치독은 "받은 줄" 아무것으로나 갱신되므로 긴 원점 복귀 중에도
워치독을 초 단위로 줄일 수 있다(firmware-motion HOST_WATCHDOG_MS). ``ping``도 자기 ``id``를
받으므로 그 응답이 명령 응답으로 오인되지 않는다(아래 id 대조에서 걸러진다).

리밋 조회(2026-09-30): ``limits``는 X·Y·Z 원점/리밋 입력의 즉시 판독(``raw``, 활성=true)과
디바운스 값(``debounced``)을 돌려준다. 움직이지 않으며 첫날 배선 확인용이다.

위치 보고(선택, 2026-09-30): 응답(``ok:true``)이나 이벤트에 정수 ``a``·``b``(엔코더
카운트, ``z`` 선택)가 실려 오면 `SerialMotionClient.last_position`에 남긴다. 기구 값이
있으면 `motor_counts_to_xy`로 mm도 계산한다. MCU가 보내지 않으면 None — 지어내지 않는다.
RPi4 ActExecutor가 이 값을 progress 프레임의 ``position``으로 RPi5에 보낸다(실모드 트윈).

모든 하드웨어 값(풀리·벨트·R_out·리밋·방향·누름 깊이/시간·타임아웃)은 설정으로만
받는다. 기본값은 None이고, 필요한 값이 비어 있으면 **움직이기 전에** 거절한다.
"""

from __future__ import annotations

import json
import logging
import math
import os
import queue
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Protocol

from .kinematics import CoreXYConfig, check_soft_limits, motor_counts_to_xy, xy_to_motor_counts
from .models import Correction, ExecutionMode, PressCommand
from .ports import GrblClient, SafetyController

log = logging.getLogger(__name__)

PROTOCOL_NOTE = "line-json/v0 (실물 미검증)"


# ── 오류 ─────────────────────────────────────────────────────────────────────


class MotionError(RuntimeError):
    """모션 어댑터 오류의 공통 부모. 폐루프는 이것을 누름 실패로 센다."""


class MotionConfigError(MotionError):
    """필요한 모션 설정이 비어 있다. 채워지기 전에는 움직이지 않는다."""

    def __init__(self, operation: str, missing: tuple[str, ...]) -> None:
        self.operation = operation
        self.missing = missing
        env = ", ".join(MOTION_ENV_NAMES.get(name, name) for name in missing)
        super().__init__(
            f"{operation}: 모션 설정이 비어 있어 거절합니다 — 미설정 {', '.join(missing)} "
            f"(환경 변수 {env})"
        )


class MotionRefused(MotionError):
    """지금 상태로는 명령을 받을 수 없다(홈 전, 좌표 없음, 정지 뒤 등)."""


class MotionTimeout(MotionError):
    """MCU가 기한 안에 응답하지 않았다. 위치를 믿을 수 없어 재홈 전까지 준비 안 됨."""


class MotionStopped(MotionError):
    """정지 요청으로 동작이 중단됐다. 폐루프는 재시도하지 않고 멈춘다."""


class MotionAlarm(MotionError):
    """MCU가 오류·알람을 보고했다(리밋·스톨·원점 미검출 등)."""


# ── 전송 ─────────────────────────────────────────────────────────────────────


class LineTransport(Protocol):
    """줄 단위 전송 경계. 실기기 시리얼이든 메모리 파이프든 이 둘만 맞춘다."""

    def write_line(self, line: str) -> None:
        """개행 없이 한 줄을 보낸다(구현이 ``\\n``을 붙인다)."""

    def read_line(self, timeout_s: float) -> str | None:
        """한 줄을 읽는다. ``timeout_s`` 안에 없으면 None."""


class _QueueEnd:
    def __init__(self, inbox: "queue.Queue[str]", outbox: "queue.Queue[str]") -> None:
        self._inbox = inbox
        self._outbox = outbox

    def write_line(self, line: str) -> None:
        self._outbox.put(line)

    def read_line(self, timeout_s: float) -> str | None:
        try:
            return self._inbox.get(timeout=max(timeout_s, 0.0))
        except queue.Empty:
            return None


class InMemoryLinePipe:
    """메모리 양방향 파이프. ``host``는 어댑터가, ``device``는 가짜 MCU가 쓴다."""

    def __init__(self) -> None:
        to_device: "queue.Queue[str]" = queue.Queue()
        to_host: "queue.Queue[str]" = queue.Queue()
        self.host = _QueueEnd(inbox=to_host, outbox=to_device)
        self.device = _QueueEnd(inbox=to_device, outbox=to_host)


class PySerialLineTransport:
    """pyserial 기반 실기기 전송 — **실물 미검증**. pyserial은 ``.[gpio]`` extra에 있다."""

    def __init__(self, port: str, baud: int) -> None:
        try:
            import serial  # type: ignore[import-untyped]  # noqa: PLC0415
        except ImportError as exc:
            raise RuntimeError(
                "pyserial is not installed. Run: pip install -e \".[gpio]\""
            ) from exc
        self._serial = serial.Serial(port, baud, timeout=0)
        self._buffer = bytearray()
        self._write_lock = threading.Lock()

    def write_line(self, line: str) -> None:
        with self._write_lock:
            self._serial.write((line + "\n").encode("utf-8"))
            self._serial.flush()

    def read_line(self, timeout_s: float) -> str | None:
        deadline = time.monotonic() + max(timeout_s, 0.0)
        while True:
            newline = self._buffer.find(b"\n")
            if newline >= 0:
                raw = bytes(self._buffer[:newline])
                del self._buffer[: newline + 1]
                return raw.decode("utf-8", errors="replace").strip()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self._serial.timeout = remaining
            chunk = self._serial.read(max(1, self._serial.in_waiting))
            if chunk:
                self._buffer.extend(chunk)


# ── 설정 ─────────────────────────────────────────────────────────────────────

PRESS_MODES = ("depth", "duration")

MOTION_ENV_NAMES: dict[str, str] = {
    "press_mode": "SIMPLELAY_MOTION_PRESS_MODE",
    "press_depth_counts": "SIMPLELAY_MOTION_PRESS_DEPTH_COUNTS",
    "press_depth_step_counts": "SIMPLELAY_MOTION_PRESS_DEPTH_STEP_COUNTS",
    "press_depth_max_counts": "SIMPLELAY_MOTION_PRESS_DEPTH_MAX_COUNTS",
    "press_drive_ms": "SIMPLELAY_MOTION_PRESS_DRIVE_MS",
    "press_drive_step_ms": "SIMPLELAY_MOTION_PRESS_DRIVE_STEP_MS",
    "press_drive_max_ms": "SIMPLELAY_MOTION_PRESS_DRIVE_MAX_MS",
    "press_dwell_ms": "SIMPLELAY_MOTION_PRESS_DWELL_MS",
    "retry_xy_offsets_mm": "SIMPLELAY_MOTION_RETRY_XY_OFFSETS_MM",
    "status_timeout_s": "SIMPLELAY_MOTION_STATUS_TIMEOUT_S",
    "home_timeout_s": "SIMPLELAY_MOTION_HOME_TIMEOUT_S",
    "move_timeout_s": "SIMPLELAY_MOTION_MOVE_TIMEOUT_S",
    "press_timeout_s": "SIMPLELAY_MOTION_PRESS_TIMEOUT_S",
    "auto_home": "SIMPLELAY_MOTION_AUTO_HOME",
    "heartbeat_ms": "SIMPLELAY_MOTION_HEARTBEAT_MS",
}

#: 응답을 기다리는 동안 heartbeat(ping)를 보내는 명령 — MCU 워치독이 도는 동작들.
HEARTBEAT_CMDS = frozenset({"home", "move", "press"})

_INT_FIELDS = (
    "press_depth_counts",
    "press_depth_step_counts",
    "press_depth_max_counts",
    "press_drive_ms",
    "press_drive_step_ms",
    "press_drive_max_ms",
    "press_dwell_ms",
    "heartbeat_ms",
)
_TIMEOUT_FIELDS = ("status_timeout_s", "home_timeout_s", "move_timeout_s", "press_timeout_s")


@dataclass(frozen=True)
class MotionConfig:
    """모션 어댑터 설정. **기구·타이밍 값은 전부 기본 None**(실측·제작자 제공 전)."""

    kinematics: CoreXYConfig = field(default_factory=CoreXYConfig)
    #: "depth"(Z 엔코더 카운트 목표까지) | "duration"(Z를 정해진 시간 구동) | None(미정).
    #: Z 변환 기구가 미정이라 mm가 아니라 Z 카운트·시간으로만 받는다(보고서 D절).
    press_mode: str | None = None
    press_depth_counts: int | None = None
    #: 재시도에서 깊이를 늘릴 때 한 번의 증가량, 그리고 절대 상한.
    press_depth_step_counts: int | None = None
    press_depth_max_counts: int | None = None
    press_drive_ms: int | None = None
    press_drive_step_ms: int | None = None
    press_drive_max_ms: int | None = None
    #: 누른 채 유지하는 시간. 버튼맵 ``press_ms``가 있으면 그것이 우선한다.
    press_dwell_ms: int | None = None
    #: 재시도 n회차의 XY 보정 오프셋(mm), n=1부터 순서대로. 방향·폭은 기구를 아는
    #: 사람이 정한다 — 여기서 만들어내지 않는다. 비어 있으면 보정 재시도를 거절한다.
    retry_xy_offsets_mm: tuple[tuple[float, float], ...] | None = None
    #: 명령별 응답 기한(초). 정지 지연·이동 시간 실측 뒤 정한다.
    status_timeout_s: float | None = None
    home_timeout_s: float | None = None
    move_timeout_s: float | None = None
    press_timeout_s: float | None = None
    #: 홈 전에 누름 요청이 오면 자동으로 홈을 돌릴지. 기본 False(거절).
    auto_home: bool = False
    #: home·move·press 응답을 기다리는 동안 ping을 보내는 간격(ms). None이면 보내지 않는다
    #: (환경 변수 0/off). 기구 실측값이 아니라 호스트 박자라 기본값을 둔다 — MCU 워치독
    #: (firmware-motion HOST_WATCHDOG_MS)은 이 값의 3배 이상이어야 한다.
    heartbeat_ms: int | None = 500

    def __post_init__(self) -> None:
        if self.press_mode is not None and self.press_mode not in PRESS_MODES:
            raise ValueError(f"press_mode는 {PRESS_MODES} 중 하나여야 합니다: {self.press_mode!r}")
        for name in _INT_FIELDS:
            value = getattr(self, name)
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, int) or value <= 0
            ):
                raise ValueError(f"{name}는 1 이상의 정수여야 합니다: {value!r}")
        for name in _TIMEOUT_FIELDS:
            value = getattr(self, name)
            if value is not None and not (
                isinstance(value, (int, float)) and math.isfinite(value) and value > 0
            ):
                raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")
        if self.retry_xy_offsets_mm is not None:
            for i, pair in enumerate(self.retry_xy_offsets_mm):
                if len(pair) != 2 or not all(
                    isinstance(v, (int, float)) and math.isfinite(v) for v in pair
                ):
                    raise ValueError(f"retry_xy_offsets_mm[{i}]는 (dx, dy) 유한한 수 쌍이어야 합니다")

    def require(self, operation: str, names: tuple[str, ...]) -> None:
        missing = tuple(name for name in names if getattr(self, name) is None)
        if missing:
            raise MotionConfigError(operation, missing)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "MotionConfig":
        source = os.environ if env is None else env
        values: dict[str, Any] = {"kinematics": CoreXYConfig.from_env(source)}
        for name, env_name in MOTION_ENV_NAMES.items():
            raw = source.get(env_name, "").strip()
            if not raw:
                continue
            try:
                if name == "press_mode":
                    values[name] = raw.lower()
                elif name == "auto_home":
                    values[name] = raw.lower() == "true"
                elif name == "heartbeat_ms" and raw.lower() in ("0", "off", "none"):
                    values[name] = None
                elif name in _INT_FIELDS:
                    values[name] = int(raw)
                elif name == "retry_xy_offsets_mm":
                    values[name] = _parse_offsets(raw)
                else:
                    values[name] = float(raw)
            except ValueError as exc:
                raise ValueError(f"{env_name} 값을 읽을 수 없습니다: {raw!r} ({exc})") from exc
        return cls(**values)

    def missing_for_press(self) -> tuple[str, ...]:
        """첫 누름(보정 없음)에 필요한데 비어 있는 모든 설정 — 시작 로그용."""
        missing = list(self.kinematics.missing_for_motion())
        base = ["press_mode", "press_dwell_ms", "move_timeout_s", "press_timeout_s"]
        if self.press_mode == "depth":
            base.append("press_depth_counts")
        elif self.press_mode == "duration":
            base.append("press_drive_ms")
        missing.extend(name for name in base if getattr(self, name) is None)
        return tuple(missing)


def _parse_offsets(raw: str) -> tuple[tuple[float, float], ...]:
    """"dx,dy;dx,dy" → ((dx, dy), (dx, dy))."""
    pairs = []
    for chunk in raw.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = [p.strip() for p in chunk.split(",")]
        if len(parts) != 2:
            raise ValueError(f"'{chunk}'는 dx,dy 형식이 아닙니다")
        pairs.append((float(parts[0]), float(parts[1])))
    return tuple(pairs)


# ── 상태 ─────────────────────────────────────────────────────────────────────


class MotionState(str, Enum):
    UNKNOWN = "unknown"  # 연결 확인 전
    UNHOMED = "unhomed"  # 위치 기준 없음 — 이동·누름 거절
    READY = "ready"
    BUSY = "busy"
    STOPPED = "stopped"  # 정지로 중단 — 위치를 믿을 수 없어 재홈 필요
    ALARM = "alarm"


@dataclass(frozen=True)
class LimitStatus:
    """리밋 입력 판독. 값은 "활성(눌림·단선)이면 True" — 핀 레벨은 MCU 설정(LIMIT_ACTIVE_LEVEL)."""

    raw: dict[str, bool | None]
    debounced: dict[str, bool | None]


LIMIT_INPUTS = ("x", "y", "z")


@dataclass(frozen=True)
class MotionStatus:
    state: str
    homed: bool
    a_counts: int | None
    b_counts: int | None
    z_counts: int | None
    alarm: str | None


EventHook = Callable[[str, dict], None]


class SerialMotionClient(GrblClient):
    """줄 단위 JSON으로 모션 MCU와 대화하는 GrblClient — **실물 미검증**."""

    #: 실제 액추에이터를 움직이라고 명령하는 어댑터다(F4). 명령이 물리적으로
    #: 성공했는지는 별개이며 이 코드는 실기기로 검증되지 않았다.
    execution_mode = ExecutionMode.REAL
    #: 좌표 없는 누름은 받지 않는다 — ClosedLoopController가 실행 전에 거른다.
    requires_coordinates = True

    def __init__(
        self,
        transport: LineTransport,
        config: MotionConfig,
        *,
        on_event: EventHook | None = None,
        clock: Callable[[], float] = time.monotonic,
        poll_s: float = 0.05,
    ) -> None:
        self._transport = transport
        self._config = config
        self._on_event = on_event
        self._clock = clock
        self._poll_s = poll_s
        self._state = MotionState.UNKNOWN
        self._state_lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._op_lock = threading.Lock()  # 응답을 읽는 쪽은 한 번에 하나
        self._stop = threading.Event()
        self._next_id = 0
        self.last_status: MotionStatus | None = None
        self._last_position: dict | None = None
        #: 보낸 heartbeat(ping) 수 — 시험·로그용.
        self.heartbeats_sent = 0

    @property
    def last_position(self) -> dict | None:
        """MCU가 마지막으로 보고한 엔코더 위치(없으면 None). 사본을 돌려준다."""
        with self._state_lock:
            return dict(self._last_position) if self._last_position is not None else None

    def _note_position(self, doc: dict, source: str) -> None:
        a, b = _opt_int(doc.get("a")), _opt_int(doc.get("b"))
        if a is None or b is None:
            return
        position: dict[str, Any] = {
            "a_counts": a, "b_counts": b, "z_counts": _opt_int(doc.get("z")),
            "x_mm": None, "y_mm": None, "source": source,
            "t_monotonic_ns": time.monotonic_ns(),
        }
        try:
            x, y = motor_counts_to_xy(a, b, self._config.kinematics)
            position["x_mm"], position["y_mm"] = round(x, 3), round(y, 3)
        except Exception:  # noqa: BLE001 - 기구 값 미설정이면 카운트만 남긴다
            pass
        with self._state_lock:
            self._last_position = position

    # ── 상태 조회 ──────────────────────────────────────────────────────────────

    @property
    def state(self) -> MotionState:
        with self._state_lock:
            return self._state

    @property
    def homed(self) -> bool:
        return self.state is MotionState.READY

    @property
    def config(self) -> MotionConfig:
        return self._config

    def _set_state(self, state: MotionState) -> None:
        with self._state_lock:
            self._state = state

    # ── 명령 ─────────────────────────────────────────────────────────────────

    def connect(self) -> MotionStatus:
        """시작 시 상태 조회. MCU가 알람이면 준비 안 됨, 홈 완료를 보고해야만 READY."""
        return self.status()

    def status(self) -> MotionStatus:
        self._config.require("상태 조회", ("status_timeout_s",))
        with self._op_lock:
            reply = self._request({"cmd": "status"}, self._config.status_timeout_s, allow_when_stopped=True)
        status = MotionStatus(
            state=str(reply.get("state", "unknown")),
            homed=reply.get("homed") is True,
            a_counts=_opt_int(reply.get("a")),
            b_counts=_opt_int(reply.get("b")),
            z_counts=_opt_int(reply.get("z")),
            alarm=reply.get("alarm") if isinstance(reply.get("alarm"), str) else None,
        )
        self.last_status = status
        if status.alarm or status.state == "alarm":
            self._set_state(MotionState.ALARM)
        elif self.state is not MotionState.STOPPED:
            # 정지로 끊긴 뒤에는 MCU가 homed라고 해도 재홈 전까지 믿지 않는다.
            self._set_state(MotionState.READY if status.homed else MotionState.UNHOMED)
        return status

    def limits(self) -> LimitStatus:
        """리밋 입력 판독(움직이지 않음). 첫날 배선 확인용 — 어댑터 상태를 바꾸지 않는다."""
        self._config.require("리밋 조회", ("status_timeout_s",))
        with self._op_lock:
            reply = self._request({"cmd": "limits"}, self._config.status_timeout_s, allow_when_stopped=True)
        return LimitStatus(raw=_limit_map(reply.get("raw")), debounced=_limit_map(reply.get("debounced")))

    def home(self) -> None:
        """원점 복귀. 절차(저속 접근·후퇴·재접근)는 MCU가 수행한다(보고서 C절)."""
        self._config.require("원점 복귀", ("home_timeout_s",))
        self._refuse_if_stopped("원점 복귀")
        with self._op_lock:
            self._set_state(MotionState.BUSY)
            try:
                self._request({"cmd": "home"}, self._config.home_timeout_s)
            except BaseException:
                if self.state is MotionState.BUSY:
                    self._set_state(MotionState.UNHOMED)
                raise
            self._set_state(MotionState.READY)

    def move_to(self, x_mm: float, y_mm: float) -> None:
        """절대 좌표(mm)로 이동. 소프트 리밋·기구 값·홈 확인을 **보내기 전에** 한다."""
        request = self._move_request(x_mm, y_mm)
        self._config.require("XY 이동", ("move_timeout_s",))
        self._refuse_if_stopped("XY 이동")
        self._require_homed("XY 이동")
        with self._op_lock:
            self._run_busy(request, self._config.move_timeout_s)

    def press(self, command: PressCommand) -> None:
        """좌표로 이동 → Z 누름 → 복귀. 검증 가능한 것은 전부 움직이기 전에 확인한다."""
        self._refuse_if_stopped(f"'{command.button}' 누름")
        if not command.has_coordinates:
            raise MotionRefused(
                f"'{command.button}'에 좌표(x_mm, y_mm)가 없어 누르지 않습니다 — 보정 먼저"
            )
        dx, dy = self._retry_offset(command.correction)
        x, y = command.x_mm + dx, command.y_mm + dy  # type: ignore[operator]
        move = self._move_request(x, y)
        press = self._press_request(command)
        self._config.require("누름", ("move_timeout_s", "press_timeout_s"))

        if not self.homed:
            if self._config.auto_home and self.state in (MotionState.UNHOMED, MotionState.UNKNOWN):
                self.home()
            else:
                self._require_homed(f"'{command.button}' 누름")

        with self._op_lock:
            self._run_busy(move, self._config.move_timeout_s)
            self._emit("press_command", {"button": command.button})
            self._run_busy(press, self._config.press_timeout_s)
            self._emit("press_done", {"button": command.button})

    def request_stop(self) -> None:
        """다른 스레드에서 즉시 정지 명령을 보낸다. 진행 중 명령의 반환을 기다리지 않는다.

        보낸 것은 '명령 전송'까지다. MCU의 정지 보고와 물리 정지(엔코더 속도 0)는
        별도 단계이며 실물로 재야 한다(docs/하드웨어-연결-설계.md §2·§5).
        """
        self._stop.set()
        try:
            with self._write_lock:
                self._next_id += 1
                self._transport.write_line(json.dumps({"id": self._next_id, "cmd": "stop"}))
        except Exception:  # noqa: BLE001 - 정지 경로에서 호출자를 죽이지 않는다
            log.exception("motion stop send failed — physical E-STOP is the final authority")
        if self.state is MotionState.BUSY:
            self._set_state(MotionState.STOPPED)

    def reset_stop(self) -> None:
        """다음 실행을 위해 정지 요청 표시를 지운다. STOPPED 상태(재홈 필요)는 남는다."""
        self._stop.clear()

    # ── 내부 ─────────────────────────────────────────────────────────────────

    def _move_request(self, x_mm: float, y_mm: float) -> dict:
        kin = self._config.kinematics
        check_soft_limits(x_mm, y_mm, kin)
        counts = xy_to_motor_counts(x_mm, y_mm, kin)
        return {
            "cmd": "move",
            "a": int(round(counts.a)),
            "b": int(round(counts.b)),
            "x_mm": x_mm,
            "y_mm": y_mm,
        }

    def _press_request(self, command: PressCommand) -> dict:
        cfg = self._config
        cfg.require("누름", ("press_mode",))
        dwell = command.press_ms if command.press_ms is not None else cfg.press_dwell_ms
        if dwell is None:
            raise MotionConfigError("누름 유지 시간", ("press_dwell_ms",))
        retry = command.correction.retry_number if command.correction else 0
        deeper = bool(command.correction and command.correction.increase_press_depth)
        if cfg.press_mode == "depth":
            base, step, cap = "press_depth_counts", "press_depth_step_counts", "press_depth_max_counts"
            key = "z_counts"
        else:
            base, step, cap = "press_drive_ms", "press_drive_step_ms", "press_drive_max_ms"
            key = "drive_ms"
        cfg.require("누름", (base,))
        amount = getattr(cfg, base)
        if deeper:
            cfg.require("누름 강화 재시도", (step, cap))
            amount = amount + getattr(cfg, step) * retry
            if amount > getattr(cfg, cap):
                raise MotionRefused(
                    f"재시도 {retry}회차 누름 {key}={amount}가 상한 {getattr(cfg, cap)}을 넘어 거절합니다"
                )
        elif getattr(cfg, cap) is not None and amount > getattr(cfg, cap):
            raise MotionRefused(f"누름 {key}={amount}가 상한 {getattr(cfg, cap)}을 넘어 거절합니다")
        return {"cmd": "press", "mode": cfg.press_mode, key: amount, "dwell_ms": dwell}

    def _retry_offset(self, correction: Correction | None) -> tuple[float, float]:
        if correction is None or not correction.xy_adjustment_required:
            return 0.0, 0.0
        offsets = self._config.retry_xy_offsets_mm
        if offsets is None:
            raise MotionConfigError("XY 보정 재시도", ("retry_xy_offsets_mm",))
        index = correction.retry_number - 1
        if not 0 <= index < len(offsets):
            raise MotionRefused(
                f"재시도 {correction.retry_number}회차 XY 보정 오프셋이 설정에 없습니다"
            )
        return offsets[index]

    def _refuse_if_stopped(self, operation: str) -> None:
        if self._stop.is_set():
            raise MotionStopped(f"{operation}: 정지 요청 중이라 거절합니다")

    def _require_homed(self, operation: str) -> None:
        if not self.homed:
            raise MotionRefused(
                f"{operation}: 원점 복귀가 확인되지 않았습니다(상태 {self.state.value}) — 홈 먼저"
            )

    def _run_busy(self, request: dict, timeout_s: float | None) -> dict:
        self._set_state(MotionState.BUSY)
        try:
            reply = self._request(request, timeout_s)
        except MotionStopped:
            self._set_state(MotionState.STOPPED)
            raise
        except MotionAlarm:
            self._set_state(MotionState.ALARM)
            raise
        except BaseException:
            # 기한 초과·프로토콜 오류: 어디서 멈췄는지 모른다 → 재홈 전까지 준비 안 됨
            if self.state is MotionState.BUSY:
                self._set_state(MotionState.UNHOMED)
            raise
        self._set_state(MotionState.READY)
        return reply

    def _request(
        self, body: dict, timeout_s: float | None, *, allow_when_stopped: bool = False
    ) -> dict:
        assert timeout_s is not None  # require()가 먼저 거른다
        with self._write_lock:
            self._next_id += 1
            request_id = self._next_id
            self._transport.write_line(json.dumps({"id": request_id, **body}, ensure_ascii=False))
        deadline = self._clock() + timeout_s
        beat_s = self._heartbeat_s(body["cmd"])
        next_beat = self._clock() + beat_s if beat_s is not None else None
        while True:
            if self._stop.is_set() and not allow_when_stopped:
                raise MotionStopped(f"'{body['cmd']}' 도중 정지 요청으로 중단됨")
            now = self._clock()
            remaining = deadline - now
            if remaining <= 0:
                self._send_stop_after_timeout(body["cmd"])
                raise MotionTimeout(f"'{body['cmd']}' 응답이 {timeout_s:g}s 안에 오지 않았습니다")
            wait = min(self._poll_s, remaining)
            if next_beat is not None and beat_s is not None:
                if now >= next_beat:
                    self._send_heartbeat()
                    next_beat = now + beat_s
                wait = max(0.0, min(wait, next_beat - now))
            line = self._transport.read_line(wait)
            if line is None:
                continue
            doc = _parse_line(line)
            if doc is None:
                log.warning("motion: ignored unparsable line: %.120s", line)
                continue
            if "event" in doc:
                self._note_position(doc, "mcu_event")
                self._handle_event(doc)
                continue
            if doc.get("id") != request_id:
                continue  # 시간 초과로 버린 요청의 늦은 응답·정지 응답·heartbeat(ping) 응답
            if doc.get("ok") is True:
                self._note_position(doc, "mcu_reply")
                return doc
            error = doc.get("error") if isinstance(doc.get("error"), str) else "unknown"
            raise MotionAlarm(f"MCU가 '{body['cmd']}'를 거절/실패 보고: {error}")

    def _heartbeat_s(self, cmd: str) -> float | None:
        interval = self._config.heartbeat_ms
        if cmd not in HEARTBEAT_CMDS or interval is None:
            return None
        return interval / 1000.0

    def _send_heartbeat(self) -> None:
        """ping 한 줄. 자기 id를 받으므로 응답은 진행 중 명령의 응답과 섞이지 않는다."""
        with self._write_lock:
            self._next_id += 1
            self._transport.write_line(json.dumps({"id": self._next_id, "cmd": "ping"}))
        self.heartbeats_sent += 1

    def _handle_event(self, doc: dict) -> None:
        name = str(doc.get("event"))
        self._emit(name, doc)
        if name == "alarm":
            reason = doc.get("reason") if isinstance(doc.get("reason"), str) else "unknown"
            self._set_state(MotionState.ALARM)
            raise MotionAlarm(f"MCU 알람: {reason}")

    def _send_stop_after_timeout(self, cmd: str) -> None:
        log.error("motion '%s' timed out — sending stop", cmd)
        try:
            with self._write_lock:
                self._next_id += 1
                self._transport.write_line(json.dumps({"id": self._next_id, "cmd": "stop"}))
        except Exception:  # noqa: BLE001
            log.exception("motion stop after timeout failed")

    def _emit(self, name: str, fields: dict) -> None:
        if self._on_event is None:
            return
        try:
            self._on_event(name, dict(fields))
        except Exception:  # noqa: BLE001 - 기록 훅 고장이 모션을 막지 않는다
            log.exception("motion event hook failed")


class MotionSafetyController(SafetyController):
    """폐루프의 안전 정지를 모션 MCU 정지 명령으로 전달한다. 물리 E-STOP이 최종 권한이다."""

    def __init__(self, client: SerialMotionClient) -> None:
        self._client = client
        self.reasons: list[str] = []

    def stop(self, reason: str) -> None:
        self.reasons.append(reason)
        log.warning("motion safety stop: %s", reason)
        self._client.request_stop()


def _parse_line(line: str) -> dict | None:
    try:
        doc = json.loads(line)
    except json.JSONDecodeError:
        return None
    return doc if isinstance(doc, dict) else None


def _limit_map(value: object) -> dict[str, bool | None]:
    source = value if isinstance(value, dict) else {}
    return {name: source.get(name) if isinstance(source.get(name), bool) else None for name in LIMIT_INPUTS}


def _opt_int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value
