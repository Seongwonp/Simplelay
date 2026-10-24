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

Z 누름 방식(2026-10-05): Z가 엔코더 모터(``motor``), 솔레노이드(``solenoid``), 또는 BLE Bot
(``switchbot``)인지 MCU가 ``ready``
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

정지 확인 단계(2026-10-13, docs/계획-정지-확인-2026-10-12.md): `SerialMotionClient.request_stop`은 정지 줄을
쓰고 **바로** 돌아온다(정지 경로를 막지 않는다). 보낸 id·시각을 남기고, MCU의 같은 id ``ok:true``를 읽으면 받은
시각을 기록한다 — 진행 중 요청의 읽기 루프가 그 줄을 버리지 않고 기록하고, 대기 중이면 `wait_stop_ack`가
짧은 기한 안에 직접 읽는다(읽는 쪽은 언제나 op 잠금을 쥔 하나). 단계: ``sent``(정지 줄을 썼다) → ``mcu_ack``
(MCU가 받았다, 지연 ms) → ``verified``(`confirm_stop`: 정지 뒤 status 두 번의 엔코더 a·b가 같다). 엔코더가
모터 축에 있어 벨트 미끄럼은 보이지 않고, 물리 E-STOP이 여전히 최종 권한이다. 기한 값은 측정 필요.

