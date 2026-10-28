"""Touch Bridge firmware simulator over TCP — **a simulation, not the ESP32 and not hardware evidence.**

Lets the RPi4 executor run its real ``touchbridge-v2`` serial adapter end to end with no ESP32
attached: point ``SIMPLELAY_MOTION_PORT`` at ``socket://<host>:<port>`` (pyserial URL).
Only the USB line formats of the HW owner's received sketch (banner "Touch Bridge CoreXY v4")
are imitated; the firmware source stays with its owner and is not copied here. Nothing about
motors, encoders, PID, belts or the SwitchBot radio is simulated beyond timing.

Wire shapes (from the received sketch's handleJson/handleEvent/handleLine):
- JSON v2 in: ``{"version":2,"commandId":..,"action":"home|move_only|press|stop|status"}``.
- JSON v2 out: ``{"version":2,"commandId":"..","state":"RECEIVED|MOVING|POSITIONED|COMPLETED|
  HOMING|HOMED|PRESSING|STOPPED|ERROR_*",...}``. POSITIONED carries position/errorMm and a
  single-use 16-hex ``positionToken``; ``press`` needs it and invalidates it either way.
- Text: ``P``/``$$`` status line, ``STOP``/``S``/``!`` stop, ``?`` help, ``G x y [f]``, ``T [ms]``,
  ``H``, ``GT x y [f]``, ``Z``, ``$H``. A ``!`` byte anywhere stops immediately (like pollSerial).

Timing defaults: speed 50 mm/s and accel 300 mm/s² are the sketch's config defaults; the
resulting move duration (trapezoid + 50 ms settle) is **추측** — the real PID loop differs.
Homing and SwitchBot press durations are **추측** (not measured).
Faults: ``--press-fail CODE``, ``--press-timeout``, ``--stall-on-move N`` (Nth JSON move).

Run: ``python -m rpi.tools.touchbridge_sim --listen 127.0.0.1:7100`` (pure stdlib). Every line
in/out is logged to stdout. One client at a time — a new connection replaces the old one,
like re-opening a serial port; the simulated board keeps its state (no reset) unless
``--reset-on-connect`` is given.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import secrets
import socket
import sys
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime

BANNER = "Touch Bridge CoreXY v4 ready (BLE: {name}, key=none)"
BLE_NAME = "TouchBridge-SIM"
X_MAX_MM = 200.0  # sketch config X_MAX_MM / Y_MAX_MM
Y_MAX_MM = 200.0
COUNTS_PER_MM = 35.0  # sketch config (1400 counts/rev / 40 mm/rev)
DEFAULT_TOLERANCE_MM = 0.7  # sketch's toleranceMm default
LINE_MAX = 255
# SwitchBot result names the sketch reports; CONNECT_FAIL/ACK_TIMEOUT map to ERROR_TIMEOUT.
PRESS_FAIL_CODES = ("BOT_EXEC_ERROR", "BOT_BUSY", "BOT_UNSUPPORTED", "BOT_LOW_BATTERY",
                    "BOT_ENCRYPTED", "BOT_PASSWORD", "CONNECT_FAIL", "NO_SERVICE", "ACK_TIMEOUT",
                    "BOT_STATUS_UNKNOWN")
_TIMEOUT_CODES = {"CONNECT_FAIL", "ACK_TIMEOUT"}
_ID_CHARS = re.compile(r"[^A-Za-z0-9\-_.:]")


def state_line(command_id: str, state: str, **fields) -> str:
    """One v2 state line exactly as the sketch's emitState builds it (version, commandId, state, extras)."""
    return json.dumps({"version": 2, "commandId": command_id, "state": state, **fields},
                      separators=(",", ":"))


def banner(name: str = BLE_NAME) -> str:
    return BANNER.format(name=name)


