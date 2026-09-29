"""메모리 파이프 위의 가짜 모션 MCU — 시험과 조그 CLI 리허설(``--fake-mcu``)이 같이 쓴다.

**실물 MCU가 아니다.** `rpi/controller/serial_motion.py` 머리말의 줄 단위 JSON 규약을
흉내 낼 뿐, 모터·엔코더·리밋 스위치·기한을 흉내 내지 않는다. 이것으로 통과한 것은
"호스트 쪽 규약 처리"까지다.

`REHEARSAL_CONFIG`의 수치는 **리허설용 임의 값**이다. 실물 값이 아니며 실기기 설정의
근거로 쓰지 않는다(조그 CLI는 ``--fake-mcu``와 함께일 때만 이 값을 받는다).
"""

from __future__ import annotations

import json
import threading
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


class FakeMcu:
    """명령 한 줄에 대해 ``handlers[cmd](doc)``가 돌려준 줄들을 답한다.

    - 핸들러가 None을 돌려주면 답하지 않는다(시간 초과 시험).
    - 모르는 명령에는 ``{"ok": false, "error": "unknown_cmd"}``.
    - ``move``가 오면 받은 ``a``·``b`` 카운트를 현재 위치로 두고, ``status``가 그것을
      보고한다(조그 CLI가 상대 이동 기준을 MCU 보고값에서 얻는지 시험하려고).
    """

    def __init__(self, pipe: InMemoryLinePipe, homed: bool = False) -> None:
        self._end = pipe.device
        self.received: list[dict] = []
        self.homed = homed
        self.a = 0
        self.b = 0
        self.z = 0
        self.handlers: dict[str, Handler] = {
            "status": lambda d: [
                self._ok(d, state="idle", homed=self.homed, a=self.a, b=self.b, z=self.z, alarm=None)
            ],
            "home": self._home,
            "move": self._move,
            "press": lambda d: [
                {"event": "press_start"},
                {"event": "press_end"},
                self._position(),
                self._ok(d),
            ],
            "stop": lambda d: [self._ok(d)],
        }
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="fake-mcu")
        self._thread.start()

    def _home(self, doc: dict) -> list[dict]:
        self.homed = True
        self.a = self.b = self.z = 0
        return [self._ok(doc)]

    def _move(self, doc: dict) -> list[dict]:
        if isinstance(doc.get("a"), int) and isinstance(doc.get("b"), int):
            self.a, self.b = doc["a"], doc["b"]
        return [self._position(), self._ok(doc)]

    def _position(self) -> dict:
        # 펌웨어의 선택 위치 이벤트(ok 직전 한 번) — firmware-motion/protocol_table.json
        return {"event": "position", "a": self.a, "b": self.b, "z": self.z}

    @staticmethod
    def _ok(doc: dict, **fields: object) -> dict:
        return {"id": doc["id"], "ok": True, **fields}

    def cmds(self) -> list[str]:
        return [d["cmd"] for d in self.received]

    def _loop(self) -> None:
        while not self._stop.is_set():
            line = self._end.read_line(0.02)
            if line is None:
                continue
            try:
                doc = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(doc, dict):
                continue
            self.received.append(doc)
            handler = self.handlers.get(str(doc.get("cmd")))
            if handler is None:
                replies: list = [{"id": doc.get("id"), "ok": False, "error": "unknown_cmd"}]
            else:
                replies = handler(doc) or []
            for reply in replies:
                self._end.write_line(reply if isinstance(reply, str) else json.dumps(reply))

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)
