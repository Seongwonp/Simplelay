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
  {"event":"ready","fw":"firmware-motion","protocol":"line-json/v0","reset":"poweron"}  (부팅 때 한 번)
  {"event":"alarm","reason":"limit|stall|home_not_found|...","z_retract":"done|..."}
  {"event":"press_start"} / {"event":"press_end"}  (원시 기록기 시각축용)
  {"event":"position","a":..,"b":..,"z":..}          (선택, 2026-09-29)

heartbeat(2026-09-29): home·move·press 응답을 기다리는 동안 ``heartbeat_ms``(기본 500ms)마다
``ping``을 따로 보낸다. MCU 워치독은 "받은 줄" 아무것으로나 갱신되므로 긴 원점 복귀 중에도
워치독을 초 단위로 줄일 수 있다(firmware-motion HOST_WATCHDOG_MS). ``ping``도 자기 ``id``를
받으므로 그 응답이 명령 응답으로 오인되지 않는다(아래 id 대조에서 걸러진다).

리밋 조회(2026-09-29): ``limits``는 X·Y·Z 원점/리밋 입력의 즉시 판독(``raw``, 활성=true)과
디바운스 값(``debounced``)을 돌려준다. 움직이지 않으며 첫날 배선 확인용이다.

위치 보고(선택, 2026-09-29): 응답(``ok:true``)이나 이벤트에 정수 ``a``·``b``(엔코더
카운트, ``z`` 선택)가 실려 오면 `SerialMotionClient.last_position`에 남긴다. 기구 값이
있으면 `motor_counts_to_xy`로 mm도 계산한다. MCU가 보내지 않으면 None — 지어내지 않는다.
RPi4 ActExecutor가 이 값을 progress 프레임의 ``position``으로 RPi5에 보낸다(실모드 트윈).

부팅 배너·연결(2026-09-29 첫날 위험 보완): FireBeetle ESP32는 USB 시리얼의 DTR/RTS로 자동 리셋된다.
`PySerialLineTransport`는 DTR/RTS를 **열기 전에** 내려 두고(dsrdtr·rtscts 끔) 연다. 그래도 리셋될 수 있으므로
(리눅스는 열 때 커널이 DTR을 잠깐 올린다) `SerialMotionClient.connect()`는 부트 로그(JSON 아닌 줄)를 버리고,
펌웨어의 한 줄 배너 ``{"event":"ready","fw":..,"protocol":..,"reset":..}``를 기다리거나 ``status``를 backoff로
``connect_timeout_s``(기본 5 s)까지 재시도한다. 동작 중에 ``ready``가 오면 MCU가 재시작한 것 — 진행 중 명령을
실패(`MotionReset`)로 끝내고 재홈 전까지 준비 안 됨으로 둔다. 조회 중이면 같은 요청을 새 id로 다시 보낸다.

Z 누름 방식(2026-10-05): Z가 엔코더 모터(``motor``)인지 솔레노이드(``solenoid``)인지 MCU가 ``ready``
배너와 ``status`` 응답의 ``z_mode``로 알린다(`SerialMotionClient.z_mode`, 안 보내는 MCU면 None).
솔레노이드는 깊이를 모르므로 ``press_mode=depth``를 **움직이기 전에** 거절한다. MCU의 ``z_unsupported``·
``z_cooldown``(코일 냉각 시간 안) 거절은 위치를 잃지 않은 거절이라 `MotionRefused`로 올리고 재홈을 요구하지 않는다.
2026-10-05 리뷰 L6: MCU가 ``z_on_max_ms``(솔레노이드 한 번 켜짐 상한)를 알리면 구동+유지가 그것을 넘는 누름을
**보내기 전에** 거절한다. 누름이 ``z_cooldown``으로 거절되면 MCU가 알린 남은 시간(``retry_ms``, 없으면
``z_cooldown_backoff_ms``·기본 0.5 s)만큼 기다렸다가 **한 번** 다시 누른다 — 기다림은 `Z_COOLDOWN_WAIT_MAX_S`로
묶고, 남은 시간이 그보다 길면 기다리지 않고 거절한다. 알람 이벤트 없이 온 ``soft_limit`` 응답은 MCU가 움직이기
전에 범위를 거절한 것이라(펌웨어는 움직이다 넘으면 alarm 이벤트를 먼저 보낸다) `MotionRefused`로 올린다.