@dataclass(frozen=True)
class Timing:
    speed_mm_s: float = 50.0     # sketch DEFAULT_SPEED
    accel_mm_s2: float = 300.0   # sketch DEFAULT_ACCEL
    settle_s: float = 0.05       # sketch SETTLE_S
    home_s: float = 3.0          # 추측 — homing without limit switches, not measured
    press_s: float = 1.5         # 추측 — BLE connect + press + reply, not measured
    press_timeout_s: float = 8.0  # sketch BOT_PRESS_TIMEOUT_MS
    stall_after_s: float = 0.5   # sketch STALL_ARM_S + FOLLOW_ERR_TIME_S
    scale: float = 1.0           # multiply every duration (tests use a small value)

    def move_s(self, distance_mm: float) -> float:
        v, a = self.speed_mm_s, self.accel_mm_s2
        if distance_mm <= 0:
            t = 0.0
        elif distance_mm >= v * v / a:
            t = distance_mm / v + v / a
        else:
            t = 2 * math.sqrt(distance_mm / a)
        return t + self.settle_s


@dataclass
class Faults:
    press_fail: str | None = None
    press_timeout: bool = False
    stall_on_move: int | None = None  # 1-based index of JSON move_only commands


@dataclass
class _Step:
    kind: str  # move | home | tap | origin
    org: str  # json | text | gcode
    id: str = ""
    x: float = 0.0
    y: float = 0.0
    tol: float = DEFAULT_TOLERANCE_MM
    started: float = 0.0
    deadline: float = 0.0
    outcome: str = "ok"
    start_xy: tuple[float, float] = (0.0, 0.0)
    extra: dict = field(default_factory=dict)


