"""G9: run() 수신 루프 → 실제 hold/모션 어댑터 → 가짜 MCU. 실물 없음."""
import asyncio
import contextlib
import threading
from dataclasses import replace

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink
from rpi.controller.serial_motion import InMemoryLinePipe, MotionSafetyController
from rpi.tests.test_serial_motion import TEST_CONFIG, _homed_client
from rpi.tools.fake_mcu import FakeMcu
from rpi.verifier import MockVerifier
from rpi4.models.act_messages import HoldPlan
from rpi4.services.act_executor import ActExecutor
from rpi4.services.stop_hold import GrblHoldMotion, MockApplianceRun, StopHoldSession
from rpi4.tests.test_act_executor import FakeWriter, feed
from rpi4.tests.test_act_hold import _until


@pytest.mark.parametrize("scope", ["appliance", "drive", "estop"])
def test_receiver_reads_abort_while_previous_hold_join_waits(monkeypatch, scope):
    async def scenario():
        pipe = InMemoryLinePipe()
        mcu = FakeMcu(pipe)
        motion = _homed_client(pipe, replace(TEST_CONFIG, move_timeout_s=10))
        controller = ClosedLoopController(motion, MockVerifier([True] * 10),
                                          MockAlertSink(), MotionSafetyController(motion))
        reader, writer = asyncio.StreamReader(), FakeWriter()
        executor = ActExecutor(reader, writer, controller, motion_stop=motion)
        # 실제 hold가 정지 버튼 위로 이동 중인 상황. MCU 응답만 늦춘다.
        mcu.delays["move"] = 10
        session = StopHoldSession(HoldPlan("취소", 2, 2, 1, 0, 0),
                                  GrblHoldMotion(motion), MockApplianceRun(30), lambda _: None)
        executor.hold_session = session
        joining = threading.Event()
        join = session.join

        def observed_join(timeout=None):
            joining.set()
            return join(timeout)

        monkeypatch.setattr(session, "join", observed_join)
        session.start()
        loop_task = asyncio.create_task(executor.run())
        try:
            await _until(lambda: "move" in mcu.cmds())
            feed(reader, {"type": "execute", "sequence_id": "next", "run_ref": "run-next",
                          "appliance_id": "microwave", "buttons": ["시작"],
                          "targets": {"시작": {"x_mm": 1, "y_mm": 1}}})
            await _until(joining.is_set)
            if scope == "estop":
                executor.handle_outlet_estop()
            else:
                feed(reader, {"type": "abort", "scope": scope, "run_ref": "run-next"})
            # join의 3초 완료를 기다리지 않고 정지가 MCU에 도착해야 한다.
            await _until(lambda: "stop" in mcu.cmds(), timeout=0.8)
            await _until(lambda: any(d.get("sequence_id") == "next" for d in writer.messages()))
            result = next(d for d in writer.messages() if d.get("sequence_id") == "next")
            if scope == "estop":
                assert result["type"] == "error" and result["reason"] == "estop_latched", result
            else:
                assert result["outcome"] == "stopped", result
                assert result["button_results"] == []
            assert mcu.cmds().count("move") == 1  # 이전 hold 이동만
            assert "press" not in mcu.cmds()
            assert not executor._busy
        finally:
            executor.estop_latched = True
            motion.request_stop()
            await asyncio.to_thread(session.join, 2)
            reader.feed_eof()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(loop_task, 4)
            await executor.shutdown()
            mcu.close()

    asyncio.run(scenario())


@pytest.mark.parametrize("stop", [False, True])
def test_preparation_reserves_execution_slot_and_cleans_up(monkeypatch, stop):
    """hold 해제 대기를 늦춰 두 번째 실행 거절과 정지 표시 보존을 함께 본다."""
    from rpi4.tests.test_act_hold import _controller, _hw, _link, _close, HOLD, TARGETS

    async def scenario():
        executor, client, task = await _link(_controller(), _hw())
        release_join = threading.Event()
        entered = threading.Event()
        try:
            await asyncio.wait_for(client.execute(["즉석밥", "시작"], targets=TARGETS,
                                                  hold=HOLD, appliance_id="microwave"), 3)
            await _until(lambda: (client.last_hold or {}).get("sim_phase") == "waiting_above_stop")
            session = executor.hold_session
            join = session.join
            def paused_join(timeout=None):
                entered.set()
                assert release_join.wait(3)
                return join(timeout)
            monkeypatch.setattr(session, "join", paused_join)
            # 송신 클라이언트의 단일 요청 제한과 별도로 실행기 수신 경계를 시험한다.
            writer = FakeWriter()
            executor._writer = writer
            message = {"type": "execute", "sequence_id": "first", "appliance_id": "microwave",
                       "buttons": ["시작"]}
            feed(executor._reader, message)
            await _until(entered.is_set)
            feed(executor._reader, {**message, "sequence_id": "second"})
            await _until(lambda: any(d.get("sequence_id") == "second" for d in writer.messages()), timeout=0.8)
            assert next(d for d in writer.messages() if d.get("sequence_id") == "second")["reason"] == "busy"
            if stop:
                feed(executor._reader, {"type": "abort"})
                await _until(lambda: executor._verify_stop)
            release_join.set()
            await executor.wait_idle()
            result = next(d for d in writer.messages() if d.get("sequence_id") == "first")
            assert result["outcome"] == ("stopped" if stop else "success")
            if stop:
                assert result["button_results"] == []
            assert not executor._busy and executor._execute_task is None
        finally:
            release_join.set()
            await _close(executor, client, task)
    asyncio.run(scenario())
