"""Host adapter for the received, unchanged Touch Bridge v2 USB protocol.

The MCU owns CoreXY/PID and consumes millimetres. One reader routes commandId
events, so status and stop never read and discard another operation's output.
This module does not upload or change firmware or insert automatic homing.
"""

from __future__ import annotations

import json
import math
import os
import queue
import re
import threading
import time
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field

from .models import ExecutionMode, PressCommand
from .ports import GrblClient
from .serial_motion import (
    LineTransport, MotionAlarm, MotionConfigError, MotionError, MotionNotReady,
    MotionPositionMismatch, MotionPressFailed, MotionRefused, MotionReset,
    MotionState, MotionStatus, MotionStopped, MotionTimeout, StopReport,
)

PROTOCOL = "touchbridge-v2"
_TOKEN = re.compile(r"[A-Fa-f0-9]{16}")


@dataclass(frozen=True)
class TouchBridgeConfig:
    status_timeout_s: float = 1.0
    connect_timeout_s: float = 5.0
    home_timeout_s: float = 80.0
    move_timeout_s: float = 30.0
    press_timeout_s: float = 10.0
    tolerance_mm: float = 0.7  # received sketch's toleranceMm default
    retry_xy_offsets_mm: tuple[tuple[float, float], ...] | None = None
    auto_home: bool = False
    press_mode: str = "switchbot"

    def __post_init__(self) -> None:
        for name in ("status_timeout_s", "connect_timeout_s", "home_timeout_s",
                     "move_timeout_s", "press_timeout_s", "tolerance_mm"):
            value = getattr(self, name)
            if isinstance(value, bool) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be finite and positive")
        if self.retry_xy_offsets_mm is not None:
            for pair in self.retry_xy_offsets_mm:
                if len(pair) != 2 or not all(_number(v) for v in pair):
                    raise ValueError("retry offsets must be finite XY pairs")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> TouchBridgeConfig:
        source = os.environ if env is None else env
        values = {}
        for name in ("status_timeout_s", "connect_timeout_s", "home_timeout_s",
                     "move_timeout_s", "press_timeout_s"):
            raw = source.get("SIMPLELAY_MOTION_" + name.upper(), "").strip()
            if raw:
                values[name] = float(raw)
        raw = source.get("SIMPLELAY_TOUCHBRIDGE_TOLERANCE_MM", "").strip()
        if raw:
            values["tolerance_mm"] = float(raw)
        raw = source.get("SIMPLELAY_MOTION_RETRY_XY_OFFSETS_MM", "").strip()
        if raw:
            values["retry_xy_offsets_mm"] = tuple(
                tuple(float(v) for v in pair.split(",")) for pair in raw.split(";") if pair.strip()
            )
        return cls(**values)

    def missing_for_press(self, z_mode: str | None = None) -> tuple[str, ...]:
        return ()  # no host counts/mm or solenoid duration configuration


@dataclass
class _Pending:
    action: str
    replies: queue.Queue = field(default_factory=queue.Queue)


@dataclass
class _Stop:
    wire_id: str
    sent_at: float
    event: threading.Event = field(default_factory=threading.Event)
    sent: bool = False
    ack_at: float | None = None


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