class TouchBridgeSim:
    """Firmware behaviour model. ``feed`` takes received bytes; ``emit`` receives each output line."""

    def __init__(self, emit: Callable[[str], None], *, timing: Timing | None = None,
                 faults: Faults | None = None, homed: bool = False,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self._emit = emit
        self.timing = timing or Timing()
        self.faults = faults or Faults()
        self._clock = clock
        self._lock = threading.RLock()
        self._wake = threading.Condition(self._lock)
        self._queue: deque[_Step] = deque()
        self._active: _Step | None = None
        self._buffer = bytearray()
        self.homed = homed
        self.xy = (0.0, 0.0)
        self._token: str | None = None
        self._token_xy = (0.0, 0.0, 0.0)
        self._json_moves = 0
        self._closed = False
        self._worker = threading.Thread(target=self._run, daemon=True, name="touchbridge-sim")
        self._worker.start()

    # output
    def _out(self, line: str) -> None:
        self._emit(line)

    def _state(self, command_id: str, state: str, **fields) -> None:
        self._out(state_line(command_id, state, **fields))

    def boot(self, name: str = BLE_NAME) -> None:
        """Power-on/reset: queue and token dropped, unhomed, banner printed."""
        with self._lock:
            self._queue.clear()
            self._active = None
            self._token = None
            self.homed = False
            self._buffer.clear()
            self._out("Z actuator: SwitchBot Bot (simulated)")
            self._out(banner(name))
            self._wake.notify_all()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._wake.notify_all()
        self._worker.join(timeout=1)

    # input
    def feed(self, data: bytes) -> None:
        with self._lock:
            for byte in data:
                if byte == 0x21:  # '!' byte: immediate stop, line buffer discarded (pollSerial)
                    self._emergency_stop()
                    self._buffer.clear()
                elif byte == 0x0D:
                    continue
                elif byte == 0x0A:
                    line = self._buffer.decode("utf-8", errors="replace")
                    self._buffer.clear()
                    self.handle_line(line)
                elif len(self._buffer) < LINE_MAX:
                    self._buffer.append(byte)

    def handle_line(self, line: str) -> None:
        with self._lock:
            line = line.lstrip(" ")
            if not line:
                return
            if line.startswith("{"):
                self._handle_json(line)
            else:
                self._handle_text(line)

    # state helpers
    def busy(self) -> bool:
        return self._active is not None or bool(self._queue)

    def position(self) -> tuple[float, float]:
        step = self._active
        if step is not None and step.kind == "move" and step.deadline > step.started:
            frac = min(1.0, max(0.0, (self._clock() - step.started) / (step.deadline - step.started)))
            if step.outcome == "stall":
                frac *= step.extra.get("stall_frac", 1.0)
            (sx, sy) = step.start_xy
            return (sx + (step.x - sx) * frac, sy + (step.y - sy) * frac)
        return self.xy

    def _status_line(self) -> str:
        x, y = self.position()
        state = ("IDLE" if self._active is None else
                 {"move": "MOVING", "home": "HOMING"}.get(self._active.kind, "IDLE"))  # names 추측
        a, b = round((x + y) * COUNTS_PER_MM), round((x - y) * COUNTS_PER_MM)
        return (f"STATE {state} homed={int(self.homed)} pos=({x:.2f}, {y:.2f}) ref=({x:.2f}, {y:.2f}) "
                f"enc=({a}, {b}) bot={int(self._active is not None and self._active.kind == 'tap')} "
                f"q={len(self._queue) + (self._active is not None)} auth=none")

    def _invalidate_token(self) -> None:
        self._token = None

    def _fail_active(self, json_state: str, text: str, **fields) -> None:
        step = self._active
        if step is not None:
            if step.org == "json":
                self._state(step.id, json_state, **fields)
            elif step.org == "text":
                self._out(f"FAULT {text}")
        self._queue.clear()
        self._active = None
        self._invalidate_token()
        self._wake.notify_all()

    def _emergency_stop(self) -> None:
        step = self._active
        if step is not None and step.kind == "move":
            self.xy = self.position()
        self._queue.clear()
        if step is not None and step.org == "json":
            self._state(step.id, "STOPPED")
        self._active = None
        self._invalidate_token()
        self._wake.notify_all()

    # JSON v2
    def _handle_json(self, line: str) -> None:
        try:
            doc = json.loads(line)
        except ValueError:
            self._out("ERROR:JSON")
            return
        if not isinstance(doc, dict):
            self._out("ERROR:JSON")
            return
        action = doc.get("action") if isinstance(doc.get("action"), str) else ""
        raw_id = doc.get("commandId") if isinstance(doc.get("commandId"), str) else ""
        cid = _ID_CHARS.sub("", raw_id)[:47]
        v2 = doc.get("version") == 2 and bool(cid)

        if action == "stop":
            self._emergency_stop()
            if cid:
                self._state(cid, "STOPPED")
            else:
                self._out("STOPPED")
            return
        if action == "status":
            if v2:
                x, y = self.position()
                self._state(cid, "COMPLETED", homed=self.homed,
                            position={"xMm": round(x, 2), "yMm": round(y, 2)})
            else:
                self._out(self._status_line())
            return
        if action == "home":
            if not v2:
                self._queue.append(_Step("home", "text"))
                self._out("OK")
                self._wake.notify_all()
                return
            if self.busy():
                self._state(cid, "ERROR_PROTOCOL", message="BUSY")
                return
            self._state(cid, "RECEIVED")
            self._queue.append(_Step("home", "json", cid))
            self._wake.notify_all()
            return
        if not v2:
            self._out("ERROR:UNKNOWN_ACTION")
            return
        if action == "move_only":
            target = doc.get("target") if isinstance(doc.get("target"), dict) else {}
            x, y = target.get("xMm"), target.get("yMm")
            if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (x, y)):
                self._state(cid, "ERROR_PROTOCOL")
                return
            tol = doc.get("toleranceMm", DEFAULT_TOLERANCE_MM)
            if not isinstance(tol, (int, float)) or isinstance(tol, bool):
                tol = DEFAULT_TOLERANCE_MM
            if not (math.isfinite(x) and math.isfinite(y)) or x < 0 or y < 0 or not tol > 0:
                self._state(cid, "ERROR_LIMIT")
                return
            if not self.homed:
                self._state(cid, "ERROR_NOT_HOMED")
                return
            if self.busy():
                self._state(cid, "ERROR_PROTOCOL", message="BUSY")
                return
            self._state(cid, "RECEIVED")
            self._json_moves += 1
            step = _Step("move", "json", cid, float(x), float(y), float(tol))
            if self.faults.stall_on_move is not None and self._json_moves == self.faults.stall_on_move:
                step.outcome = "stall"
            self._queue.append(step)
            self._wake.notify_all()
            return
        if action == "press":
            token = doc.get("positionToken") if isinstance(doc.get("positionToken"), str) else ""
            ok = self._token is not None and token == self._token and not self.busy()
            if ok:
                x, y = self.position()
                tx, ty, tol = self._token_xy
                ok = math.hypot(x - tx, y - ty) <= tol
            self._invalidate_token()  # single use: pressing again needs a new move
            if not ok:
                self._state(cid, "ERROR_INVALID_TOKEN")
                return
            self._state(cid, "RECEIVED")
            self._queue.append(_Step("tap", "json", cid))
            self._wake.notify_all()
            return
        self._state(cid, "ERROR_PROTOCOL", message="UNKNOWN_ACTION")

    # text commands
    def _handle_text(self, line: str) -> None:
        word = line.split(" ", 1)[0].upper()
        if word in ("STOP", "S", "!"):
            self._emergency_stop()
            self._out("STOPPED")
            return
        if word in ("P", "$$"):
            self._out(self._status_line())
            return
        if word == "?":
            self._out("HELP (simulated): G x y [f] | GT x y [f] | T [ms] | H | Z | P | STOP")
            return
        if word == "$H":
            self._queue.append(_Step("home", "gcode"))
            self._out("ok")
            self._wake.notify_all()
            return
        if word == "$X":
            self._out("ok")
            return
        nums = []
        for part in line.split()[1:]:
            try:
                nums.append(float(part))
            except ValueError:
                break
        if word == "GT":
            if len(nums) < 2:
                self._out("ERR USAGE: GT x y [f]")
                return
            self._enqueue_text_move(nums[0], nums[1])
            self._queue.append(_Step("tap", "text"))
            self._out("OK")
        elif word == "G":
            if len(nums) < 2:
                self._out("ERR USAGE: G x y [f]")
                return
            self._enqueue_text_move(nums[0], nums[1])
            self._out("OK")
        elif word == "T":
            self._queue.append(_Step("tap", "text"))
            self._out("OK")
        elif word == "H":
            self._queue.append(_Step("home", "text"))
            self._out("OK")
        elif word == "Z":
            self._queue.append(_Step("origin", "text"))
            self._out("OK")
        elif word == "M":
            if self.busy():
                self._out("ERR BUSY")
                return
            self._invalidate_token()
            self._out("OK")  # raw PWM: nothing is simulated
        else:
            self._out("ERR UNKNOWN")
        self._wake.notify_all()

    def _enqueue_text_move(self, x: float, y: float) -> None:
        self._queue.append(_Step("move", "text", "", x, y))

    # worker
    def _run(self) -> None:
        with self._lock:
            while not self._closed:
                step = self._active
                if step is None:
                    if not self._queue:
                        self._wake.wait()
                        continue
                    self._active = self._queue.popleft()
                    self._start(self._active)
                    continue
                remaining = step.deadline - self._clock()
                if remaining > 0:
                    self._wake.wait(remaining)
                    continue
                self._finish(step)

    def _start(self, step: _Step) -> None:
        t, now = self.timing, self._clock()
        step.started = now
        if step.kind == "move":
            self._invalidate_token()
            if step.org == "json":
                self._state(step.id, "MOVING")
            if not (0 <= step.x <= X_MAX_MM and 0 <= step.y <= Y_MAX_MM):
                self._fail_active("ERROR_LIMIT", "OUT_OF_RANGE")  # message text 추측
                return
            step.start_xy = self.xy
            full = t.move_s(math.dist(self.xy, (step.x, step.y))) * t.scale
            if step.outcome == "stall":
                stall = t.stall_after_s * t.scale
                step.extra["stall_frac"] = min(1.0, stall / full) if full > 0 else 0.0
                step.deadline = now + min(stall, full)
            else:
                step.deadline = now + full
        elif step.kind == "home":
            self._invalidate_token()
            if step.org == "json":
                self._state(step.id, "HOMING")
            step.deadline = now + t.home_s * t.scale
        elif step.kind == "tap":
            if step.org == "json":
                self._state(step.id, "PRESSING")
            if self.faults.press_timeout:
                step.outcome = "timeout"
                step.deadline = now + t.press_timeout_s * t.scale
            else:
                step.outcome = self.faults.press_fail or "ok"
                step.deadline = now + t.press_s * t.scale
        else:  # origin — 원본 CoreXYMotion::setOrigin()은 엔코더를 0으로, homed_=true로 둔다(10/25 대조)
            self.xy = (0.0, 0.0)
            self.homed = True
            self._invalidate_token()
            self._active = None

    def _finish(self, step: _Step) -> None:
        if step.kind == "move":
            if step.outcome == "stall":
                self.xy = self.position()
                self._fail_active("ERROR_STALL", "FOLLOW_ERROR")
                return
            self.xy = (step.x, step.y)
            x, y = self.xy
            if step.org == "json":
                self._token = secrets.token_hex(8)
                self._token_xy = (step.x, step.y, step.tol)
                pos = {"xMm": round(x, 2), "yMm": round(y, 2)}
                self._state(step.id, "POSITIONED", position=pos, errorMm=0.0, positionToken=self._token)
                self._state(step.id, "COMPLETED")
            elif step.org == "text":
                self._out(f"DONE {x:.2f} {y:.2f}")
        elif step.kind == "home":
            self.xy = (0.0, 0.0)
            self.homed = True
            if step.org == "json":
                self._state(step.id, "HOMED", homed=True)
                self._state(step.id, "COMPLETED", homed=True)
            else:
                self._out("HOMED")
        elif step.kind == "tap":
            if step.outcome == "timeout":
                self._fail_active("ERROR_TIMEOUT", "BOT_TIMEOUT")
                return
            if step.outcome != "ok":
                if step.org == "json":
                    state = "ERROR_TIMEOUT" if step.outcome in _TIMEOUT_CODES else "ERROR_PROTOCOL"
                    self._state(step.id, state, message=step.outcome)
                    step.org = "gcode"  # the sketch does not report the same id twice
                self._fail_active("ERROR_PROTOCOL", step.outcome)
                return
            if step.org == "json":
                self._state(step.id, "COMPLETED")
            elif step.org == "text":
                self._out("PRESSED")
        self._active = None
        self._wake.notify_all()


