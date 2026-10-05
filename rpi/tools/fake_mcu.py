"""메모리 파이프 위의 가짜 모션 MCU — 시험과 조그 CLI 리허설(``--fake-mcu``)이 같이 쓴다.

**실물 MCU가 아니다.** `rpi/controller/serial_motion.py` 머리말의 줄 단위 JSON 규약을
흉내 낼 뿐, 모터·엔코더·리밋 스위치를 흉내 내지 않는다. 이것으로 통과한 것은
"호스트 쪽 규약 처리"까지다.

규약의 실행 가능한 기준이라 펌웨어(firmware-motion)와 같은 규칙 두 가지는 흉내 낸다.
- ``delays[cmd]``(초)를 주면 그 명령의 응답을 그만큼 늦게 보낸다. 그동안 다른 줄(``ping``·
  ``status``·``limits``·``stop``)은 바로 처리하고, 움직이는 명령은 ``busy``로 거절한다.
- ``watchdog_s``를 주면 늦은 응답을 기다리는 동안 **받은 줄이 하나도 없이** 그 시간이 지나면
  ``{"event":"alarm","reason":"host_timeout"}``을 먼저, 대기 명령의 ``ok:false``를 나중에 보낸다
  (펌웨어 HOST_WATCHDOG_MS와 같은 순서). 호스트 heartbeat(``ping``)가 이것을 막는다.
- ``ready_banner=True``면 시작할 때(``boot_noise`` 줄들 뒤에) 펌웨어 부팅 배너
  ``{"event":"ready","fw":"fake_mcu","protocol":"line-json/v0","reset":"poweron"}``를 보낸다.
  ``boot_delay_s``를 주면 그동안은 받은 줄을 버린다(부팅 중 — 첫 status가 사라지는 경우).
  ``reboot()``는 대기 명령·원점을 버리고 같은 순서로 다시 부팅한다.

- ``z_mode``(2026-10-05): ``"motor"``(기본)·``"solenoid"``를 ``ready``·``status``에 ``z_mode``로 싣는다.
  None이면 필드를 빼서 z_mode를 모르는 MCU(팀원 펌웨어 원본)를 흉내 낸다. 솔레노이드는 펌웨어
  Z_MODE_SOLENOID처럼 ``depth`` 누름을 ``z_unsupported``로, 켜짐 시간(drive_ms + dwell_ms)이
  ``solenoid_on_max_ms``를 넘으면 ``soft_limit``으로, 직전 누름 뒤 ``solenoid_min_off_s``가 안 지났으면
  ``z_cooldown``으로 거절한다.
- ``slip_counts=(da, db)``(2026-10-05): 이동 뒤 실제(보고) 위치를 명령 카운트에서 그만큼 어긋나게 둔다 —
  벨트 미끄럼·도착 실패 주입. ``report_position=False``면 ``position`` 이벤트를 보내지 않는다.

`REHEARSAL_CONFIG`의 수치는 **리허설용 임의 값**이다. 실물 값이 아니며 실기기 설정의
근거로 쓰지 않는다(조그 CLI는 ``--fake-mcu``와 함께일 때만 이 값을 받는다).
"""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable

from rpi.controller.kinematics import CoreXYConfig
from rpi.controller.serial_motion import InMemoryLinePipe, MotionConfig

# 리허설용 임의 값 — 실물 값 아님
REHEARSAL_KINEMATICS = CoreXYConfig(
    counts_per_output_rev=1000.0,
    pulley_teeth=10,
    belt_pitch_mm=3.0,
    x_min_mm=0.0,
    x_max_mm=100.0,
    y_min_mm=0.0,
    y_max_mm=100.0,
    a_sign=1,
    b_sign=1,
)
REHEARSAL_CONFIG = MotionConfig(
    kinematics=REHEARSAL_KINEMATICS,
    press_mode="depth",
    press_depth_counts=40,
    press_depth_step_counts=10,
    press_depth_max_counts=60,
    press_drive_max_ms=500,
    press_dwell_ms=100,
    retry_xy_offsets_mm=((0.5, 0.0), (-0.5, 0.0)),
    status_timeout_s=1.0,
    home_timeout_s=1.0,
    move_timeout_s=1.0,
    press_timeout_s=1.0,
)

Handler = Callable[[dict], "list[dict | str] | None"]

MOTION_CMDS = frozenset({"home", "move", "press"})
_BUSY_STATE = {"home": "homing", "move": "moving", "press": "pressing"}


