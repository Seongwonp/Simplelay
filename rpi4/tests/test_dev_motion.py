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

from rpi4.models.act_messages import AbortMsg, DevMotionMsg, DevMotionRefusedMsg, parse_act_message
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


# ── 정지 확인 단계(2026-10-13, 개발자 조작 규약 2) ─────────────────────────────


def test_dev_stop_reply_carries_the_confirmed_stop_level(rig) -> None:
    """대기 중 정지: MCU 응답(지연 ms)과 status 두 번의 같은 엔코더로 ``verified``까지 싣는다."""
    async def _t():
        r = rig(homed=True)
        reply = await r.op("stop", reason="emergency_stop")
        assert reply["ok"] is True
        assert reply["stop_level"] == "verified"
        assert isinstance(reply["ack_ms"], int) and reply["ack_ms"] >= 0

    run(_t())


def test_dev_stop_without_mcu_reply_says_only_sent(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.mcu.handlers["stop"] = lambda d: None  # 답하지 않는 MCU
        reply = await r.op("stop", reason="emergency_stop")
        assert reply["ok"] is True  # 정지 줄은 썼다
        assert reply["stop_level"] == "sent"
        assert reply["ack_ms"] is None

    run(_t())


def test_dev_stop_during_a_jog_reports_the_mcu_ack(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.mcu.delays["move"] = 0.6
        await r.send({"type": "dev_motion", "request_id": "j1", "op": "jog", "axis": "x", "delta_mm": 1.0})
        await asyncio.sleep(0.05)
        stop = await r.op("stop", request_id="s1", reason="user_stop")
        assert stop["ok"] is True
        assert stop["stop_level"] in ("mcu_ack", "verified")
        assert isinstance(stop["ack_ms"], int)

    run(_t())


def test_dev_stop_reply_does_not_block_the_read_loop(rig) -> None:
    """정지 확인을 기다리는 동안에도 읽기 루프는 다음 프레임(abort 등)을 바로 처리한다."""
    async def _t():
        r = rig(homed=True)
        r.mcu.handlers["stop"] = lambda d: None  # 확인 기한까지 기다리게
        started = time.monotonic()
        await r.send({"type": "dev_motion", "request_id": "s1", "op": "stop", "reason": "user_stop"})
        assert time.monotonic() - started < 0.1
        await r.executor.wait_dev()
        assert [d for d in r.writer.dev_results() if d["request_id"] == "s1"][-1]["stop_level"] == "sent"

    run(_t())


def test_act_info_advertises_the_stop_report_protocol(rig) -> None:
    async def _t() -> dict:
        r = rig()
        await r.send({"type": "hello"})
        return next(d for d in r.writer.docs() if d["type"] == "act_info")

    from rpi4.services.act_executor import STOP_REPORT_PROTOCOL

    info = run(_t())
    assert info["dev_motion_protocol"] == DEV_MOTION_PROTOCOL == 2
    assert info["stop_report_protocol"] == STOP_REPORT_PROTOCOL == 1


def test_parse_abort_keeps_the_stop_id() -> None:
    assert parse_act_message(json.dumps({"type": "abort", "stop_id": "st1"})) == AbortMsg(stop_id="st1")
    assert parse_act_message(json.dumps({"type": "abort"})) == AbortMsg()
    # 모양이 틀린 stop_id는 정지를 막지 않는다 — 보고만 하지 않는다.
    assert parse_act_message(json.dumps({"type": "abort", "stop_id": 5})) == AbortMsg()


def test_abort_with_stop_id_reports_the_dev_stop_level(rig) -> None:
    async def _t():
        r = rig(homed=True)
        r.mcu.delays["move"] = 0.6
        await r.send({"type": "dev_motion", "request_id": "j1", "op": "jog", "axis": "x", "delta_mm": 1.0})
        await asyncio.sleep(0.05)
        await r.send({"type": "abort", "stop_id": "st1"})
        await r.executor.wait_dev()
        reports = [d for d in r.writer.docs() if d.get("type") == "stop_report"]
        assert len(reports) == 1
        assert reports[0]["stop_id"] == "st1" and reports[0]["target"] == "dev"
        assert reports[0]["stop_level"] in ("mcu_ack", "verified")

    run(_t())


def test_abort_with_stop_id_while_idle_reports_nothing_to_stop(rig) -> None:
    async def _t():
        r = rig(homed=True)
        await r.send({"type": "abort", "stop_id": "st2"})
        await r.executor.wait_dev()
        report = next(d for d in r.writer.docs() if d.get("type") == "stop_report")
        assert report["target"] == "idle" and report["stop_level"] is None
        assert "stop" not in r.mcu.cmds()  # 유휴면 MCU에 보내지 않는다(종전과 같다)

    run(_t())


def test_abort_without_stop_id_sends_no_report(rig) -> None:
    """옛 RPi5(stop_id 없음)에는 종전처럼 답하지 않는다."""
    async def _t():
        r = rig(homed=True)
        await r.send({"type": "abort"})
        await r.executor.wait_dev()
        assert not [d for d in r.writer.docs() if d.get("type") == "stop_report"]

    run(_t())


class _BlockingController:
    """request_stop이 올 때까지 실행을 붙잡는 컨트롤러 — 정지는 실제 SerialMotionClient로 보낸다."""

    def __init__(self, motion: SerialMotionClient) -> None:
        import threading

        self._motion = motion
        self._stopped = threading.Event()

    def execute(self, buttons, targets=None):
        from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus

        self._stopped.wait(3.0)
        return ExecutionResult(status=ExecutionStatus.SAFETY_STOPPED,
                               buttons=(ButtonResult("시작", ButtonStatus.FAILED, 1, None),))

    def request_stop(self) -> None:
        self._motion.request_stop()
        self._stopped.set()

    def reset_stop(self) -> None:
        self._stopped.clear()


def test_abort_mid_execution_reports_the_motion_stop_level(rig) -> None:
    async def _t():
        r = rig(homed=True)
        blocking = _BlockingController(r.client)
        r.executor = ActExecutor(reader=r.reader, writer=r.writer, controller=blocking,
                                 dev_motion=DevMotionService(r.client), motion_stop=r.client)
        feed(r.reader, {"type": "execute", "sequence_id": "q1", "buttons": ["시작"], "appliance_id": "microwave"})
        first = asyncio.create_task(r.executor.run_once())
        await _until(lambda: r.executor._busy)
        await r.send({"type": "abort", "stop_id": "st3"})
        await first
        await r.executor.wait_dev()
        report = next(d for d in r.writer.docs() if d.get("type") == "stop_report")
        assert report["stop_id"] == "st3" and report["target"] == "run"
        assert report["stop_level"] in ("mcu_ack", "verified")
        assert isinstance(report["ack_ms"], int)

    run(_t())


def test_abort_mid_execution_without_a_motion_client_says_sent(rig) -> None:
    """모의 모션(실제 모션 어댑터 없음)이면 RPi4가 정지를 넘긴 것까지만 — ``sent``."""
    async def _t():
        r = rig(homed=True, wired=False)
        blocking = _BlockingController(r.client)
        r.executor = ActExecutor(reader=r.reader, writer=r.writer, controller=blocking)
        feed(r.reader, {"type": "execute", "sequence_id": "q1", "buttons": ["시작"], "appliance_id": "microwave"})
        first = asyncio.create_task(r.executor.run_once())
        await _until(lambda: r.executor._busy)
        await r.send({"type": "abort", "stop_id": "st4"})
        await first
        await r.executor.wait_dev()
        report = next(d for d in r.writer.docs() if d.get("type") == "stop_report")
        assert report["target"] == "run" and report["stop_level"] == "sent" and report["ack_ms"] is None

    run(_t())


class _HeldController:
    """정지가 와도 시험이 놓을 때까지 실행을 붙잡는다 — 두 번째 abort도 '실행 중'에 들어온다.

    정지는 실제 SerialMotionClient로 보낸다(실행기 → 어댑터 → 가짜 MCU 배선)."""

    def __init__(self, motion: SerialMotionClient) -> None:
        import threading

        self._motion = motion
        self.release = threading.Event()

    def execute(self, buttons, targets=None):
        from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus

        self.release.wait(5.0)
        return ExecutionResult(status=ExecutionStatus.SAFETY_STOPPED,
                               buttons=(ButtonResult("시작", ButtonStatus.FAILED, 1, None),))

    def request_stop(self) -> None:
        self._motion.request_stop()

    def reset_stop(self) -> None:
        pass


def test_two_interleaved_aborts_each_report_their_own_mcu_stop(rig) -> None:
    """2차 평가 M-N2: 첫 정지의 멈춤 확인(status) 도중 두 번째 정지가 MCU에 나가도, 첫 보고는 첫 MCU 정지의
    기록만 싣는다(최신 정지의 기록으로 바꿔 답하지 않는다). 두 번째 MCU 정지에는 답이 없어 ``sent``에 머문다."""
    import threading

    async def _t():
        r = rig(homed=True)
        held = _HeldController(r.client)
        r.executor = ActExecutor(reader=r.reader, writer=r.writer, controller=held,
                                 dev_motion=DevMotionService(r.client), motion_stop=r.client)
        stop_ids: list[int] = []

        def stop_handler(doc: dict):
            stop_ids.append(doc["id"])
            return [{"id": doc["id"], "ok": True}] if len(stop_ids) == 1 else None

        in_verify, go = threading.Event(), threading.Event()
        original_status = r.mcu.handlers["status"]

        def gated_status(doc: dict):
            if not in_verify.is_set():
                in_verify.set()
                go.wait(2.0)  # 첫 확인이 status를 기다리는 동안 두 번째 정지를 넣는다
            return original_status(doc)

        r.mcu.handlers["stop"] = stop_handler
        r.mcu.handlers["status"] = gated_status
        feed(r.reader, {"type": "execute", "sequence_id": "q1", "buttons": ["시작"], "appliance_id": "microwave"})
        first = asyncio.create_task(r.executor.run_once())
        await _until(lambda: r.executor._busy)
        await r.send({"type": "abort", "stop_id": "st1"})
        await _until(in_verify.is_set)
        assert in_verify.is_set()
        await r.send({"type": "abort", "stop_id": "st2"})  # 두 번째 MCU 정지가 이 안에서 나간다
        go.set()

        def reports() -> list[dict]:
            return [d for d in r.writer.docs() if d.get("type") == "stop_report"]

        await _until(lambda: len(reports()) == 2, 3.0)
        held.release.set()
        await first
        await r.executor.wait_dev()
        by_id = {d["stop_id"]: d for d in reports()}
        assert set(by_id) == {"st1", "st2"}
        assert by_id["st1"]["target"] == by_id["st2"]["target"] == "run"
        # 첫 정지는 MCU가 답했다 — 그 기록(mcu_ack 이상, ack_ms 있음)만.
        assert by_id["st1"]["stop_level"] in ("mcu_ack", "verified")
        assert isinstance(by_id["st1"]["ack_ms"], int)
        # 두 번째 정지는 답이 없다 — 첫 정지의 응답을 빌려 오지 않는다.
        assert by_id["st2"]["stop_level"] == "sent" and by_id["st2"]["ack_ms"] is None
        assert len(stop_ids) == 2

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