# TCP front end

class _Log:
    def __init__(self, stream=None) -> None:
        self._stream = stream or sys.stdout
        self._lock = threading.Lock()

    def __call__(self, direction: str, text: str) -> None:
        stamp = datetime.now().isoformat(timespec="milliseconds")
        with self._lock:
            print(f"{stamp} {direction} {text}", file=self._stream, flush=True)


class TcpFrontEnd:
    """One client at a time; a new connection replaces the previous one."""

    def __init__(self, host: str, port: int, *, log: Callable[[str, str], None] | None = None,
                 reset_on_connect: bool = False, **sim_kwargs) -> None:
        self._log = log or _Log()
        self._conn: socket.socket | None = None
        self._conn_lock = threading.Lock()
        self.reset_on_connect = reset_on_connect
        self.sim = TouchBridgeSim(self._emit, **sim_kwargs)
        self._server = socket.create_server((host, port), reuse_port=False)
        self.address = self._server.getsockname()[:2]
        self._closed = threading.Event()

    def _emit(self, line: str) -> None:
        with self._conn_lock:
            conn = self._conn
            self._log("<<", line if conn is not None else line + "   (no client)")
            if conn is None:
                return
            try:
                conn.sendall((line + "\n").encode("utf-8"))
            except OSError:
                pass

    def serve_forever(self) -> None:
        self._log("--", f"listening on {self.address[0]}:{self.address[1]} (SIMULATION, not hardware)")
        while not self._closed.is_set():
            try:
                conn, peer = self._server.accept()
            except OSError:
                break
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self._conn_lock:
                old, self._conn = self._conn, conn
            if old is not None:
                try:
                    old.close()
                except OSError:
                    pass
            self._log("--", f"client connected from {peer[0]}:{peer[1]}")
            if self.reset_on_connect:
                self.sim.boot()
            threading.Thread(target=self._read, args=(conn,), daemon=True).start()

    def _read(self, conn: socket.socket) -> None:
        pending = b""
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                pending += data
                while b"\n" in pending:
                    raw, pending = pending.split(b"\n", 1)
                    self._log(">>", raw.decode("utf-8", errors="replace").rstrip("\r"))
                    self.sim.feed(raw + b"\n")
                if b"!" in pending:  # a bare '!' stops without waiting for a newline
                    self._log(">>", "! (immediate stop byte)")
                    self.sim.feed(pending)
                    pending = b""
        except OSError:
            pass
        finally:
            with self._conn_lock:
                if self._conn is conn:
                    self._conn = None
            self._log("--", "client disconnected")
            try:
                conn.close()
            except OSError:
                pass

    def close(self) -> None:
        self._closed.set()
        try:
            self._server.close()
        except OSError:
            pass
        with self._conn_lock:
            conn, self._conn = self._conn, None
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass
        self.sim.close()