class FakeMcu:
    """명령 한 줄에 대해 ``handlers[cmd](doc)``가 돌려준 줄들을 답한다.

    - 핸들러가 None을 돌려주면 답하지 않는다(시간 초과 시험).
    - 모르는 명령에는 ``{"ok": false, "error": "unknown_cmd"}``.
    - ``move``가 오면 받은 ``a``·``b`` 카운트를 현재 위치로 두고, ``status``가 그것을
      보고한다(조그 CLI가 상대 이동 기준을 MCU 보고값에서 얻는지 시험하려고).
    """

    def __init__(
        self,
        pipe: InMemoryLinePipe,
        homed: bool = False,
        *,
        watchdog_s: float | None = None,
        ready_banner: bool = False,
        boot_noise: tuple[str, ...] = (),
        boot_delay_s: float = 0.0,
        z_mode: str | None = "motor",
        solenoid_on_max_ms: int = 1000,
        solenoid_min_off_s: float = 0.0,
        slip_counts: tuple[int, int] = (0, 0),
        report_position: bool = True,
    ) -> None:
        #: Z 누름 방식 — None이면 ready·status에 z_mode를 싣지 않는다.
        self.z_mode = z_mode
        #: 솔레노이드 켜짐 시간 상한(ms)·최소 꺼짐 시간(s). 시험용 임의 값 — 펌웨어 SOLENOID_* 자리표시자의 축소판.
        self.solenoid_on_max_ms = solenoid_on_max_ms
        self.solenoid_min_off_s = solenoid_min_off_s
        self._solenoid_off_at: float | None = None
        #: 이동 뒤 보고 위치의 어긋남(카운트) — 미끄럼 주입.
        self.slip_counts = slip_counts
        self.report_position = report_position
        self._end = pipe.device
        self.ready_banner = ready_banner
        self.boot_noise = boot_noise
        self.boot_delay_s = boot_delay_s
        self._booting_until = 0.0
        #: 부팅 중이라 버린 줄 수.
        self.dropped_while_booting = 0
        self.received: list[dict] = []
        self.homed = homed
        self.a = 0
        self.b = 0
        self.z = 0
        self.alarm: str | None = None
        #: 리밋 입력(활성=True). 시험이 바꿔 배선 확인 출력을 본다.
        self.limits_raw = {"x": False, "y": False, "z": False}
        self.limits_debounced = {"x": False, "y": False, "z": False}
        self.delays: dict[str, float] = {}
        self.watchdog_s = watchdog_s
        self._pending: tuple[dict, list, float] | None = None  # (요청, 응답 줄들, 보낼 시각)
        self._pending_boot_reset: str | None = None
        self._last_line = time.monotonic()
        self.handlers: dict[str, Handler] = {
            "status": lambda d: [
                self._ok(
                    d, state=self._state(), homed=self.homed, a=self.a, b=self.b, z=self.z, alarm=self.alarm,
                    **self._z_mode_field(),
                )
            ],
            "home": self._home,
            "move": self._move,
            "press": self._press,
            "stop": lambda d: [self._ok(d)],
            "ping": lambda d: [self._ok(d)],
            "limits": lambda d: [
                self._ok(d, raw=dict(self.limits_raw), debounced=dict(self.limits_debounced))
            ],
        }
        self._stop = threading.Event()
        self._boot()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="fake-mcu")
        self._thread.start()

    def ready_event(self, reset: str = "poweron") -> dict:
        # 펌웨어 부팅 배너 — firmware-motion/protocol_table.json events.ready
        return {"event": "ready", "fw": "fake_mcu", "protocol": "line-json/v0", "reset": reset, **self._z_mode_field()}

    def _z_mode_field(self) -> dict:
        return {"z_mode": self.z_mode} if self.z_mode is not None else {}

    def _boot(self, reset: str = "poweron") -> None:
        self._booting_until = time.monotonic() + self.boot_delay_s
        if self.boot_delay_s <= 0:
            self._emit_boot(reset)
        else:
            self._pending_boot_reset = reset

    def _emit_boot(self, reset: str) -> None:
        self._pending_boot_reset = None
        self._send(list(self.boot_noise))
        if self.ready_banner:
            self._send([self.ready_event(reset)])

    def reboot(self, reset: str = "sw") -> None:
        """MCU 재시작 흉내: 대기 명령·원점·알람을 버리고 부팅 잡음·배너를 다시 보낸다."""
        self._pending = None
        self.homed = False
        self.alarm = None
        self._boot(reset)

    def _home(self, doc: dict) -> list[dict]:
        self.homed = True
        self.a = self.b = self.z = 0
        return [self._ok(doc)]

    def _move(self, doc: dict) -> list[dict]:
        if isinstance(doc.get("a"), int) and isinstance(doc.get("b"), int):
            da, db = self.slip_counts
            self.a, self.b = doc["a"] + da, doc["b"] + db
        return [*self._positions(), self._ok(doc)]

    def _press(self, doc: dict) -> list[dict]:
        if self.z_mode == "solenoid":
            refusal = self._solenoid_refusal(doc)
            if refusal is not None:
                return [{"id": doc.get("id"), "ok": False, "error": refusal}]
        return [{"event": "press_start"}, {"event": "press_end"}, *self._positions(), self._ok(doc)]

    def _solenoid_refusal(self, doc: dict) -> str | None:
        # 펌웨어 motion_cmd_press(Z_MODE_SOLENOID)와 같은 순서: 방식 → 켜짐 상한 → 냉각.
        if doc.get("mode") != "duration":
            return "z_unsupported"
        on_ms = int(doc.get("drive_ms") or 0) + int(doc.get("dwell_ms") or 0)
        if on_ms > self.solenoid_on_max_ms:
            return "soft_limit"
        now = time.monotonic()
        if self._solenoid_off_at is not None and now - self._solenoid_off_at < self.solenoid_min_off_s:
            return "z_cooldown"
        self._solenoid_off_at = now  # 가짜는 즉시 끝난다 — 지금 꺼진 것으로 둔다
        return None

    def _positions(self) -> list[dict]:
        return [self._position()] if self.report_position else []

    def _position(self) -> dict:
        # 펌웨어의 선택 위치 이벤트(ok 직전 한 번) — firmware-motion/protocol_table.json
        return {"event": "position", "a": self.a, "b": self.b, "z": self.z}

    @staticmethod
    def _ok(doc: dict, **fields: object) -> dict:
        return {"id": doc["id"], "ok": True, **fields}

    def _state(self) -> str:
        if self.alarm is not None:
            return "alarm"
        pending = self._pending
        return _BUSY_STATE.get(str(pending[0].get("cmd")), "idle") if pending else "idle"

    def cmds(self) -> list[str]:
        """받은 명령 이름(heartbeat ``ping`` 제외 — 링크 유지용 줄이라 명령 순서 시험에서 뺀다)."""
        return [d["cmd"] for d in self.received if d.get("cmd") != "ping"]

    def pings(self) -> int:
        return sum(1 for d in self.received if d.get("cmd") == "ping")

    def _send(self, replies: list) -> None:
        for reply in replies:
            self._end.write_line(reply if isinstance(reply, str) else json.dumps(reply))

    def _tick(self, now: float) -> None:
        pending = self._pending
        if pending is None:
            return
        doc, replies, due = pending
        if self.watchdog_s is not None and now - self._last_line >= self.watchdog_s:
            # 펌웨어 fault(): 이벤트 먼저, 대기 명령의 실패 응답 나중.
            self._pending = None
            self.alarm = "host_timeout"
            self.homed = False
            self._send([
                {"event": "alarm", "reason": "host_timeout", "z_retract": "skipped"},
                {"id": doc.get("id"), "ok": False, "error": "host_timeout"},
            ])
        elif now >= due:
            self._pending = None
            self._send(replies)

    def _handle(self, doc: dict) -> None:
        cmd = str(doc.get("cmd"))
        if cmd == "stop" and self._pending is not None:
            held = self._pending[0]
            self._pending = None
            self.homed = False
            self._send([{"id": held.get("id"), "ok": False, "error": "stopped"}])
        elif cmd in MOTION_CMDS and self._pending is not None:
            self._send([{"id": doc.get("id"), "ok": False, "error": "busy"}])
            return
        elif cmd in MOTION_CMDS and self.alarm is not None and cmd != "home":
            self._send([{"id": doc.get("id"), "ok": False, "error": "alarm"}])
            return
        if cmd == "home":
            self.alarm = None
        handler = self.handlers.get(cmd)
        if handler is None:
            replies: list = [{"id": doc.get("id"), "ok": False, "error": "unknown_cmd"}]
        else:
            replies = handler(doc) or []
        delay = self.delays.get(cmd)
        if delay and replies:
            self._pending = (doc, list(replies), time.monotonic() + delay)
            return
        self._send(replies)

    def _loop(self) -> None:
        while not self._stop.is_set():
            line = self._end.read_line(0.02)
            now = time.monotonic()
            if self._pending_boot_reset is not None or now < self._booting_until:
                if line is not None:
                    self.dropped_while_booting += 1  # 부팅 중 — 펌웨어는 아직 시리얼을 읽지 않는다
                if now >= self._booting_until and self._pending_boot_reset is not None:
                    self._emit_boot(self._pending_boot_reset)
                continue
            if line is not None:
                self._last_line = now  # 펌웨어처럼 받은 줄이면 무엇이든 워치독을 갱신한다
            self._tick(now)
            if line is None:
                continue
            try:
                doc = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(doc, dict):
                continue
            self.received.append(doc)
            self._handle(doc)

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)
