"""G10 기존 의미 고정: 실행 정지 / hold의 가전 취소 / 물리 비상 사건."""
import asyncio
import contextlib
from dataclasses import replace

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink
from rpi.controller.serial_motion import InMemoryLinePipe, MotionSafetyController
from rpi.tests.test_serial_motion import TEST_CONFIG, _homed_client
from rpi.tools.fake_mcu import FakeMcu
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor
from rpi4.tests.test_act_executor import FakeWriter, feed
from rpi4.tests.test_act_hold import HOLD, TARGETS, _close, _controller, _hw, _link, _until


@pytest.mark.parametrize("stop", ["appliance", "drive", "estop"])
def test_hold_stop_meaning_and_repeated_stop_does_not_press_again(stop):
    async def scenario():
        hw = _hw()
        executor, client, task = await _link(_controller(), hw)
        try:
            await asyncio.wait_for(client.execute(["즉석밥", "시작"], targets=TARGETS,
                                                  hold=HOLD, appliance_id="microwave"), 3)
            await _until(lambda: (client.last_hold or {}).get("sim_phase") == "waiting_above_stop")
            if stop == "estop":
                executor.handle_outlet_estop()
                executor.handle_outlet_estop()
            else:
                await client.abort(stop)
                await client.abort(stop)
            state = "parked" if stop == "appliance" else "fault"
            await _until(lambda: (client.last_hold or {}).get("hold_state") == state)
            assert hw.motion.presses() == (["취소"] * HOLD["stop_presses"] if stop == "appliance" else [])
            assert hw.motion.moves() == ([(120.0, 80.0), (10.0, 190.0)]
                                         if stop == "appliance" else [(120.0, 80.0)])
            assert executor.estop_latched is (stop == "estop")
        finally:
            await _close(executor, client, task)
    asyncio.run(scenario())


@pytest.mark.parametrize("stop", ["appliance", "drive", "estop"])
def test_stop_during_execution_stops_drive_without_appliance_cancel(stop):
    async def scenario():
        pipe = InMemoryLinePipe()
        mcu = FakeMcu(pipe)
        motion = _homed_client(pipe, replace(TEST_CONFIG, move_timeout_s=10))
        controller = ClosedLoopController(motion, MockVerifier([True] * 10),
                                          MockAlertSink(), MotionSafetyController(motion))
        reader, writer = asyncio.StreamReader(), FakeWriter()
        executor = ActExecutor(reader, writer, controller, motion_stop=motion)
        mcu.delays["move"] = 10
        task = asyncio.create_task(executor.run())
        try:
            feed(reader, {"type": "execute", "sequence_id": "run", "appliance_id": "microwave",
                          "buttons": ["시작", "취소"],
                          "targets": {"시작": {"x_mm": 1, "y_mm": 1},
                                      "취소": {"x_mm": 2, "y_mm": 2}}})
            await _until(lambda: "move" in mcu.cmds())
            if stop == "estop":
                executor.handle_outlet_estop()
            else:
                feed(reader, {"type": "abort", "scope": stop})
            await _until(lambda: any(d.get("type") == "result" for d in writer.messages()))
            # 가짜 MCU는 별도 스레드라 부하 때 결과가 'stop' 기록보다 먼저 올 수 있다 — 도착을 기다린다.
            await _until(lambda: "stop" in mcu.cmds())
            assert mcu.cmds().count("move") == 1
            assert "press" not in mcu.cmds()
            assert executor.estop_latched is (stop == "estop")
        finally:
            motion.request_stop()
            reader.feed_eof()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(task, 3)
            await executor.shutdown()
            mcu.close()
    asyncio.run(scenario())