모든 하드웨어 값(풀리·벨트·R_out·리밋·방향·누름 깊이/시간·타임아웃)은 설정으로만
받는다. 기본값은 None이고, 필요한 값이 비어 있으면 **움직이기 전에** 거절한다.
"""

from __future__ import annotations

import contextlib
import errno
import json
import logging
import math
import os
import queue
import re
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
    """모션 어댑터 오류의 공통 부모. 폐루프는 이것을 누름 실패로 센다.

    ``motion_abort_reason``이 None이 아니면(알람·재시작·기한 초과·준비 안 됨, 2026-10-14) 폐루프는 **재시도하지 않고**
    바로 멈추고 결과에 그 원인을 싣는다 — 다시 눌러도 움직이지 않고 '눌림 확인 실패'로 원인이 바뀌어 보인다."""

    motion_abort_reason: str | None = None


class MotionConfigError(MotionError):
    """필요한 모션 설정이 비어 있다. 채워지기 전에는 움직이지 않는다."""

    motion_abort_reason = "motion_not_ready"

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


class MotionNotReady(MotionRefused):
    """원점 복귀 전이거나 이번 실행 중 재시작·통신 오류가 있어 누를 수 없다(2026-10-14). 다시 시도해도 같다."""

    motion_abort_reason = "motion_not_ready"


class MotionTimeout(MotionError):
    """MCU가 기한 안에 응답하지 않았다. 위치를 믿을 수 없어 재홈 전까지 준비 안 됨."""

    motion_abort_reason = "motion_timeout"


class MotionStopped(MotionError):
    """정지 요청으로 동작이 중단됐다. 폐루프는 재시도하지 않고 멈춘다."""


class MotionAlarm(MotionError):
    """MCU가 오류·알람을 보고했다(리밋·스톨·원점 미검출 등). ``reason``은 MCU가 보낸 코드(예: ``stall``)."""

    def __init__(self, message: str, *, reason: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason

    @property
    def motion_abort_reason(self) -> str:  # type: ignore[override]
        code = self.reason if isinstance(self.reason, str) and _ABORT_CODE.fullmatch(self.reason) else None
        return f"motion_alarm: {code}" if code else "motion_alarm"


class MotionPressFailed(MotionError):
    """누름 장치가 결과를 실패로 보고했다. XY 원점은 잃지 않지만 같은 실행에서 자동 재누름하지 않는다."""

    def __init__(self, message: str, *, reason: str, press_outcome: str) -> None:
        super().__init__(message)
        self.reason = reason
        self.press_outcome = press_outcome

    @property
    def motion_abort_reason(self) -> str:  # type: ignore[override]
        code = self.reason if _ABORT_CODE.fullmatch(self.reason) else None
        return f"motion_press_failed: {code}" if code else "motion_press_failed"


#: 결과에 싣는 MCU 알람 코드 모양(그 밖의 값은 코드 없이 ``motion_alarm``).
_ABORT_CODE = re.compile(r"[A-Za-z0-9_.\-]{1,40}")


class MotionReset(MotionAlarm):
    """동작 중 MCU가 재시작했다(``ready`` 배너). 진행 중 명령은 사라졌고 원점 기준도 없다."""

    @property
    def motion_abort_reason(self) -> str:  # type: ignore[override]
        return "motion_reset"


class MotionPositionMismatch(MotionError):
    """이동은 ``ok``였지만 MCU가 보고한 엔코더 위치가 명령과 허용 오차 넘게 다르다(또는 보고 없음).

    어디 있는지 믿을 수 없어 재홈 전까지 준비 안 됨으로 둔다. 폐루프는 재시도하지 않고 멈춘다(2026-10-14).
    """

    motion_abort_reason = "motion_position_mismatch"


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
        if "://" in port:
            # pyserial URL(예: socket://host:port — 모의 보드 rpi/tools/touchbridge_sim.py). 규약 처리는 같다.
            ser = serial_module.serial_for_url(port, do_not_open=True)
        else:
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

    def close(self) -> None:
        """포트를 닫는다(끊긴 포트를 붙잡지 않게 — `ReopeningLineTransport`가 부른다)."""
        with contextlib.suppress(Exception):
            self._serial.close()


#: 포트 다시 열기 간격(초) — 마지막 값에서 멈춰 그 간격으로 계속한다. 호스트 박자(측정 필요 아님).
REOPEN_BACKOFF_S = (0.5, 1.0, 2.0, 4.0, 8.0)


class ReopeningLineTransport:
    """끊기면 닫고 **설정 경로로 다시 여는** 전송(2026-10-14, 보드 날 발견 1) — **실물 재열거 미검증**.

    USB 재열거(모터 전원 투입 때 저전압 등)로 ``ttyACM0``가 사라지고 ``ttyACM1``로 다시 잡히면, 열린 파일은 영영 EIO다.
    쓰기·읽기에서 ``OSError``(pyserial ``SerialException`` 포함)가 나면 그 포트를 닫고 끊김으로 표시한 뒤 예외를 그대로 올린다
    (진행 중 명령은 연결 오류로 끝나고 폐루프는 다시 누르지 않는다). 끊긴 동안의 쓰기·읽기는 죽은 포트에 닿지 않고 바로
    ``OSError``다. 다시 열기는 `try_reopen`(백오프)만 한다 — RPi4 실행기의 감시 스레드가 부른다.

    경로는 **설정 그대로**다. 재열거 뒤 이름이 바뀌는 ``/dev/ttyACM0`` 대신 ``/dev/serial/by-id/…``를 쓰라고 런북에 적었다.
    """

    def __init__(
        self,
        opener: Callable[[], "LineTransport"],
        *,
        describe: str = "",
        initial: "LineTransport | None" = None,
        backoff_s: tuple[float, ...] = REOPEN_BACKOFF_S,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if not backoff_s:
            raise ValueError("backoff_s must not be empty")
        self._opener = opener
        self._describe = describe
        self._backoff_s = tuple(backoff_s)
        self._clock = clock
        self._lock = threading.Lock()
        self._inner = initial if initial is not None else opener()
        self._down_reason: str | None = None
        self._failures = 0
        self._next_try = 0.0
        self._listener: Callable[[str], None] | None = None
        #: 다시 연 횟수 — 시험·로그용.
        self.reopens = 0

    def set_link_listener(self, listener: "Callable[[str], None] | None") -> None:
        """끊김을 알 함수(이유 한 줄). 끊김을 처음 본 스레드에서 한 번 불린다."""
        self._listener = listener

    @property
    def link_down_reason(self) -> str | None:
        """끊겨 있으면 사람이 읽을 이유, 열려 있으면 None."""
        with self._lock:
            return self._down_reason

    def write_line(self, line: str) -> None:
        inner = self._current()
        try:
            inner.write_line(line)
        except OSError as exc:
            self._drop(inner, exc)
            raise

    def read_line(self, timeout_s: float) -> str | None:
        inner = self._current()
        try:
            return inner.read_line(timeout_s)
        except OSError as exc:
            self._drop(inner, exc)
            raise

    def try_reopen(self) -> bool:
        """끊겨 있고 백오프가 지났으면 설정 경로로 한 번 다시 연다. 열려 있게 됐으면 True."""
        with self._lock:
            if self._inner is not None:
                return True
            if self._clock() < self._next_try:
                return False
        try:
            fresh = self._opener()
        except (OSError, RuntimeError, ValueError) as exc:
            with self._lock:
                self._failures += 1
                self._next_try = self._clock() + self._backoff_s[min(self._failures, len(self._backoff_s) - 1)]
                self._down_reason = f"{self._describe or '모션 포트'} 다시 열기 실패: {exc}"
            log.warning("motion port reopen failed (%s): %s", self._describe, exc)
            return False
        with self._lock:
            self._inner = fresh
            self._down_reason = None
            self._failures = 0
            self.reopens += 1
        log.warning("motion port reopened: %s (재열거 뒤 — 연결 확인·원점 전까지 준비 안 됨)", self._describe)
        return True

    def close(self) -> None:
        with self._lock:
            inner, self._inner = self._inner, None
            self._down_reason = self._down_reason or "닫힘"
        _close_quietly(inner)

    def _current(self) -> "LineTransport":
        with self._lock:
            inner = self._inner
            reason = self._down_reason
        if inner is None:
            raise OSError(errno.ENODEV, f"모션 포트 끊김 — 다시 여는 중 ({reason})")
        return inner

    def _drop(self, inner: "LineTransport", exc: BaseException) -> None:
        with self._lock:
            if self._inner is not inner:
                return  # 이미 다른 스레드가 내렸다
            self._inner = None
            self._down_reason = f"{type(exc).__name__}: {exc}"
            self._failures = 0
            self._next_try = self._clock() + self._backoff_s[0]
            reason = self._down_reason
        _close_quietly(inner)
        log.error("motion port lost (%s): %s — closed, reopening the configured path", self._describe, reason)
        listener = self._listener
        if listener is not None:
            try:
                listener(reason)
            except Exception:  # noqa: BLE001 - 알림 고장이 전송 오류 보고를 가리지 않는다
                log.exception("motion link listener failed")


def _close_quietly(transport: object) -> None:
    close = getattr(transport, "close", None)
    if callable(close):
        with contextlib.suppress(Exception):
            close()


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
Z_MODES = ("motor", "solenoid", "switchbot")
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

    def missing_for_press(self, z_mode: str | None = None) -> tuple[str, ...]:
        """첫 누름(보정 없음)에 필요한데 비어 있는 모든 설정 — 시작 로그용."""
        missing = list(self.kinematics.missing_for_motion())
        if z_mode == "switchbot":
            base = ["move_timeout_s", "press_timeout_s"]
        else:
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


# ── 정지 확인 단계(2026-10-13) ─────────────────────────────────────────────────

#: 정지 줄을 전송 계층에 썼다(MCU가 받았는지는 모름).
STOP_SENT = "sent"
#: MCU가 같은 id로 ``ok:true``를 답했다.
STOP_MCU_ACK = "mcu_ack"
#: 정지 뒤 status 두 번의 엔코더 a·b가 같았다(모터 축 기준 — 벨트 미끄럼은 보이지 않는다). 2026-10-15 G11부터는 **이번
#: 실행에 이동을 명령한 축마다 엔코더 값이 실제로 바뀐 것을 본 경우**에만 — 죽은 엔코더(늘 같은 값)는 멈춤과 구별되지 않는다.
STOP_VERIFIED = "verified"
#: 엔코더가 살아 있다는 근거가 없어 ``verified``로 올리지 않을 때의 이유(2026-10-15 G11, ``mcu_ack``에 머문다).
ENCODER_UNPROVEN_DETAIL = "엔코더 움직임을 확인할 수 없어 멈춤은 확인하지 못했어요"
STOP_LEVELS = (STOP_SENT, STOP_MCU_ACK, STOP_VERIFIED)
#: 대기 중 정지에서 MCU 응답을 기다리는 기본 기한(초)과 멈춤 확인 status 간격(초). 10/13 실물(ESP32 USB, n=10):
#: 정지→MCU 응답 중앙 10.6 ms·최대 11.0 ms라 0.3 s는 여유를 둔 값이다.
STOP_ACK_TIMEOUT_S = 0.3
STOP_VERIFY_INTERVAL_S = 0.05
#: 멈춤 확인 기한(초). 10/13 실물(벨트 없이 모터 축, 이동 중 정지 n=10): 정지 뒤 관성 1~7카운트, 엔코더는 약 0.15 s 안에
#: 멈췄다(같은 값 두 번 연속까지 중앙 160 ms·최대 162 ms). 기한 안에 같은 값 두 번을 못 보면 ``mcu_ack``로 남는다.
STOP_VERIFY_DEADLINE_S = 0.5
#: id별로 남겨 두는 최근 정지 기록 수(2차 평가 M-N2). 확인 기한(1초 미만) 안의 연속 정지만 덮으면 된다.
_STOP_RECORDS_KEPT = 16


@dataclass(frozen=True)
class StopReport:
    """정지 한 번의 확인 단계. ``level``은 `STOP_LEVELS` 중 하나, 정지 줄을 쓰지 못했으면 None."""

    stop_id: int | None
    sent: bool
    level: str | None
    ack_ms: int | None = None
    detail: str | None = None

    def fields(self) -> dict:
        """규약 프레임에 싣는 모양 ``{"stop_level", "ack_ms"}``(+ 있으면 ``stop_detail``)."""
        out: dict = {"stop_level": self.level, "ack_ms": self.ack_ms}
        if self.detail:
            out["stop_detail"] = self.detail
        return out


@dataclass
class _StopRecord:
    stop_id: int
    sent_ns: int
    sent: bool = True
    acked_ns: int | None = None
    verified: bool = False
    detail: str | None = None


class SerialMotionClient(GrblClient):
    """줄 단위 JSON으로 모션 MCU와 대화하는 GrblClient — **실물 미검증**."""

    motion_protocol = "line-json/v0"

    def position_xy(self, status: MotionStatus | None = None) -> tuple[float, float] | None:
        status = self.last_status if status is None else status
        if status is None or status.a_counts is None or status.b_counts is None:
            return None
        return motor_counts_to_xy(status.a_counts, status.b_counts, self.config.kinematics)

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
        #: 마지막으로 보낸 정지(id·보낸 시각·MCU 응답 시각). 정지 확인 단계용(2026-10-13).
        self._last_stop: _StopRecord | None = None
        #: 최근 정지들의 기록(id별, 최대 `_STOP_RECORDS_KEPT`개) — 연속 정지에서도 각 확인이 자기 정지의 기록만
        #: 읽게 한다(2차 평가 M-N2).
        self._stops: dict[int, _StopRecord] = {}
        #: 전송 계층이 포트를 잃은 뒤 연결 확인(connect)을 아직 못 했으면 True(2026-10-14).
        self._link_dropped = False
        #: 이 프로세스가 아직 스스로 원점을 잡지 않았거나, 포트를 다시 연결한 뒤라 MCU의 ``homed`` 보고를 믿지 않는다
        #: (2026-10-19). 실행기만 다시 시작했거나(MCU 전원 유지) 포트만 다시 붙었으면 MCU는 homed라고 해도, 그사이 손으로
        #: 캐리지를 옮겼거나 이동 도중 실행기가 죽었을 수 있다. 성공한 ``home()``만 푼다.
        self._origin_unverified = True
        # 엔코더 생존 근거(2026-10-15 G11) — ``_state_lock``으로 보호. 이번 실행(``reset_stop`` 뒤)에 이동을 명령한 축
        # (``_enc_need``)과, 기준값(``_enc_ref``)에서 실제로 값이 바뀐 것을 본 축(``_enc_moved``). 축 순서는 (a, b).
        self._enc_ref: tuple[int, int] | None = None
        self._enc_need = [False, False]
        self._enc_moved = [False, False]

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
            # 엔코더 생존 근거(G11): 기준값과 다른 값을 본 축은 살아 있다(값이 바뀌었다). 기준이 없으면 이 값이 기준이다.
            if self._enc_ref is None:
                self._enc_ref = (a, b)
            else:
                self._enc_moved[0] = self._enc_moved[0] or a != self._enc_ref[0]
                self._enc_moved[1] = self._enc_moved[1] or b != self._enc_ref[1]

    def _reset_encoder_evidence(self, *, keep_reference: bool) -> None:
        """엔코더 생존 근거를 비운다(G11). ``keep_reference``면 마지막으로 본 값을 새 기준으로 둔다(새 실행 — 쉬는 사이
        카운트는 그대로다). 아니면 기준도 버린다(원점 복귀·MCU 재시작·포트 잃음 — 카운트가 0으로 돌아가는 것은 엔코더가
        살아 있다는 근거가 아니다)."""
        with self._state_lock:
            last = self._last_position
            self._enc_ref = ((last["a_counts"], last["b_counts"])
                             if keep_reference and last is not None else None)
            self._enc_need = [False, False]
            self._enc_moved = [False, False]

    def _note_commanded_move(self, body: dict) -> None:
        """이동 명령을 보낸다(G11) — 목표 카운트가 마지막으로 본 값과 다른 축은 이번 실행에서 엔코더가 바뀌어야 한다.
        마지막 값을 모르면 두 축 모두로 본다(보수적)."""
        with self._state_lock:
            last = self._last_position
            for i, (key, axis) in enumerate((("a_counts", "a"), ("b_counts", "b"))):
                target = body.get(axis)
                if isinstance(target, int) and (last is None or last.get(key) != target):
                    self._enc_need[i] = True

    def _encoders_proven(self) -> bool:
        """이번 실행에 이동을 명령한 축이 있고, 그 축마다 엔코더 값이 바뀐 것을 봤나(G11)."""
        with self._state_lock:
            need, moved = tuple(self._enc_need), tuple(self._enc_moved)
        return any(need) and all(m for n, m in zip(need, moved) if n)

    @property
    def z_mode(self) -> str | None:
        """MCU가 알린 Z 누름 방식(``motor``|``solenoid``|``switchbot``). 알리지 않았으면 None."""
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

    def _set_ready_unless_stopped(self) -> bool:
        """정지 요청이 없을 때만 READY로 둔다. 정지가 끼어들었으면 STOPPED(재홈 필요)로 두고 False.

        ``request_stop``은 BUSY일 때만 STOPPED로 바꾸므로, 응답과 정지가 엇갈리면 READY로 덮어쓰지 않게
        같은 잠금 안에서 정지 표시를 다시 본다(검토 10/19)."""
        with self._state_lock:
            if self._stop.is_set() or self._state is MotionState.STOPPED:
                self._state = MotionState.STOPPED
                return False
            self._state = MotionState.READY
            return True

    # ── 명령 ─────────────────────────────────────────────────────────────────

    def connect(self) -> MotionStatus:
        """포트를 연 직후의 상태 조회. MCU가 알람이면 준비 안 됨. MCU가 홈 완료를 보고해도 READY가 아니라 UNHOMED다
        (2026-10-19) — 실행기 시작·포트 재연결 뒤에는 이 프로세스가 ``home()``으로 원점을 다시 잡아야 위치를 믿는다.

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
                    self._link_dropped = False
                    # 연결 확인(실행기 시작·포트 재연결) 뒤에는 MCU의 homed를 그대로 믿지 않는다(2026-10-19).
                    self._origin_unverified = True
                    return self._apply_status(reply)
                remaining = deadline - self._clock()
                if remaining <= 0:
                    break
                self._drain_until_ready(min(delay, remaining))
                delay = min(delay * 2, CONNECT_BACKOFF_MAX_S)
        self._connect_error = f"{budget:g}s 동안 status 시도 {attempts}회 무응답"
        raise MotionTimeout(f"모션 MCU 연결 확인 실패: {self._connect_error} ({last_error})")

    def note_link_down(self, reason: str) -> None:
        """전송 계층이 포트를 잃었다(EIO·포트 사라짐, 2026-10-14). 다시 연결을 확인하기 전까지 준비 안 됨으로 두고,
        이번 실행 안의 자동 재홈·재누름 차단(``_reset_mid_run``)을 건다 — 재부팅·통신 오류와 같은 규칙."""
        with self._state_lock:
            self._state = MotionState.UNKNOWN
        self._connect_error = f"모션 포트 연결 끊김 — 다시 여는 중({reason})"
        self._reset_mid_run = True
        self._link_dropped = True
        self._origin_unverified = True
        self._reset_encoder_evidence(keep_reference=False)
        self._emit("link_down", {"detail": reason})

    @property
    def needs_reconnect(self) -> bool:
        """포트를 잃은 뒤 연결 확인을 아직 못 했다."""
        return self._link_dropped

    def link_not_ready_reason(self) -> str | None:
        """연결 확인(status 성공) 전이면 사람이 읽을 이유, 아니면 None. 개발자 조작(원점 잡기 포함)이 쓴다 — 원점이 없거나
        정지·알람 뒤라도 사람이 원점을 다시 잡을 수 있어야 한다."""
        with self._state_lock:
            if self._state is not MotionState.UNKNOWN:
                return None
        error = self._connect_error
        return f"모션 MCU 연결 확인 전({error})" if error else "모션 MCU 연결 확인 전"

    def not_ready_reason(self) -> str | None:
        """새 실행이 누르기 전에 볼 준비 이유(act_main readiness), 준비됐으면 None.

        연결 확인 전(``link_not_ready_reason``)에 더해 2026-10-19부터 ``press``가 어차피 거절할 상태를 미리 알린다 —
        ALARM, STOPPED(지난 실행의 정지로 위치를 믿을 수 없음)·UNHOMED는 자동 원점이 꺼져 있을 때만. 자동 원점이 켜져 있으면
        새 실행(``reset_stop`` 뒤)의 첫 누름이 원점부터 잡는다(``press``). 예전에는 STOPPED여도 준비됐다고 해 실행을 받고
        누를 때마다 ``motion_not_ready``로 실패했다."""
        link = self.link_not_ready_reason()
        if link is not None:
            return link
        state = self.state
        if state is MotionState.ALARM:
            return "누름 장치에 이상 신호(알람)가 있어 멈춰 있어요. 장치를 확인하고 원점을 다시 잡아야 해요."
        if self._config.auto_home:
            return None
        if state is MotionState.STOPPED:
            return "누름 장치가 멈춘 뒤라 위치를 믿을 수 없어요. 원점을 다시 잡아야 해요."
        if state is MotionState.UNHOMED:
            if self._origin_unverified and self.last_status is not None and self.last_status.homed:
                return "실행기가 다시 시작했거나 누름 장치와 다시 연결돼 위치를 믿을 수 없어요. 원점을 다시 잡아야 해요."
            return "누름 장치의 위치 기준이 없어요. 원점을 다시 잡아야 해요."
        return None

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
            # 정지로 끊긴 뒤에는 MCU가 homed라고 해도 재홈 전까지 믿지 않는다. 실행기 시작·포트 재연결 뒤 이 프로세스가
            # 원점을 잡기 전에도 같다(``_origin_unverified``, 2026-10-19).
            trusted = status.homed and not self._origin_unverified
            self._set_state(MotionState.READY if trusted else MotionState.UNHOMED)
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
            if not self._set_ready_unless_stopped():
                raise MotionStopped("원점 복귀 직후 정지 요청 — 재홈 필요")
            self._reset_mid_run = False
            self._origin_unverified = False
        # 원점 복귀가 카운트를 0으로 되돌린 것은 엔코더 생존 근거가 아니다(G11) — 기준부터 다시 잡는다.
        self._reset_encoder_evidence(keep_reference=False)

    def move_to(self, x_mm: float, y_mm: float) -> None:
        """절대 좌표(mm)로 이동. 소프트 리밋·기구 값·홈 확인을 **보내기 전에** 한다."""
        request = self._move_request(x_mm, y_mm)
        self._config.require("XY 이동", ("move_timeout_s",))
        self._refuse_if_stopped("XY 이동")
        self._require_homed("XY 이동")
        with self._op_lock:
            self._run_busy(request, self._config.move_timeout_s)

    def jog_to(self, x_mm: float, y_mm: float) -> bool:
        """개발자 위치 탐색용 이동. 시험대 MCU의 부분 이동은 실제 좌표를 유지한다.

        일반 실행의 move_to/press는 부분 이동을 성공으로 취급하지 않는다.
        """
        request = self._move_request(x_mm, y_mm)
        self._config.require("개발자 XY 조그", ("move_timeout_s",))
        self._refuse_if_stopped("개발자 XY 조그")
        self._require_homed("개발자 XY 조그")
        with self._op_lock:
            reply = self._run_busy(request, self._config.move_timeout_s, allow_partial=True)
        return reply.get("reached") is not False

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
                raise MotionNotReady(
                    f"'{command.button}' 누름: 이번 실행 중 MCU 재시작 또는 통신 오류가 발생했습니다 — 자동 재홈·재누름 없이 멈춤"
                    "(사람이 확인한 뒤 새로 요청)"
                )
            # STOPPED(2026-10-19): 맨 위 ``_refuse_if_stopped``를 지났다 = 정지 표시가 지워졌다 = 정지된 그 실행이 아니라
            # 새로 승인된 다음 실행(``reset_stop`` 뒤)이다. 이 실행 안의 MCU 재시작·통신 오류(``_reset_mid_run``)는 위에서 막혔다.
            if self._config.auto_home and self.state in (MotionState.UNHOMED, MotionState.UNKNOWN,
                                                         MotionState.STOPPED):
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

    def request_stop(self) -> bool:
        """다른 스레드에서 즉시 정지 명령을 보낸다. 진행 중 명령의 반환을 기다리지 않는다.

        보낸 것은 '명령 전송'까지다. MCU의 정지 응답은 `wait_stop_ack`·`confirm_stop`이 따로 확인하고(2026-10-13),
        물리 정지는 실물로 재야 한다(docs/하드웨어-연결-설계.md §2·§5).
        돌려주는 값은 정지 줄을 전송 계층에 썼는지(2026-10-10, 개발자 정지 확인용) — 종전 호출자는 무시한다.
        """
        self._stop.set()
        sent = True
        record: _StopRecord | None = None
        try:
            with self._write_lock:
                self._next_id += 1
                # 응답이 쓰기보다 먼저 읽힐 수 있다 — 쓰기 전에 남긴다.
                record = _StopRecord(stop_id=self._next_id, sent_ns=time.monotonic_ns())
                with self._state_lock:
                    self._last_stop = record
                    self._stops[record.stop_id] = record
                    while len(self._stops) > _STOP_RECORDS_KEPT:
                        del self._stops[next(iter(self._stops))]
                self._transport.write_line(json.dumps({"id": self._next_id, "cmd": "stop"}))
        except Exception:  # noqa: BLE001 - 정지 경로에서 호출자를 죽이지 않는다
            sent = False
            if record is not None:
                with self._state_lock:
                    record.sent = False
            log.exception("motion stop send failed — physical E-STOP is the final authority")
        if self.state is MotionState.BUSY:
            self._set_state(MotionState.STOPPED)
        return sent

    # ── 정지 확인(2026-10-13) ────────────────────────────────────────────────

    @property
    def last_stop(self) -> StopReport | None:
        """마지막 정지의 지금 확인 단계(보낸 적 없으면 None). 읽기만 한다."""
        return self._stop_report()

    @property
    def last_stop_id(self) -> int | None:
        """마지막으로 보낸(보내려 한) 정지의 MCU 요청 id. 보낸 적 없으면 None.

        정지를 보내는 쪽이 보내기 직전·직후에 읽어 **그 정지의 불변 id**를 얻고 ``confirm_stop(stop_id=…)``에
        넘긴다(2차 평가 M-N2) — 확인하는 사이 다른 정지가 나가도 그 기록으로 바꿔 답하지 않는다."""
        with self._state_lock:
            return self._last_stop.stop_id if self._last_stop is not None else None

    def wait_stop_ack(self, timeout_s: float = STOP_ACK_TIMEOUT_S, *, stop_id: int | None = None) -> StopReport:
        """정지의 MCU 응답을 ``timeout_s`` 안에서 기다린다. 기한이 지나면 그때의 단계(``sent``)를 돌려준다.

        ``stop_id``를 주면 그 정지의 기록만 본다(없으면 마지막 정지 — 종전). 진행 중 요청이 op 잠금을 쥐고 있으면
        그 읽기 루프가 응답을 기록하므로 기록만 다시 본다. 잠금이 비면 직접 줄을 읽는다(사건 줄은 기존처럼 처리하고,
        모르는 id의 늦은 응답은 버린다). 정지 자체는 이미 나갔다."""
        deadline = time.monotonic() + max(timeout_s, 0.0)
        while True:
            report = self._stop_report(stop_id)
            if report is None:
                if stop_id is not None:
                    return StopReport(stop_id=stop_id, sent=False, level=None,
                                      detail="이 정지의 기록이 남아 있지 않아요")
                return StopReport(stop_id=None, sent=False, level=None, detail="보낸 정지가 없어요")
            if report.level != STOP_SENT:
                return report
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return report
            if self._op_lock.acquire(timeout=min(self._poll_s, remaining)):
                try:
                    self._read_for_stop_ack(deadline, report.stop_id)
                finally:
                    self._op_lock.release()
                final = self._stop_report(report.stop_id)
                return final if final is not None else report

    def confirm_stop(
        self,
        ack_timeout_s: float = STOP_ACK_TIMEOUT_S,
        *,
        verify: bool = True,
        verify_interval_s: float = STOP_VERIFY_INTERVAL_S,
        verify_deadline_s: float = STOP_VERIFY_DEADLINE_S,
        stop_id: int | None = None,
    ) -> StopReport:
        """MCU 응답을 기다리고(`wait_stop_ack`), 받았으면 status 두 번으로 멈춤을 확인한다(``verified``).

        엔코더가 달라졌거나 위치를 알려 주지 않으면 ``mcu_ack``로 남기고 ``detail``에 이유를 쓴다.
        ``stop_id``(정지를 보낼 때 얻은 `last_stop_id`)를 주면 처음부터 끝까지 **그 정지의 기록만** 돌려준다 —
        확인하는 사이 다른 정지가 나가도 그 최신 기록으로 바꾸지 않는다(2차 평가 M-N2). 없으면 이 호출이 처음 본
        마지막 정지에 묶는다."""
        report = self.wait_stop_ack(ack_timeout_s, stop_id=stop_id)
        status_timeout = self._config.status_timeout_s
        if not verify or report.level != STOP_MCU_ACK or status_timeout is None:
            return report
        detail = self._verify_still(report.stop_id, verify_interval_s, status_timeout, verify_deadline_s)
        if detail is not None:
            with self._state_lock:
                record = self._stops.get(report.stop_id) if report.stop_id is not None else None
                if record is not None:
                    record.detail = detail
        final = self._stop_report(report.stop_id)
        return final if final is not None else report

    def _verify_still(self, stop_id: int | None, interval_s: float, status_timeout: float,
                      deadline_s: float = STOP_VERIFY_DEADLINE_S) -> str | None:
        """status를 ``interval_s``마다 물어 a·b가 **두 번 연속 같으면** 기록을 ``verified``로 올리고 None,
        ``deadline_s`` 안에 못 보면 사람이 읽을 이유. 이동 중 정지는 정지 응답 뒤에도 잠깐 관성으로 돈다(10/13 실물).

        같은 값 두 번은 **죽은 엔코더**(선 빠짐 — 늘 같은 값)와 구별되지 않는다(10/13 발견, 2026-10-15 G11). 그래서 이번
        실행에 이동을 명령한 축마다 엔코더 값이 바뀐 것을 본 경우에만 ``verified``로 올리고(정지 뒤 관성으로 바뀐 것도
        근거다), 아니면 `ENCODER_UNPROVEN_DETAIL`을 돌려준다(``mcu_ack``에 머문다). 이번 실행에 이동 명령이 없었던
        쉬는 중 정지는 확인할 움직임이 없어 ``verified``가 아니다."""
        if not self._op_lock.acquire(timeout=status_timeout):
            return "다른 명령이 끝나지 않아 멈춤을 확인하지 못했어요"
        try:
            deadline = self._clock() + max(deadline_s, 0.0)
            first = second = self._apply_status(self._request(
                {"cmd": "status"}, status_timeout, allow_when_stopped=True, stop_on_timeout=False))
            settled = False
            while True:
                time.sleep(max(interval_s, 0.0))
                prev, second = second, self._apply_status(self._request(
                    {"cmd": "status"}, status_timeout, allow_when_stopped=True, stop_on_timeout=False))
                if None in (prev.a_counts, prev.b_counts, second.a_counts, second.b_counts):
                    return "모션 보드가 위치를 알려 주지 않아 멈춤을 확인하지 못했어요"
                if (prev.a_counts, prev.b_counts) == (second.a_counts, second.b_counts):
                    settled = True
                    break
                if self._clock() >= deadline:
                    break
        except MotionError as exc:
            return f"멈춤 확인 중 오류: {exc}"
        finally:
            self._op_lock.release()
        if not settled:
            return (f"정지 뒤 {deadline_s:g}s 동안 엔코더가 움직였어요(a {first.a_counts}→{second.a_counts}, "
                    f"b {first.b_counts}→{second.b_counts})")
        if not self._encoders_proven():
            return ENCODER_UNPROVEN_DETAIL
        with self._state_lock:
            record = self._stops.get(stop_id) if stop_id is not None else None
            if record is not None:
                record.verified = True
        self._emit("stop_verified", {"id": stop_id, "a": second.a_counts, "b": second.b_counts})
        return None

    def _stop_report(self, stop_id: int | None = None) -> StopReport | None:
        """``stop_id`` 정지의 지금 단계(없으면 마지막 정지). 기록이 없으면 None — 다른 정지의 기록으로 대신하지 않는다."""
        with self._state_lock:
            record = self._last_stop if stop_id is None else self._stops.get(stop_id)
            if record is None:
                return None
            stop_id, sent, acked_ns, verified, detail = (
                record.stop_id, record.sent, record.acked_ns, record.verified, record.detail)
            sent_ns = record.sent_ns
        ack_ms = None if acked_ns is None else max(0, round((acked_ns - sent_ns) / 1_000_000))
        if not sent:
            level = None
        elif verified:
            level = STOP_VERIFIED
        elif acked_ns is not None:
            level = STOP_MCU_ACK
        else:
            level = STOP_SENT
        return StopReport(stop_id=stop_id, sent=sent, level=level, ack_ms=ack_ms, detail=detail)

    def _note_stop_ack(self, doc: dict) -> bool:
        """최근 정지 중 하나의 응답이면 **그 정지의 기록에** 받은 시각을 남기고 True(2차 평가 M-N2 — 옛 정지의 늦은
        응답이 새 정지를 확인하지는 않는다). 실패 응답(``ok:false``)은 확인이 아니다."""
        request_id = doc.get("id")
        now = time.monotonic_ns()
        with self._state_lock:
            record = self._stops.get(request_id) if isinstance(request_id, int) else None
            if record is None or record.acked_ns is not None:
                return False
            if doc.get("ok") is not True:
                error = doc.get("error") if isinstance(doc.get("error"), str) else "unknown"
                record.detail = f"모션 보드가 정지에 실패로 답했어요({error})"
                ack_ms = None
            else:
                record.acked_ns = now
                ack_ms = max(0, round((now - record.sent_ns) / 1_000_000))
        if ack_ms is not None:
            self._emit("stop_ack", {"id": request_id, "ack_ms": ack_ms})
        return True

    def _read_for_stop_ack(self, deadline: float, stop_id: int | None = None) -> None:
        """op 잠금을 쥔 채 ``stop_id`` 정지(없으면 마지막 정지)의 응답이 올 때까지(또는 기한까지) 줄을 읽는다.
        예외를 내지 않는다."""
        while True:
            report = self._stop_report(stop_id)
            if report is None or report.level != STOP_SENT:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                line = self._transport.read_line(min(self._poll_s, remaining))
            except Exception:  # noqa: BLE001 - 정지 확인이 읽기 오류로 호출자를 죽이지 않는다
                log.exception("motion: reading the stop reply failed")
                return
            if line is None:
                continue
            doc = _parse_line(line)
            if doc is None:
                log.debug("motion: ignored unparsable line while waiting for stop reply: %.120s", line)
                continue
            if "event" in doc:
                self._note_position(doc, "mcu_event")
                name = str(doc.get("event"))
                if name == "ready":
                    self._note_ready(doc)
                    continue
                self._emit(name, doc)
                if name == "alarm":
                    self._set_state(MotionState.ALARM)
                continue
            self._note_stop_ack(doc)  # 다른 id는 시간 초과로 버린 요청의 늦은 응답·heartbeat 응답 — 버린다

    def reset_stop(self) -> None:
        """다음 실행을 위해 정지 요청 표시를 지운다. STOPPED 상태(재홈 필요)는 남는다.

        엔코더 생존 근거도 새 실행 것으로 비운다(G11) — 지난 실행 뒤 엔코더 선이 빠졌을 수 있다."""
        self._stop.clear()
        self._reset_mid_run = False
        self._reset_encoder_evidence(keep_reference=True)

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
        if self.z_mode == "switchbot":
            return {"cmd": "press", "mode": "switchbot"}
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
            raise MotionNotReady(
                f"{operation}: 원점 복귀가 확인되지 않았습니다(상태 {self.state.value}) — 홈 먼저"
            )

    def _run_busy(self, request: dict, timeout_s: float | None, *, allow_partial: bool = False) -> dict:
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
        except MotionPressFailed:
            # Bot 실패·응답 불명은 같은 실행에서 재누름하지 않지만 CoreXY 위치 자체는 그대로다.
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
        if request.get("cmd") == "move" and reply.get("reached") is False and not allow_partial:
            self._set_state(MotionState.UNHOMED)
            raise MotionPositionMismatch("목표에 도착하지 못했습니다 — 누름을 차단하고 위치 재확인이 필요합니다")
        if request.get("cmd") == "move" and reply.get("reached") is not False:
            mismatch = self._position_mismatch(request, seq_before)
            if mismatch is not None:
                self._set_state(MotionState.UNHOMED)
                self._emit("position_mismatch", {"detail": mismatch})
                raise MotionPositionMismatch(f"이동 뒤 위치 불일치: {mismatch} — 재홈 필요")
        if not self._set_ready_unless_stopped():
            raise MotionStopped(f"'{request.get('cmd')}' 직후 정지 요청 — 재홈 필요")
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
                # 정지 응답이면 확인 시각을 남긴다(2026-10-13). 나머지는 시간 초과로 버린 요청의 늦은 응답·
                # heartbeat(ping) 응답 — 어느 쪽도 이 요청의 응답이 아니다.
                self._note_stop_ack(doc)
                continue
            if doc.get("ok") is True:
                self._note_position(doc, "mcu_reply")
                # read_line에서 기다리는 동안 /stop이 왔으면 늦게 도착한 ok도 성공으로 받지 않는다(검토 10/19) —
                # 정지된 동작이라 위치를 믿을 수 없고 재홈이 필요하다.
                if self._stop.is_set() and not allow_when_stopped:
                    raise MotionStopped(f"'{body['cmd']}' 응답 전에 정지 요청이 와 성공으로 받지 않음")
                return doc
            error = doc.get("error") if isinstance(doc.get("error"), str) else "unknown"
            press_outcome = doc.get("press_outcome")
            if body.get("cmd") == "press" and press_outcome in {"not_pressed", "unknown"}:
                raise MotionPressFailed(
                    f"MCU가 누름 실패를 보고: {error} ({press_outcome})",
                    reason=error,
                    press_outcome=press_outcome,
                )
            if error in MCU_REFUSAL_ERRORS:
                raise MotionRefused(f"MCU가 '{body['cmd']}'를 거절: {error}", code=error,
                                    retry_ms=_opt_int(doc.get("retry_ms")))
            raise MotionAlarm(f"MCU가 '{body['cmd']}'를 거절/실패 보고: {error}", reason=error)

    def _send_request(self, body: dict) -> int:
        with self._write_lock:
            # G4: 동작 잠금/쓰기 잠금을 기다리는 동안 도착한 정지도 실제 쓰기 직전에 본다.
            # stop과 같은 쓰기 잠금 안이므로 정지 줄 뒤에 옛 동작 줄이 붙지 않는다.
            # status/limits는 정지 확인에 필요하므로 계속 허용한다.
            if body.get("cmd") in {"home", "move", "press"} and self._stop.is_set():
                raise MotionStopped(f"'{body['cmd']}' 전송 전 정지 요청으로 중단됨")
            if body.get("cmd") == "move":
                self._note_commanded_move(body)
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
        # MCU가 다시 켜져 카운트가 처음부터다 — 그 변화는 엔코더 생존 근거가 아니다(G11).
        self._reset_encoder_evidence(keep_reference=False)

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
                continue
            # 응답 줄은 이전 시도의 늦은 응답 — 버린다(정지 응답이면 확인 시각만 남긴다).
            self._note_stop_ack(doc)

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
            raise MotionAlarm(f"MCU 알람: {reason}", reason=reason)

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