def _parse_listen(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep or not host:
        raise argparse.ArgumentTypeError("--listen must be HOST:PORT")
    return host.strip("[]"), int(port)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Touch Bridge firmware simulator (SIMULATION, not hardware).")
    parser.add_argument("--listen", type=_parse_listen, default=("127.0.0.1", 7100), help="HOST:PORT")
    parser.add_argument("--speed", type=float, default=Timing.speed_mm_s, help="mm/s (sketch default)")
    parser.add_argument("--accel", type=float, default=Timing.accel_mm_s2, help="mm/s^2 (sketch default)")
    parser.add_argument("--home-s", type=float, default=Timing.home_s, help="homing duration, 추측")
    parser.add_argument("--press-s", type=float, default=Timing.press_s, help="SwitchBot press duration, 추측")
    parser.add_argument("--time-scale", type=float, default=1.0, help="multiply all durations")
    parser.add_argument("--start-homed", action="store_true",
                        help="start already homed (the real sketch boots unhomed)")
    parser.add_argument("--reset-on-connect", action="store_true",
                        help="reboot (unhomed, banner) on every new connection, like a DTR reset")
    parser.add_argument("--press-fail", choices=PRESS_FAIL_CODES, help="every press fails with this Bot result")
    parser.add_argument("--press-timeout", action="store_true", help="every press gets no Bot reply (8 s)")
    parser.add_argument("--stall-on-move", type=int, metavar="N", help="the Nth JSON move_only stalls")
    args = parser.parse_args(argv)
    for name in ("speed", "accel", "home_s", "press_s", "time_scale"):
        value = getattr(args, name)
        if not math.isfinite(value) or value <= 0:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    timing = Timing(speed_mm_s=args.speed, accel_mm_s2=args.accel, home_s=args.home_s,
                    press_s=args.press_s, scale=args.time_scale)
    faults = Faults(press_fail=args.press_fail, press_timeout=args.press_timeout,
                    stall_on_move=args.stall_on_move)
    host, port = args.listen
    front = TcpFrontEnd(host, port, timing=timing, faults=faults, homed=False)
    front.sim.boot()
    if args.start_homed:
        front.sim.homed = True
    try:
        front.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        front.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