위치 일치 검사(2026-10-05, 선택): ``position_tolerance_counts``를 주면 이동(``move``)이 ``ok``로 끝난 뒤
그 요청 동안 받은 엔코더 위치 보고(``position`` 이벤트·응답의 ``a``·``b``)를 명령 카운트와 비교해, 어느 모터든
허용 오차를 넘거나 보고가 없으면 `MotionPositionMismatch`로 실패시키고 재홈 전까지 준비 안 됨으로 둔다 —
엉뚱한 곳을 누르는 대신 L1 재시도(``auto_home``이면 재홈부터)로 넘긴다. **한계:** FIT0482 엔코더는 모터 축에
있어 풀리–벨트 미끄럼은 엔코더에 보이지 않는다. 이 검사가 잡는 것은 MCU가 목표에 못 닿고도 ``ok``를 보낸
경우(팀원 펌웨어의 시간 기반 이동 등)다. 벨트 미끄럼 자체는 원점 복귀(리밋)와 L3 검증으로 잡는다.
허용 오차는 측정 필요.

모든 하드웨어 값(풀리·벨트·R_out·리밋·방향·누름 깊이/시간·타임아웃)은 설정으로만
받는다. 기본값은 None이고, 필요한 값이 비어 있으면 **움직이기 전에** 거절한다.
"""

from __future__ import annotations

import contextlib
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
    """지금 상태로는 명령을 받을 수 없다(홈 전, 좌표 없음, 정지 뒤 등).

    MCU가 거절했으면 ``code``(z_cooldown·soft_limit 등)와, 알렸다면 ``retry_ms``(냉각 남은 시간)를 싣는다."""

    def __init__(self, message: str, *, code: str | None = None, retry_ms: int | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.retry_ms = retry_ms


class MotionTimeout(MotionError):
    """MCU가 기한 안에 응답하지 않았다. 위치를 믿을 수 없어 재홈 전까지 준비 안 됨."""


class MotionStopped(MotionError):
    """정지 요청으로 동작이 중단됐다. 폐루프는 재시도하지 않고 멈춘다."""


class MotionAlarm(MotionError):
    """MCU가 오류·알람을 보고했다(리밋·스톨·원점 미검출 등)."""


class MotionReset(MotionAlarm):
    """동작 중 MCU가 재시작했다(``ready`` 배너). 진행 중 명령은 사라졌고 원점 기준도 없다."""


class MotionPositionMismatch(MotionError):
    """이동은 ``ok``였지만 MCU가 보고한 엔코더 위치가 명령과 허용 오차 넘게 다르다(또는 보고 없음).

    어디 있는지 믿을 수 없어 재홈 전까지 준비 안 됨으로 둔다. 폐루프는 누름 실패로 센다.
    """


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
    """pyserial 기반 실기기 전송 — **실물 미검증**. pyserial은 ``.[gpio]`` extra에 있다.

    포트를 열 때 ESP32 자동 리셋(DTR/RTS)을 피하려고 ``serial.Serial()``을 인자 없이 만든 뒤
    흐름 제어(dsrdtr·rtscts·xonxoff)를 끄고 DTR/RTS를 **내린 상태로** 설정하고 나서 ``open()``한다
    (pyserial은 이 값을 열 때 적용한다). 리눅스는 열 때 커널이 DTR을 잠깐 올릴 수 있어(HUPCL) 리셋을
    완전히 막는다고 보장하지 않는다 — 필요하면 ``stty -F <포트> -hupcl``. 그래서 연결 쪽
    (`SerialMotionClient.connect`)이 부트 잡음·``ready`` 배너·status 재시도를 따로 처리한다.
    """

    def __init__(self, port: str, baud: int, *, serial_module: Any = None) -> None:
        if serial_module is None:
            try:
                import serial as serial_module  # type: ignore[import-untyped, no-redef]  # noqa: PLC0415
            except ImportError as exc:
                raise RuntimeError(
                    "pyserial is not installed. Run: pip install -e \".[gpio]\""
                ) from exc
        ser = serial_module.Serial()
        ser.port = port
        ser.baudrate = baud
        ser.timeout = 0
        ser.dsrdtr = False
        ser.rtscts = False
        ser.xonxoff = False
        ser.dtr = False  # 열기 전에 내려 둔다 — FireBeetle 자동 리셋 회로(EN·IO0)를 건드리지 않게
        ser.rts = False
        ser.open()
        with contextlib.suppress(Exception):
            ser.reset_input_buffer()  # 열기 전에 쌓인 줄은 이번 연결과 무관하다
        self._serial = ser
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
    "connect_timeout_s": "SIMPLELAY_MOTION_CONNECT_TIMEOUT_S",
    "position_tolerance_counts": "SIMPLELAY_MOTION_POSITION_TOLERANCE_COUNTS",
    "z_cooldown_backoff_ms": "SIMPLELAY_MOTION_Z_COOLDOWN_BACKOFF_MS",
}

#: MCU가 알리는 Z 누름 방식(firmware-motion/protocol_table.json z_modes).
Z_MODES = ("motor", "solenoid")
#: 위치를 잃지 않은 MCU 거절 — 알람·재홈으로 번지지 않게 `MotionRefused`로 올린다.
#: soft_limit: 알람 이벤트 없이 온 거절 응답은 움직이기 전 범위 검사다(움직이다 넘으면 alarm 이벤트가 먼저 온다).
MCU_REFUSAL_ERRORS = frozenset({"z_unsupported", "z_cooldown", "soft_limit"})
#: z_cooldown 재시도: MCU가 남은 시간을 알리지 않을 때의 기본 기다림(초, 호스트 박자 — 측정 필요)과
#: 기다림 상한(초). 남은 시간이 상한보다 길면 기다리지 않고 거절한다. 남은 시간에 더하는 여유(초).
Z_COOLDOWN_DEFAULT_BACKOFF_S = 0.5
Z_COOLDOWN_WAIT_MAX_S = 2.0
Z_COOLDOWN_MARGIN_S = 0.05

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
    "position_tolerance_counts",
    "z_cooldown_backoff_ms",
)
_TIMEOUT_FIELDS = ("status_timeout_s", "home_timeout_s", "move_timeout_s", "press_timeout_s", "connect_timeout_s")

#: connect()의 status 재시도 간격(초): 처음 값에서 두 배씩, 상한까지. 호스트 박자라 기구 값이 아니다.
CONNECT_BACKOFF_START_S = 0.2
CONNECT_BACKOFF_MAX_S = 1.0
#: 이 리셋 이유로 ready가 오면 경고한다(펌웨어 워치독·패닉·전압 강하로 재부팅).
_ABNORMAL_RESETS = frozenset({"panic", "task_wdt", "int_wdt", "wdt", "brownout"})


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
    #: connect()가 부팅 배너·status 응답을 기다리는 총 시간(초). 포트를 열면 ESP32가 리셋될 수 있어
    #: 첫 status가 사라질 수 있다 — 이 시간 동안 backoff로 재시도한다. 호스트 박자라 기본값을 둔다.
    connect_timeout_s: float | None = 5.0
    #: 이동 뒤 엔코더 보고 위치와 명령 카운트의 허용 차(모터 카운트). None이면 검사하지 않는다.
    #: 값은 측정 필요(MCU 도착 허용 오차 POS_TOLERANCE_COUNTS보다 넉넉하게).
    position_tolerance_counts: int | None = None
    #: 솔레노이드 z_cooldown 거절 뒤 MCU가 남은 시간(retry_ms)을 알리지 않을 때 기다릴 시간(ms).
    #: None이면 `Z_COOLDOWN_DEFAULT_BACKOFF_S`. 호스트 박자 — 측정 필요.
    z_cooldown_backoff_ms: int | None = None

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


def heartbeat_off_warning(config: MotionConfig) -> str | None:
    """heartbeat를 끈 설정이면 시작 경고 문구(아니면 None). act_main·조그 CLI가 쓴다."""
    if config.heartbeat_ms is not None:
        return None
    return (
        "SIMPLELAY_MOTION_HEARTBEAT_MS=off — 동작 응답을 기다리는 동안 ping을 보내지 않습니다. "
        "MCU 워치독(firmware-motion HOST_WATCHDOG_MS, 2 s 자리표시자)이 2 s 넘게 걸리는 "
        "home·move·press를 host_timeout으로 끊습니다"
    )


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
        self._position_seq = 0  # 위치 보고를 받을 때마다 1 증가 — 이번 요청 중에 왔는지 가린다
        self._z_mode: str | None = None
        self._z_on_max_ms: int | None = None
        #: z_cooldown 뒤 기다렸다가 다시 누른 횟수 — 시험·로그용.
        self.cooldown_retries = 0
        #: 보낸 heartbeat(ping) 수 — 시험·로그용.
        self.heartbeats_sent = 0
        #: 마지막으로 받은 부팅 배너(``ready`` 이벤트) — 없으면 None.
        self.ready_info: dict | None = None
        #: 마지막 connect()의 status 시도 횟수와 실패 이유(성공하면 None).
        self.connect_attempts = 0
        self._connect_error: str | None = None
        #: 동작 중 MCU 재시작(MotionReset)을 본 뒤 새 실행(reset_stop)이나 명시적 home() 전까지 True —
        #: 그동안은 auto_home이 켜져 있어도 스스로 재홈해 다시 누르지 않는다(장애 복구 결과표, 2026-10-07).
        self._reset_mid_run = False

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
            self._position_seq += 1

    @property
    def z_mode(self) -> str | None:
        """MCU가 알린 Z 누름 방식(``motor``|``solenoid``). 알리지 않았으면 None."""
        with self._state_lock:
            return self._z_mode

    @property
    def z_on_max_ms(self) -> int | None:
        """MCU가 알린 솔레노이드 한 번 켜짐 상한(ms). 모터 방식이거나 알리지 않았으면 None."""
        with self._state_lock:
            return self._z_on_max_ms

    def _note_z_mode(self, doc: dict) -> None:
        value = doc.get("z_mode")
        if value in Z_MODES:
            on_max = _opt_int(doc.get("z_on_max_ms"))
            with self._state_lock:
                self._z_mode = value
                if "z_on_max_ms" in doc:
                    self._z_on_max_ms = on_max if on_max is not None and on_max > 0 else None
        elif value is not None:
            log.warning("motion: unknown z_mode=%r ignored", value)

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
        """포트를 연 직후의 상태 조회. MCU가 알람이면 준비 안 됨, 홈 완료를 보고해야만 READY.

        포트를 열면 ESP32가 리셋될 수 있다(자동 리셋 회로). 부팅 중에 보낸 status는 사라지므로
        ``connect_timeout_s`` 동안 status를 backoff(0.2 s → 두 배 → 1 s 상한)로 재시도한다. 기다리는
        동안 부트 로그(JSON 아닌 줄)는 버리고, 펌웨어 ``ready`` 배너가 오면 바로 다시 묻는다.
        기한 안에 답이 없으면 `MotionTimeout` — 상태는 UNKNOWN으로 남는다(`not_ready_reason`).
        """
        self._config.require("상태 조회", ("status_timeout_s",))
        status_timeout = self._config.status_timeout_s
        assert status_timeout is not None
        budget = self._config.connect_timeout_s or status_timeout
        deadline = self._clock() + budget
        delay = CONNECT_BACKOFF_START_S
        attempts = 0
        last_error = "응답 없음"
        with self._op_lock:
            while True:
                attempts += 1
                self.connect_attempts = attempts
                remaining = deadline - self._clock()
                try:
                    reply = self._request(
                        {"cmd": "status"},
                        max(min(status_timeout, remaining), self._poll_s),
                        allow_when_stopped=True,
                        stop_on_timeout=False,
                        quiet_noise=True,
                    )
                except MotionTimeout as exc:
                    last_error = str(exc)
                else:
                    self._connect_error = None
                    return self._apply_status(reply)
                remaining = deadline - self._clock()
                if remaining <= 0:
                    break
                self._drain_until_ready(min(delay, remaining))
                delay = min(delay * 2, CONNECT_BACKOFF_MAX_S)
        self._connect_error = f"{budget:g}s 동안 status 시도 {attempts}회 무응답"
        raise MotionTimeout(f"모션 MCU 연결 확인 실패: {self._connect_error} ({last_error})")

    def not_ready_reason(self) -> str | None:
        """연결 확인(status 성공) 전이면 사람이 읽을 이유, 아니면 None. act_main readiness가 쓴다."""
        with self._state_lock:
            if self._state is not MotionState.UNKNOWN:
                return None
        error = self._connect_error
        return f"모션 MCU 연결 확인 전({error})" if error else "모션 MCU 연결 확인 전"

    def status(self) -> MotionStatus:
        self._config.require("상태 조회", ("status_timeout_s",))
        with self._op_lock:
            reply = self._request({"cmd": "status"}, self._config.status_timeout_s, allow_when_stopped=True)
        return self._apply_status(reply)

    def _apply_status(self, reply: dict) -> MotionStatus:
        status = MotionStatus(
            state=str(reply.get("state", "unknown")),
            homed=reply.get("homed") is True,
            a_counts=_opt_int(reply.get("a")),
            b_counts=_opt_int(reply.get("b")),
            z_counts=_opt_int(reply.get("z")),
            alarm=reply.get("alarm") if isinstance(reply.get("alarm"), str) else None,
        )
        self.last_status = status
        self._note_z_mode(reply)
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
            self._reset_mid_run = False

    def move_to(self, x_mm: float, y_mm: float) -> None:
        """절대 좌표(mm)로 이동. 소프트 리밋·기구 값·홈 확인을 **보내기 전에** 한다."""
        request = self._move_request(x_mm, y_mm)
        self._config.require("XY 이동", ("move_timeout_s",))
        self._refuse_if_stopped("XY 이동")
        self._require_homed("XY 이동")
        with self._op_lock:
            self._run_busy(request, self._config.move_timeout_s)

    def press_with_observation(self, command: PressCommand, before_press: Callable[[], None]) -> None:
        """자동 원점·XY 이동 뒤, Z 명령 직전에 관측을 시작한다."""
        self.press(command, before_press=before_press)

    def press(self, command: PressCommand, *, before_press: Callable[[], None] | None = None) -> None:
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
            if self._reset_mid_run:
                raise MotionRefused(
                    f"'{command.button}' 누름: 이번 실행 중 MCU 재시작 또는 통신 오류가 발생했습니다 — 자동 재홈·재누름 없이 멈춤"
                    "(사람이 확인한 뒤 새로 요청)"
                )
            if self._config.auto_home and self.state in (MotionState.UNHOMED, MotionState.UNKNOWN):
                self.home()
            else:
                self._require_homed(f"'{command.button}' 누름")

        with self._op_lock:
            self._run_busy(move, self._config.move_timeout_s)
            if before_press is not None:
                before_press()
            self._refuse_if_stopped(f"'{command.button}' 누름")
            self._emit("press_command", {"button": command.button})
            try:
                self._run_busy(press, self._config.press_timeout_s)
            except MotionRefused as exc:
                wait = self._cooldown_wait(exc)
                if wait is None:
                    raise
                # 코일 냉각 시간 안 — 움직이지 않은 거절. 남은 시간만큼 기다렸다가 한 번만 다시 누른다.
                log.info("motion: '%s' press in solenoid cooldown — retrying once in %.2fs", command.button, wait)
                self._emit("press_cooldown_wait", {"button": command.button, "wait_s": round(wait, 3)})
                if self._stop.wait(wait):
                    raise MotionStopped(f"'{command.button}' 누름: 냉각 대기 중 정지 요청") from exc
                self.cooldown_retries += 1
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
        self._reset_mid_run = False

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

    def _cooldown_wait(self, exc: MotionRefused) -> float | None:
        """z_cooldown 거절이면 기다릴 시간(초), 아니면 None. 상한보다 길면 None(바로 거절)."""
        if exc.code != "z_cooldown":
            return None
        if exc.retry_ms is not None:
            wait = max(exc.retry_ms, 0) / 1000.0 + Z_COOLDOWN_MARGIN_S
        elif self._config.z_cooldown_backoff_ms is not None:
            wait = self._config.z_cooldown_backoff_ms / 1000.0
        else:
            wait = Z_COOLDOWN_DEFAULT_BACKOFF_S
        if wait > Z_COOLDOWN_WAIT_MAX_S:
            log.warning("motion: solenoid cooldown %.2fs exceeds the %.1fs wait bound — refusing", wait,
                        Z_COOLDOWN_WAIT_MAX_S)
            return None
        return wait

    def _press_request(self, command: PressCommand) -> dict:
        cfg = self._config
        cfg.require("누름", ("press_mode",))
        if cfg.press_mode == "depth" and self.z_mode == "solenoid":
            raise MotionRefused(
                "Z가 솔레노이드라 깊이(depth) 누름을 받지 않습니다 — "
                "SIMPLELAY_MOTION_PRESS_MODE=duration으로 시간 누름을 쓰세요"
            )
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
        on_max = self.z_on_max_ms
        if cfg.press_mode == "duration" and self.z_mode == "solenoid" and on_max is not None:
            if amount + dwell > on_max:
                raise MotionRefused(
                    f"솔레노이드 켜짐 {amount + dwell}ms(구동 {amount} + 유지 {dwell})가 MCU 상한 "
                    f"{on_max}ms를 넘어 움직이기 전에 거절합니다"
                )
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
        previous = self.state
        with self._state_lock:
            seq_before = self._position_seq
        self._set_state(MotionState.BUSY)
        try:
            reply = self._request(request, timeout_s)
        except MotionRefused:
            # 움직이기 전 MCU 거절(z_unsupported·z_cooldown) — 위치를 잃지 않았다.
            if self.state is MotionState.BUSY:
                self._set_state(previous)
            raise
        except MotionStopped:
            self._set_state(MotionState.STOPPED)
            raise
        except MotionReset:
            raise  # _note_ready가 이미 UNHOMED로 두었다 — 재홈 필요
        except MotionAlarm:
            self._set_state(MotionState.ALARM)
            raise
        except BaseException:
            # 기한 초과·프로토콜 오류: 어디서 멈췄는지 모른다 → 재홈 전까지 준비 안 됨
            # 전송 오류도 실제 누름 여부가 불명확하다. 같은 실행의 보정 루프가
            # 자동 원점·재누름으로 이어지지 않게 재부팅과 같은 차단을 유지한다.
            self._reset_mid_run = True
            if self.state is MotionState.BUSY:
                self._set_state(MotionState.UNHOMED)
            raise
        if request.get("cmd") == "move":
            mismatch = self._position_mismatch(request, seq_before)
            if mismatch is not None:
                self._set_state(MotionState.UNHOMED)
                self._emit("position_mismatch", {"detail": mismatch})
                raise MotionPositionMismatch(f"이동 뒤 위치 불일치: {mismatch} — 재홈 필요")
        self._set_state(MotionState.READY)
        return reply

    def _position_mismatch(self, request: dict, seq_before: int) -> str | None:
        """위치 일치 검사(선택). 문제가 없거나 검사가 꺼져 있으면 None, 아니면 사람이 읽을 이유."""
        tolerance = self._config.position_tolerance_counts
        if tolerance is None:
            return None
        with self._state_lock:
            fresh = self._position_seq != seq_before
            position = dict(self._last_position) if self._last_position is not None else None
        if not fresh or position is None:
            return "MCU 위치 보고 없음(검사를 켰으면 position 이벤트가 필요)"
        diffs = []
        for axis in ("a", "b"):
            error = position[f"{axis}_counts"] - int(request[axis])
            if abs(error) > tolerance:
                diffs.append(f"{axis} 명령 {request[axis]} / 보고 {position[f'{axis}_counts']} (차 {error:+d})")
        if not diffs:
            return None
        return ", ".join(diffs) + f" > 허용 {tolerance}"

    def _request(
        self,
        body: dict,
        timeout_s: float | None,
        *,
        allow_when_stopped: bool = False,
        stop_on_timeout: bool = True,
        quiet_noise: bool = False,
    ) -> dict:
        assert timeout_s is not None  # require()가 먼저 거른다
        request_id = self._send_request(body)
        deadline = self._clock() + timeout_s
        beat_s = self._heartbeat_s(body["cmd"])
        next_beat = self._clock() + beat_s if beat_s is not None else None
        while True:
            if self._stop.is_set() and not allow_when_stopped:
                raise MotionStopped(f"'{body['cmd']}' 도중 정지 요청으로 중단됨")
            now = self._clock()
            remaining = deadline - now
            if remaining <= 0:
                if stop_on_timeout:
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
                # 부트 로그·잡음. 연결 중에는 흔하므로 조용히 버린다.
                (log.debug if quiet_noise else log.warning)("motion: ignored unparsable line: %.120s", line)
                continue
            if "event" in doc:
                self._note_position(doc, "mcu_event")
                if doc.get("event") == "ready":
                    self._note_ready(doc)
                    if body["cmd"] in HEARTBEAT_CMDS:
                        self._reset_mid_run = True
                        raise MotionReset(f"'{body['cmd']}' 도중 MCU가 재시작했습니다(ready 배너) — 재홈 필요")
                    # 조회는 MCU가 부팅 중에 받은 요청을 잃었을 수 있다 — 새 id로 다시 묻는다.
                    request_id = self._send_request(body)
                    continue
                self._handle_event(doc)
                continue
            if doc.get("id") != request_id:
                continue  # 시간 초과로 버린 요청의 늦은 응답·정지 응답·heartbeat(ping) 응답
            if doc.get("ok") is True:
                self._note_position(doc, "mcu_reply")
                return doc
            error = doc.get("error") if isinstance(doc.get("error"), str) else "unknown"
            if error in MCU_REFUSAL_ERRORS:
                raise MotionRefused(f"MCU가 '{body['cmd']}'를 거절: {error}", code=error,
                                    retry_ms=_opt_int(doc.get("retry_ms")))
            raise MotionAlarm(f"MCU가 '{body['cmd']}'를 거절/실패 보고: {error}")

    def _send_request(self, body: dict) -> int:
        with self._write_lock:
            self._next_id += 1
            request_id = self._next_id
            self._transport.write_line(json.dumps({"id": request_id, **body}, ensure_ascii=False))
        return request_id

    def _note_ready(self, doc: dict) -> None:
        """부팅 배너. MCU가 (재)시작했으므로 원점 기준이 없다 — 정지 표시가 아니면 UNHOMED로."""
        self.ready_info = dict(doc)
        self._note_z_mode(doc)
        reset = doc.get("reset")
        self._emit("ready", doc)
        if reset in _ABNORMAL_RESETS:
            log.warning("motion MCU restarted after abnormal reset=%s (fw=%s)", reset, doc.get("fw"))
        else:
            log.info("motion MCU ready (fw=%s protocol=%s reset=%s)", doc.get("fw"), doc.get("protocol"), reset)
        with self._state_lock:
            if self._state is not MotionState.STOPPED:
                self._state = MotionState.UNHOMED

    def _drain_until_ready(self, wait_s: float) -> bool:
        """연결 재시도 사이에 줄을 읽어 버린다. ``ready`` 배너를 받으면 True로 바로 돌아온다."""
        deadline = self._clock() + wait_s
        while True:
            remaining = deadline - self._clock()
            if remaining <= 0:
                return False
            line = self._transport.read_line(min(self._poll_s, remaining))
            if line is None:
                continue
            doc = _parse_line(line)
            if doc is None:
                log.debug("motion: boot noise ignored: %.120s", line)
                continue
            if doc.get("event") == "ready":
                self._note_ready(doc)
                return True
            if "event" in doc:
                self._emit(str(doc.get("event")), doc)
            # 응답 줄은 이전 시도의 늦은 응답 — 버린다.

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
