"""Real hub/executor frames through the unchanged Touch Bridge wire protocol."""

from __future__ import annotations

import asyncio
import contextlib
import time
from datetime import datetime, timezone

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink
from rpi.controller.models import ButtonTarget, ExecutionStatus
from rpi.controller.serial_motion import MotionSafetyController
from rpi.controller.touchbridge_motion import TouchBridgeConfig, TouchBridgeMotionClient
from rpi.services.act_client import ActClient
from rpi.services.act_client_controller import ActClientController, start_background_loop
from rpi.services.control_arbiter import ControlArbiter
from rpi.services.dev_real_motion import ActDevMotionAdapter
from rpi.services.developer_session import DeveloperSessionManager
from rpi.tests.test_touchbridge_motion import ReceivedSketch
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor
from rpi4.services.dev_motion import DevMotionService


class Writer:
    def __init__(self, peer):
        self.peer = peer

    def write(self, data):
        self.peer.feed_data(data)

    async def drain(self):
        pass


class Clock:
    def now(self):
        return datetime.now(timezone.utc)


@pytest.fixture(params=[None, "touchbridge-test-link-key-0123"], ids=["plain", "signed"])
def link(request):
    mcu = ReceivedSketch()
    motion = TouchBridgeMotionClient(mcu.pipe.host, TouchBridgeConfig(status_timeout_s=0.3))
    motion.connect()
    loop, thread = start_background_loop()

    async def build():
        to_act, to_hub = asyncio.StreamReader(), asyncio.StreamReader()
        controller = ClosedLoopController(grbl=motion, verifier=MockVerifier(outcomes=[True] * 10),
                                          alerts=MockAlertSink(), safety=MotionSafetyController(motion))
        executor = ActExecutor(reader=to_act, writer=Writer(to_hub), controller=controller,
                               readiness=motion.not_ready_reason, dev_motion=DevMotionService(motion),
                               motion_stop=motion, link_key=request.param)
        executor.act_info = {"motion": "serial", "motion_protocol": "touchbridge-v2"}
        task = asyncio.create_task(executor.run())
        hub = ActClient(to_hub, Writer(to_act), hello=True, link_key=request.param)
        await hub.start()
        return hub, task

    hub, task = asyncio.run_coroutine_threadsafe(build(), loop).result(3)
    act = ActClientController(loop, hub)
    deadline = time.monotonic() + 2
    while not act.dev_motion_link()["act_info"].get("dev_motion_protocol"):
        assert time.monotonic() < deadline
        time.sleep(0.01)
    try:
        yield act, mcu
    finally:
        async def finish():
            await hub.stop()
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        asyncio.run_coroutine_threadsafe(finish(), loop).result(3)
        loop.call_soon_threadsafe(loop.stop)
        thread.join(2)
        motion.close()
        mcu.close()


def test_hub_developer_read_jog_press_and_stop_use_received_protocol_without_home(link):
    act, mcu = link
    manager = DeveloperSessionManager(
        adapter=ActDevMotionAdapter(lambda: act), clock=Clock(), arbiter=ControlArbiter(),
        is_calibrated=lambda _: True, known_appliance=lambda a: a == "microwave",
        known_button=lambda _a, b: b == "start", allow_real_adapter=True,
    )
    try:
        session = manager.start("microwave", "phone")
        sensor = manager.submit(session.session_id, "microwave", "sensor read")
        assert sensor.accepted and sensor.sensor["x_mm"] == 12.5
        assert manager.submit(session.session_id, "microwave", "jog x + 1").accepted
        assert manager.submit(session.session_id, "microwave", "jog y + 1").accepted
        result = manager.submit(session.session_id, "microwave", "press start")
        assert result.accepted, result
        stop = manager.emergency_stop("emergency_stop")
        assert stop["stop_level"] == "mcu_ack"
        assert "home" not in [c["action"] for c in mcu.commands]
    finally:
        manager.close()


def test_normal_execute_targets_reach_touchbridge_as_mm_and_same_move_token(link):
    act, mcu = link
    act.arm_execute_target("microwave")
    act.reset_stop()
    result = act.execute(["start"], targets={"start": ButtonTarget(45.5, 82.25)})
    assert result.status is ExecutionStatus.SUCCEEDED, result
    move = next(c for c in mcu.commands if c["action"] == "move_only")
    press = next(c for c in mcu.commands if c["action"] == "press")
    assert move["target"] == {"xMm": 45.5, "yMm": 82.25}
    assert press["positionToken"] == mcu.token
