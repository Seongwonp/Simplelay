"""RPi4 개발자 조작 프레임(``dev_motion``) — 2026-10-10, **실물 미검증**.

RPi5 개발자 API가 실물 모드(SIMPLELAY_DEV_REAL_MOTION=1)일 때 보내는 조그·홈·누름·정지를 RPi4가
**같은 SerialMotionClient**로 모션 MCU에 넘기는지 본다. 모션 MCU는 메모리 파이프 위의 가짜
(rpi/tools/fake_mcu.py, 솔레노이드 방식)다 — 모터·엔코더·솔레노이드는 흉내 내지 않는다.

못 박는 것:
- 실제 모션 어댑터가 물렸을 때만 ``act_info.dev_motion_protocol``을 알린다(모의 모션이면 없다)
- 원점 전 조그·누름 거절(MCU에 move·press가 가지 않는다), 한 번 이동 상한(10 mm) 넘으면 거절,
  Z 조그 거절(솔레노이드), 비상정지 걸림·일반 실행 중 거절 — 전부 ``moved:false``
- 조그는 MCU가 보고한 현재 위치 기준 상대 이동 한 번(응답 하나), 재전송·자동 재개 없음
- 정지는 진행 중 조작을 MCU ``stop``으로 끊는다(``dev_motion stop``·일반 ``abort`` 둘 다)
- 누름은 시간 누름(duration)만, 켜짐 800 ms 상한 안에서만
- bring-up 펌웨어(사람용 방향 시험 명령이 켜진 빌드)에는 개발자 조작을 보내지 않는다
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import time

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.serial_motion import InMemoryLinePipe, SerialMotionClient
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu
from rpi.verifier import MockVerifier

from rpi4.models.act_messages import DevMotionMsg, DevMotionRefusedMsg, parse_act_message
from rpi4.services.act_executor import ActExecutor
from rpi4.services.dev_motion import DEV_JOG_STEP_CEILING_MM, DEV_MOTION_PROTOCOL, DevMotionService

#: 시험용 — 솔레노이드 시간 누름(구동 100 + 유지 100 = 200 ms ≤ 800).
_CONFIG = dataclasses.replace(
    REHEARSAL_CONFIG, press_mode="duration", press_drive_ms=100, press_dwell_ms=100,
    press_drive_max_ms=500,
)


class FakeWriter:
    def __init__(self) -> None:
        self._buf = b""

    def write(self, data: bytes) -> None:
        self._buf += data

    async def drain(self) -> None:
        pass

    def docs(self) -> list[dict]:
        return [json.loads(line) for line in self._buf.split(b"\n") if line.strip()]

    def dev_results(self) -> list[dict]:
        return [d for d in self.docs() if d.get("type") == "dev_motion_result"]


def feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


class _Rig:
    def __init__(self, *, homed: bool = False, fw: str = "fake_mcu", config=_CONFIG, wired: bool = True,
                 controller=None) -> None:
        self.pipe = InMemoryLinePipe()
        self.mcu = FakeMcu(self.pipe, homed=homed, z_mode="solenoid", solenoid_on_max_ms=800)
        self.client = SerialMotionClient(self.pipe.host, config, poll_s=0.01)
        self.client.connect()
        self.client.ready_info = {"event": "ready", "fw": fw, "protocol": "line-json/v0"}
        self.reader = asyncio.StreamReader()
        self.writer = FakeWriter()
        controller = controller or ClosedLoopController(
            grbl=MockGrblClient(), verifier=MockVerifier(outcomes=[True] * 50),
            alerts=MockAlertSink(), safety=MockSafetyController(),
        )
        self.executor = ActExecutor(
            reader=self.reader, writer=self.writer, controller=controller,
            dev_motion=DevMotionService(self.client) if wired else None,
        )

    async def send(self, doc: dict) -> None:
        feed(self.reader, doc)
        await self.executor.run_once()

    async def op(self, op: str, request_id: str = "r1", **fields) -> dict:
        await self.send({"type": "dev_motion", "request_id": request_id, "op": op, **fields})
        await self.executor.wait_dev()
        return [d for d in self.writer.dev_results() if d["request_id"] == request_id][-1]

    def close(self) -> None:
        self.mcu.close()


@pytest.fixture()
def rig():
    made: list[_Rig] = []

    def make(**kw) -> _Rig:
        r = _Rig(**kw)
        made.append(r)
        return r

    yield make
    for r in made:
        r.close()


def run(coro):
    return asyncio.run(coro)


async def _until(cond, timeout_s: float = 2.0) -> None:
    """가짜 MCU는 자기 스레드에서 줄을 읽는다 — 받을 때까지 잠깐 기다린다."""
    deadline = time.monotonic() + timeout_s
    while not cond() and time.monotonic() < deadline:
        await asyncio.sleep(0.01)


# ── 규약 ────────────────────────────────────────────────────────────────────


def test_parse_dev_motion_frames() -> None:
    assert parse_act_message(json.dumps({"type": "dev_motion", "request_id": "a1", "op": "home"})) == \
        DevMotionMsg(request_id="a1", op="home")
    jog = parse_act_message(json.dumps(
        {"type": "dev_motion", "request_id": "a2", "op": "jog", "axis": "x", "delta_mm": -1.5}))
    assert jog == DevMotionMsg(request_id="a2", op="jog", axis="x", delta_mm=-1.5)
    # 모양이 틀려도 id가 있으면 버리지 않고 거절로 답한다(RPi5가 기한까지 기다리지 않게).
    bad = parse_act_message(json.dumps(
        {"type": "dev_motion", "request_id": "a3", "op": "jog", "axis": "x", "delta_mm": "far"}))
    assert isinstance(bad, DevMotionRefusedMsg) and bad.reason == "bad_args"
    assert isinstance(parse_act_message(json.dumps({"type": "dev_motion", "request_id": "a4", "op": "shell"})),
                      DevMotionRefusedMsg)
    assert parse_act_message(json.dumps({"type": "dev_motion", "op": "home"})) is None


def test_act_info_advertises_dev_motion_only_when_a_real_motion_client_is_wired(rig) -> None:
    async def _t(wired: bool) -> dict:
        r = rig(wired=wired)
        await r.send({"type": "hello"})
        return next(d for d in r.writer.docs() if d["type"] == "act_info")

    assert run(_t(True))["dev_motion_protocol"] == DEV_MOTION_PROTOCOL
    assert "dev_motion_protocol" not in run(_t(False))


def test_without_a_dev_motion_service_every_op_is_refused(rig) -> None:
    async def _t():
        r = rig(wired=False)
        reply = await r.op("home")
        assert reply["ok"] is False and reply["reason"] == "dev_unsupported"
        assert reply["moved"] is False

    run(_t())


# ── 원점·조그 ───────────────────────────────────────────────────────────────


def test_jog_before_home_is_refused_without_any_move(rig) -> None:
    async def _t():
        r = rig(homed=False)
        reply = await r.op("jog", axis="x", delta_mm=1.0)
        assert reply["ok"] is False and reply["reason"] == "not_homed" and reply["moved"] is False
        assert "move" not in r.mcu.cmds()

    run(_t())


def test_home_then_one_small_jog_is_one_relative_move(rig) -> None:
    async def _t():
        r = rig(homed=False)
        home = await r.op("home", request_id="h1")
        assert home["ok"] is True and home["homed"] is True
        jog = await r.op("jog", request_id="j1", axis="x", delta_mm=1.0)
        assert jog["ok"] is True
        assert jog["x_mm"] == pytest.approx(1.0, abs=0.05) and jog["y_mm"] == pytest.approx(0.0, abs=0.05)
        moves = [d for d in r.mcu.received if d.get("cmd") == "move"]
        assert len(moves) == 1  # 재전송·이어 가기 없음
        assert moves[0]["x_mm"] == pytest.approx(1.0, abs=0.05)
        again = await r.op("jog", request_id="j2", axis="y", delta_mm=-0.0 + 2.0)
        assert again["ok"] is True and again["y_mm"] == pytest.approx(2.0, abs=0.05)

    run(_t())


def test_jog_step_over_the_ceiling_is_refused(rig) -> None:
    async def _t():
        r = rig(homed=False)
        await r.op("home", request_id="h1")
        reply = await r.op("jog", request_id="j1", axis="x", delta_mm=DEV_JOG_STEP_CEILING_MM + 0.5)
        assert reply["ok"] is False and reply["reason"] == "step_too_large" and reply["moved"] is False
        assert "move" not in r.mcu.cmds()

    run(_t())


def test_jog_outside_the_soft_limits_is_refused_before_moving(rig) -> None:
    async def _t():
        r = rig(homed=False)
        await r.op("home", request_id="h1")
        reply = await r.op("jog", request_id="j1", axis="x", delta_mm=-1.0)  # x_min 0 아래
        assert reply["ok"] is False and reply["reason"] == "soft_limit" and reply["moved"] is False
        assert "move" not in r.mcu.cmds()

    run(_t())


def test_z_jog_is_refused_for_the_solenoid(rig) -> None:
    async def _t():
        r = rig(homed=True)
        reply = await r.op("jog", axis="z", delta_mm=1.0)
        assert reply["ok"] is False and reply["reason"] == "z_jog_unsupported"

    run(_t())


# ── 거절 조건(비상정지·일반 실행·bring-up) ──────────────────────────────────


def test_dev_ops_are_refused_while_the_estop_is_latched(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.executor.handle_outlet_estop("button")
        reply = await r.op("jog", axis="x", delta_mm=1.0)
        assert reply["ok"] is False and reply["reason"] == "estop_latched" and reply["moved"] is False
        assert "move" not in r.mcu.cmds()

    run(_t())


def test_dev_ops_are_refused_while_a_normal_execution_runs(rig) -> None:
    class Slow:
        execution_mode = None

        def execute(self, buttons, targets=None):
            time.sleep(0.3)
            raise RuntimeError("stop here")

    async def _t():
        r = rig(homed=True, controller=Slow())
        await r.send({"type": "execute", "sequence_id": "s1", "buttons": ["시작"], "appliance_id": "microwave"})
        reply = await r.op("jog", axis="x", delta_mm=1.0)
        assert reply["ok"] is False and reply["reason"] == "execution_busy"
        assert "move" not in r.mcu.cmds()
        await r.executor.wait_idle()

    run(_t())


def test_an_execute_is_refused_while_a_dev_op_runs(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.mcu.delays["move"] = 0.4
        await r.send({"type": "dev_motion", "request_id": "j1", "op": "jog", "axis": "x", "delta_mm": 1.0})
        await asyncio.sleep(0.05)
        await r.send({"type": "execute", "sequence_id": "s1", "buttons": ["시작"], "appliance_id": "microwave"})
        error = next(d for d in r.writer.docs() if d.get("type") == "error")
        assert error["reason"] == "dev_busy"
        await r.executor.wait_dev()

    run(_t())


def test_bringup_firmware_is_refused(rig) -> None:
    async def _t():
        r = rig(homed=True, fw="firmware-motion-corexy-bringup")
        reply = await r.op("home")
        assert reply["ok"] is False and reply["reason"] == "bringup_firmware"
        assert "home" not in r.mcu.cmds()

    run(_t())


# ── 정지 ────────────────────────────────────────────────────────────────────


def test_dev_stop_cuts_an_in_flight_jog_with_an_mcu_stop(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.mcu.delays["move"] = 0.6  # 이동 기한(1 s)보다 짧게 — 기한 초과 정지와 구분
        await r.send({"type": "dev_motion", "request_id": "j1", "op": "jog", "axis": "x", "delta_mm": 1.0})
        await asyncio.sleep(0.05)
        stop = await r.op("stop", request_id="s1", reason="user_stop")
        assert stop["ok"] is True
        await r.executor.wait_dev()
        jog = next(d for d in r.writer.dev_results() if d["request_id"] == "j1")
        assert jog["ok"] is False and jog["reason"] == "stopped" and jog["moved"] is None
        await _until(lambda: "stop" in r.mcu.cmds())
        assert "stop" in r.mcu.cmds()
        # 정지로 끊긴 뒤에는 다시 원점부터(재개 없음).
        again = await r.op("jog", request_id="j2", axis="x", delta_mm=1.0)
        assert again["reason"] == "not_homed"

    run(_t())


def test_a_plain_abort_also_stops_a_dev_op(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.mcu.delays["move"] = 0.6  # 이동 기한(1 s)보다 짧게 — 기한 초과 정지와 구분
        await r.send({"type": "dev_motion", "request_id": "j1", "op": "jog", "axis": "x", "delta_mm": 1.0})
        await asyncio.sleep(0.05)
        await r.send({"type": "abort"})
        await r.executor.wait_dev()
        await _until(lambda: "stop" in r.mcu.cmds())
        assert "stop" in r.mcu.cmds()
        jog = next(d for d in r.writer.dev_results() if d["request_id"] == "j1")
        assert jog["ok"] is False and jog["reason"] == "stopped"

    run(_t())


def test_stop_is_answered_even_while_idle(rig) -> None:
    async def _t():
        r = rig(homed=True)
        reply = await r.op("stop", reason="emergency_stop")
        assert reply["ok"] is True
        await _until(lambda: "stop" in r.mcu.cmds())
        assert "stop" in r.mcu.cmds()

    run(_t())


# ── 누름 ────────────────────────────────────────────────────────────────────


def test_press_is_one_timed_solenoid_press_at_the_current_position(rig) -> None:
    async def _t():
        r = rig(homed=True)
        reply = await r.op("press", label="BT-05")
        assert reply["ok"] is True
        presses = [d for d in r.mcu.received if d.get("cmd") == "press"]
        assert len(presses) == 1
        assert presses[0]["mode"] == "duration"
        assert presses[0]["drive_ms"] + presses[0]["dwell_ms"] <= 800

    run(_t())


def test_press_before_home_is_refused(rig) -> None:
    async def _t():
        r = rig(homed=False)
        reply = await r.op("press", label="BT-05")
        assert reply["ok"] is False and reply["reason"] == "not_homed"
        assert "press" not in r.mcu.cmds()

    run(_t())


def test_press_longer_than_the_800ms_cap_is_refused(rig) -> None:
    async def _t():
        r = rig(homed=True, config=dataclasses.replace(_CONFIG, press_drive_ms=500, press_dwell_ms=400))
        reply = await r.op("press", label="BT-05")
        assert reply["ok"] is False and reply["reason"] == "press_too_long" and reply["moved"] is False
        assert "press" not in r.mcu.cmds()

    run(_t())


def test_depth_press_is_refused_for_dev_press(rig) -> None:
    async def _t():
        r = rig(homed=True, config=dataclasses.replace(_CONFIG, press_mode="depth"))
        reply = await r.op("press", label="BT-05")
        assert reply["ok"] is False and reply["reason"] == "press_mode_unsupported"

    run(_t())