class TouchBridgeMotionClient(GrblClient):
    execution_mode = ExecutionMode.REAL
    motion_protocol = PROTOCOL
    z_mode = "switchbot"

    def __init__(self, transport: LineTransport, config: TouchBridgeConfig | None = None, *,
                 on_event: Callable[[str, dict], None] | None = None,
                 on_unclaimed_line: Callable[[str], None] | None = None) -> None:
        self._transport = transport
        self.config = config or TouchBridgeConfig()
        self._on_event = on_event
        self._on_unclaimed = on_unclaimed_line
        self._lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._op_lock = threading.RLock()
        self._shutdown = threading.Event()
        self._stopped = threading.Event()
        self._prefix = uuid.uuid4().hex[:12]
        self._next = 0
        self._pending: dict[str, _Pending] = {}
        self._stops: dict[int, _Stop] = {}
        self._last_stop_id: int | None = None
        self._state = MotionState.UNKNOWN
        self._homed = False
        self._connected = False
        self._needs_reconnect = False
        self._motion_active = False
        self._token: str | None = None
        self._position: dict | None = None
        self._position_seq = 0
        self._rx_seq = 0
        self.last_status: MotionStatus | None = None
        self.ready_info: dict = {"protocol": PROTOCOL}
        self._reader = threading.Thread(target=self._read_loop, daemon=True, name="touchbridge-reader")
        self._reader.start()

    @property
    def state(self) -> MotionState:
        with self._lock:
            return self._state

    @property
    def homed(self) -> bool:
        with self._lock:
            return self._homed

    @property
    def last_position(self) -> dict | None:
        with self._lock:
            return dict(self._position) if self._position is not None else None

    @property
    def needs_reconnect(self) -> bool:
        with self._lock:
            return self._needs_reconnect

    def link_not_ready_reason(self) -> str | None:
        with self._lock:
            return None if self._connected else "모션 보드 연결을 확인하지 못했어요"

    def not_ready_reason(self) -> str | None:
        reason = self.link_not_ready_reason()
        if reason:
            return reason
        if not self.homed:
            return "누름 장치의 좌표 기준이 아직 설정되지 않았어요"
        if self._stopped.is_set():
            return "누름 장치의 중단 요청이 남아 있어요"
        return None

    def _allocate(self) -> tuple[int, str]:
        with self._lock:
            self._next += 1
            return self._next, f"sl-{self._prefix}-{self._next}"

    def _encode(self, wire_id: str, action: str, fields: dict) -> str:
        line = json.dumps({"version": 2, "commandId": wire_id, "action": action, **fields},
                          ensure_ascii=True, allow_nan=False, separators=(",", ":"))
        if len(line.encode("utf-8")) > 255:
            raise MotionRefused("Touch Bridge 명령이 255바이트를 넘어요", code="command_too_long")
        return line

    def _exchange(self, action: str, timeout: float, **fields) -> dict:
        _, wire_id = self._allocate()
        line = self._encode(wire_id, action, fields)
        pending = _Pending(action)
        with self._lock:
            self._pending[wire_id] = pending
        aggregate: dict = {}
        deadline = time.monotonic() + timeout
        try:
            with self._write_lock:
                if action not in ("status", "home") and self._stopped.is_set():
                    raise MotionStopped("전송 전에 중단 요청이 왔어요")
                self._transport.write_line(line)
            while True:
                if action != "status" and self._stopped.is_set():
                    raise MotionStopped("중단 요청으로 동작을 끝냈어요")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    if action != "status":
                        self.request_stop()
                    raise MotionTimeout(f"Touch Bridge {action}: 응답 기한 {timeout:g}s 초과")
                try:
                    reply = pending.replies.get(timeout=min(remaining, 0.05))
                except queue.Empty:
                    continue
                if isinstance(reply, BaseException):
                    raise reply
                state = reply.get("state")
                if isinstance(state, str) and state.startswith("ERROR_"):
                    self._raise_error(action, reply)
                if state == "STOPPED":
                    raise MotionStopped("모션 보드가 중단을 보고했어요")
                aggregate.update(reply)
                if state == "POSITIONED":
                    aggregate["positioned"] = True
                    aggregate["position_seq"] = reply["_rx_seq"]
                if state == "COMPLETED":
                    if action != "status" and self._stopped.is_set():
                        raise MotionStopped("완료 응답 전에 중단 요청이 왔어요")
                    return aggregate
        except OSError as exc:
            self.note_link_down(str(exc))
            raise
        finally:
            with self._lock:
                self._pending.pop(wire_id, None)

    def _raise_error(self, action: str, reply: dict) -> None:
        state, message = reply["state"], reply.get("message", "")
        if action == "press":
            # The received sketch does not expose line-json press_outcome.
            # Only invalid-token/BUSY proves rejection before a Bot request.
            known_rejection = state == "ERROR_INVALID_TOKEN" or message == "BUSY"
            raise MotionPressFailed(f"Touch Bridge {state}: {message}", reason=state,
                                    press_outcome="not_pressed" if known_rejection else "unknown")
        if state == "ERROR_NOT_HOMED":
            with self._lock:
                self._homed = False
            raise MotionNotReady("모션 보드의 좌표 기준이 없어요", code="not_homed")
        if state == "ERROR_LIMIT" or message == "BUSY":
            raise MotionRefused(f"Touch Bridge {state}: {message}",
                                code="busy" if message == "BUSY" else "soft_limit")
        raise MotionAlarm(f"Touch Bridge {state}: {message}", reason=state)

    def _read_loop(self) -> None:
        while not self._shutdown.is_set():
            try:
                line = self._transport.read_line(0.1)
            except (OSError, RuntimeError) as exc:
                if not self._shutdown.is_set():
                    self.note_link_down(str(exc))
                    self._shutdown.wait(0.1)
                continue
            if line is None:
                continue
            try:
                doc = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                doc = None
            if not isinstance(doc, dict) or doc.get("version") != 2:
                if "Touch Bridge CoreXY" in line and "ready" in line:
                    self._booted()
                elif line.startswith("FAULT "):
                    self._fail_pending(MotionAlarm(line, reason="firmware_fault"), motions_only=True)
                self._emit("mcu_text", {"line": line})
                if self._on_unclaimed is not None:
                    self._callback(self._on_unclaimed, line)
                continue
            wire_id = doc.get("commandId")
            with self._lock:
                self._rx_seq += 1
                doc["_rx_seq"] = self._rx_seq
                for stop in self._stops.values():
                    if stop.wire_id == wire_id and doc.get("state") == "STOPPED":
                        if stop.ack_at is None:
                            stop.ack_at = time.monotonic()
                        stop.event.set()
                        break
                pending = self._pending.get(wire_id) if isinstance(wire_id, str) else None
                if pending is not None:
                    pending.replies.put(doc)
            self._emit("touchbridge_state", doc)
            if pending is None and self._on_unclaimed is not None:
                self._callback(self._on_unclaimed, line)

    @staticmethod
    def _callback(fn, *args) -> None:
        try:
            fn(*args)
        except Exception:
            pass  # a diagnostic sink must not kill the only serial reader

    def _emit(self, name: str, fields: dict) -> None:
        if self._on_event is not None:
            self._callback(self._on_event, name, dict(fields))

    def _fail_pending(self, exc: BaseException, *, motions_only: bool = False) -> None:
        with self._lock:
            self._token = None
            for pending in self._pending.values():
                if not motions_only or pending.action != "status":
                    pending.replies.put(exc)

    def _booted(self) -> None:
        with self._lock:
            self._connected = False
            self._homed = False
            self._position = None
            self._state = MotionState.UNKNOWN
            self._needs_reconnect = True
            self.ready_info["fw"] = "Touch Bridge CoreXY"
        self._fail_pending(MotionReset("모션 보드가 다시 켜졌어요"), motions_only=True)

    def note_link_down(self, reason: str) -> None:
        with self._lock:
            self._connected = False
            self._homed = False
            self._position = None
            self._state = MotionState.UNKNOWN
            self._needs_reconnect = True
        self._fail_pending(OSError(f"Touch Bridge 연결 끊김: {reason}"))

    def connect(self) -> MotionStatus:
        deadline = time.monotonic() + self.config.connect_timeout_s
        while True:
            try:
                return self._status(min(self.config.status_timeout_s, max(0.001, deadline - time.monotonic())))
            except (MotionTimeout, OSError):
                if time.monotonic() >= deadline or self._shutdown.is_set():
                    raise
                self._shutdown.wait(min(0.1, max(0, deadline - time.monotonic())))

    def _status(self, timeout: float) -> MotionStatus:
        reply = self._exchange("status", timeout)
        pos, homed = reply.get("position"), reply.get("homed")
        if not isinstance(pos, dict) or type(homed) is not bool or not all(
                _number(pos.get(axis)) for axis in ("xMm", "yMm")):
            raise MotionError("Touch Bridge status에 유효한 좌표·기준 상태가 없어요")
        with self._lock:
            self._connected = True
            self._needs_reconnect = False
            self._homed = homed
            if reply["_rx_seq"] >= self._position_seq:
                self._position_seq = reply["_rx_seq"]
                self._position = {"x_mm": pos["xMm"], "y_mm": pos["yMm"]}
            if not self._motion_active:
                self._state = MotionState.STOPPED if self._stopped.is_set() else (
                    MotionState.READY if homed else MotionState.UNHOMED)
            status = MotionStatus(self._state.value, homed, None, None, None, None)
            self.last_status = status
            return status

    def status(self) -> MotionStatus:
        return self._status(self.config.status_timeout_s)

    def position_xy(self, status: MotionStatus | None = None) -> tuple[float, float] | None:
        pos = self.last_position
        return (pos["x_mm"], pos["y_mm"]) if pos is not None else None

    def home(self) -> None:
        with self._op_lock:
            self._physical("home", self.config.home_timeout_s)
            self.status()

    def _physical(self, action: str, timeout: float, **fields) -> dict:
        with self._lock:
            self._motion_active = True
            self._token = None
            self._state = MotionState.BUSY
        try:
            return self._exchange(action, timeout, **fields)
        except MotionRefused:
            raise
        except BaseException:
            with self._lock:
                self._token = None
            raise
        finally:
            with self._lock:
                self._motion_active = False
                self._state = (MotionState.UNKNOWN if not self._connected else
                               MotionState.STOPPED if self._stopped.is_set() else
                               MotionState.READY if self._homed else MotionState.UNHOMED)

    def _move(self, x_mm: float, y_mm: float) -> None:
        if not all(_number(v) for v in (x_mm, y_mm)):
            raise MotionRefused("목표는 유한한 XY 좌표여야 해요", code="bad_args")
        reply = self._physical("move_only", self.config.move_timeout_s,
                               target={"xMm": x_mm, "yMm": y_mm}, toleranceMm=self.config.tolerance_mm)
        pos, token = reply.get("position"), reply.get("positionToken")
        if not reply.get("positioned") or not isinstance(token, str) or not _TOKEN.fullmatch(token) or not (
                isinstance(pos, dict) and all(_number(pos.get(a)) for a in ("xMm", "yMm"))):
            raise MotionPositionMismatch("도착 좌표와 이번 이동의 위치 토큰을 확인하지 못했어요")
        if math.hypot(pos["xMm"] - x_mm, pos["yMm"] - y_mm) > self.config.tolerance_mm + 0.015:
            raise MotionPositionMismatch("보고 위치가 목표의 허용 오차를 넘었어요")
        with self._lock:
            if self._stopped.is_set():
                raise MotionStopped("도착할 때 중단 요청이 왔어요")
            if reply["position_seq"] >= self._position_seq:
                self._position_seq = reply["position_seq"]
                self._position = {"x_mm": pos["xMm"], "y_mm": pos["yMm"]}
            self._token = token

    def move_to(self, x_mm: float, y_mm: float) -> None:
        with self._op_lock:
            self._move(x_mm, y_mm)

    def press_with_observation(self, command: PressCommand, before_press: Callable[[], None]) -> None:
        self.press(command, before_press=before_press)

    def press(self, command: PressCommand, *, before_press: Callable[[], None] | None = None) -> None:
        if not command.has_coordinates:
            raise MotionNotReady("버튼의 보정 좌표가 없어요", code="coordinates_missing")
        x, y = command.x_mm, command.y_mm
        correction = command.correction
        if correction is not None and correction.xy_adjustment_required:
            offsets = self.config.retry_xy_offsets_mm
            if offsets is None:
                raise MotionConfigError("XY 보정 재시도", ("retry_xy_offsets_mm",))
            index = correction.retry_number - 1
            if not 0 <= index < len(offsets):
                raise MotionRefused("해당 재시도 좌표가 설정되지 않았어요")
            dx, dy = offsets[index]
            x, y = x + dx, y + dy
        with self._op_lock:
            self._move(x, y)
            if before_press is not None:
                before_press()
            with self._lock:
                token, self._token = self._token, None
            if token is None:
                raise MotionPositionMismatch("이번 이동의 위치 토큰이 없어요")
            self._physical("press", self.config.press_timeout_s, positionToken=token)

    def reset_stop(self) -> None:
        self._stopped.clear()

    @property
    def last_stop_id(self) -> int | None:
        with self._lock:
            return self._last_stop_id

    def request_stop(self) -> bool:
        stop_id, wire_id = self._allocate()
        record = _Stop(wire_id, time.monotonic())
        with self._lock:
            self._stopped.set()
            self._token = None
            self._last_stop_id = stop_id
            self._stops[stop_id] = record
            while len(self._stops) > 16:
                del self._stops[next(iter(self._stops))]
        try:
            with self._write_lock:
                self._transport.write_line(self._encode(wire_id, "stop", {}))
            record.sent = True
        except (OSError, RuntimeError):
            return False
        return True

    def confirm_stop(self, ack_timeout_s: float = 0.3, *, stop_id: int | None = None, **_) -> StopReport:
        with self._lock:
            stop_id = self._last_stop_id if stop_id is None else stop_id
            record = self._stops.get(stop_id)
        if record is None:
            return StopReport(stop_id, False, None)
        record.event.wait(ack_timeout_s)
        ack_ms = round((record.ack_at - record.sent_at) * 1000) if record.ack_at is not None else None
        return StopReport(stop_id, record.sent, "mcu_ack" if ack_ms is not None else "sent" if record.sent else None,
                          ack_ms, "원본 v2 응답에는 물리 정지 검증용 엔코더 정보가 없어요")

    def close(self) -> None:
        self._shutdown.set()
        self._fail_pending(OSError("모션 어댑터를 닫았어요"))
        self._reader.join(timeout=1)
        close = getattr(self._transport, "close", None)
        if callable(close):
            close()
