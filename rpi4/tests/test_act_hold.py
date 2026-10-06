"""ActExecutor 정지 대기·보관·확인 주행 — 실제 ActClient(RPi5) ↔ ActExecutor(RPi4)를 메모리로 잇는다."""

from __future__ import annotations

import asyncio

import pytest

from rpi.controller import ButtonTarget, ClosedLoopController, ExecutionMode
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.services.act_client import ActClient, ActLinkError
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor
from rpi4.services.stop_hold import HoldHardware, HoldTiming, MockApplianceRun, MockHoldMotion

HOLD = {"appliance_id": "microwave", "stop_button": "취소", "stop_x_mm": 120.0, "stop_y_mm": 80.0,
        "stop_presses": 2, "park_x_mm": 10.0, "park_y_mm": 190.0}
TARGETS = {"즉석밥": ButtonTarget(40.0, 60.0), "시작": ButtonTarget(90.0, 60.0)}
FAST = HoldTiming(poll_s=0.01, stop_confirm_s=0.2, max_hold_s=30.0, press_gap_s=0.0)


class _PipeWriter:
    def __init__(self, peer):
        self._peer = peer

    def write(self, data):
        self._peer.feed_data(data)

    async def drain(self):
        pass


class _RealGrbl(MockGrblClient):
    execution_mode = ExecutionMode.REAL


def _controller(grbl=None):
    return ClosedLoopController(grbl=grbl or MockGrblClient(), verifier=MockVerifier([True] * 20),
                                alerts=MockAlertSink(), safety=MockSafetyController())


async def _link(controller, hardware):
    a_reader, h_reader = asyncio.StreamReader(), asyncio.StreamReader()
    executor = ActExecutor(a_reader, _PipeWriter(h_reader), controller, hold=hardware)
    client = ActClient(h_reader, _PipeWriter(a_reader))
    await client.start()
    task = asyncio.create_task(executor.run())
    return executor, client, task


async def _until(pred, timeout=5.0):
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while not pred():
        assert loop.time() < end, "timed out"
        await asyncio.sleep(0.01)


async def _close(executor, client, task):
    await executor.shutdown()
    task.cancel()
    await client.stop()


def _hw(run_s=30.0, honors=True, motion=None):
    return HoldHardware(motion or MockHoldMotion(),
                        lambda plan: MockApplianceRun(run_s, honors_stop=honors, presses_needed=plan.stop_presses),
                        FAST)


def test_after_success_hovers_then_abort_presses_stop_and_parks():
    async def t():
        hw = _hw()
        executor, client, task = await _link(_controller(), hw)
        seen = []
        client.add_progress_listener(lambda d: seen.append(d) if d.get("phase") == "hold" else None)
        result = await client.execute(["즉석밥", "시작"], targets=TARGETS, hold=HOLD, appliance_id="microwave")
        assert result.success
        await _until(lambda: (client.last_hold or {}).get("hold_state") == "hovering_stop"
                     and client.last_hold.get("sim_phase") == "waiting_above_stop")
        assert client.last_hold["execution_mode"] == "mock" and client.last_hold["appliance_id"] == "microwave"
        await client.abort()  # /stop — 대기 중이면 정지 버튼 누름
        await _until(lambda: client.last_hold.get("hold_state") == "parked")
        assert client.last_hold["stop_outcome"] == "stopped"
        assert hw.motion.presses() == ["취소", "취소"]
        assert hw.motion.moves() == [(120.0, 80.0), (10.0, 190.0)]
        states = [d["hold_state"] for d in seen]
        assert "stopping" in states and states[-1] == "parked"
        await _close(executor, client, task)

    asyncio.run(t())


def test_drive_scope_abort_does_not_press():
    async def t():
        hw = _hw()
        executor, client, task = await _link(_controller(), hw)
        await client.execute(["즉석밥", "시작"], targets=TARGETS, hold=HOLD, appliance_id="microwave")
        await _until(lambda: (client.last_hold or {}).get("sim_phase") == "waiting_above_stop")
        await client.abort("drive")
        await _until(lambda: client.last_hold.get("hold_state") == "fault")
        assert hw.motion.presses() == [] and client.last_hold["stop_outcome"] is None
        await _close(executor, client, task)

    asyncio.run(t())


def test_real_run_without_l3_confirmation_does_not_hover():
    async def t():
        hw = _hw()
        executor, client, task = await _link(_controller(_RealGrbl()), hw)
        await client.execute(["즉석밥", "시작"], targets=TARGETS, hold=HOLD, appliance_id="microwave")
        await _until(lambda: client.last_hold is not None)
        assert client.last_hold["hold_state"] is None
        assert "확인되지 않아" in client.last_hold["detail"]
        assert hw.motion.moves() == [] and executor.hold_session is None
        await _close(executor, client, task)

    asyncio.run(t())


def test_new_execute_releases_a_hover_and_verify_is_refused_while_holding():
    async def t():
        hw = _hw()
        executor, client, task = await _link(_controller(), hw)
        await client.execute(["즉석밥", "시작"], targets=TARGETS, hold=HOLD, appliance_id="microwave")
        await _until(lambda: (client.last_hold or {}).get("sim_phase") == "waiting_above_stop")
        with pytest.raises(ActLinkError, match="정지 버튼 위에서"):
            await client.verify_pass([{"button": "시작", "x_mm": 90.0, "y_mm": 60.0}])
        first = executor.hold_session
        result = await client.execute(["시작"], targets={"시작": TARGETS["시작"]}, appliance_id="microwave")
        assert result.success and first.snapshot()["hold_state"] == "released"
        assert hw.motion.presses() == []
        await _close(executor, client, task)

    asyncio.run(t())


def test_verify_pass_over_the_link_moves_only():
    async def t():
        hw = _hw()
        executor, client, task = await _link(_controller(), hw)
        steps = []
        client.add_progress_listener(lambda d: steps.append(d) if d.get("phase") == "verify" else None)
        doc = await client.verify_pass([{"button": "즉석밥", "x_mm": 40.0, "y_mm": 60.0},
                                        {"button": "보관 위치", "x_mm": 10.0, "y_mm": 190.0, "kind": "park"}])
        assert doc["type"] == "verify_result" and doc["ok"] is True
        assert [r["status"] for r in doc["targets"]] == ["reached", "reached"]
        assert hw.motion.moves() == [(40.0, 60.0), (10.0, 190.0)] and hw.motion.presses() == []
        assert {s["status"] for s in steps} == {"moving", "reached"}
        await _close(executor, client, task)

    asyncio.run(t())


def test_without_hold_hardware_hold_is_ignored_and_verify_unavailable():
    async def t():
        executor, client, task = await _link(_controller(), None)
        result = await client.execute(["즉석밥", "시작"], targets=TARGETS, hold=HOLD, appliance_id="microwave")
        assert result.success
        await asyncio.sleep(0.05)
        assert client.last_hold is None
        with pytest.raises(ActLinkError, match="확인 주행용 모션"):
            await client.verify_pass([{"button": "시작", "x_mm": 90.0, "y_mm": 60.0}])
        await _close(executor, client, task)

    asyncio.run(t())
