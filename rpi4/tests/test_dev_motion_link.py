"""개발자 실물 경로 끝-끝(2026-10-10): RPi5 DeveloperSessionManager → ActDevMotionAdapter → ActClientController →
ActClient ⇄(메모리 파이프)⇄ ActExecutor → DevMotionService → SerialMotionClient ⇄ 가짜 모션 MCU.

양쪽 규약 구현을 실제로 맞물린다. 모션 MCU만 가짜(rpi/tools/fake_mcu.py, 솔레노이드)다 — **실물 미검증.**
"""

from __future__ import annotations

import asyncio
import dataclasses
import time
from datetime import datetime, timezone

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.serial_motion import InMemoryLinePipe, SerialMotionClient
from rpi.services.act_client import ActClient
from rpi.services.act_client_controller import ActClientController, start_background_loop
from rpi.services.control_arbiter import ControlArbiter
from rpi.services.dev_real_motion import ActDevMotionAdapter
from rpi.services.developer_session import DeveloperSessionManager
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu
from rpi.verifier import MockVerifier

from rpi4.services.act_executor import ActExecutor
from rpi4.services.dev_motion import DevMotionService

_CONFIG = dataclasses.replace(REHEARSAL_CONFIG, press_mode="duration", press_drive_ms=100,
                              press_dwell_ms=100, press_drive_max_ms=500)


class _PipeWriter:
    def __init__(self, loop: asyncio.AbstractEventLoop, peer: asyncio.StreamReader) -> None:
        self._loop = loop
        self._peer = peer

    def write(self, data: bytes) -> None:
        self._peer.feed_data(data)

    async def drain(self) -> None:
        pass


class _Clock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)


@pytest.fixture(params=[None, "pairing-key-for-tests-0123"], ids=["plain", "signed"])
def link(request):
    """``signed``: 두 쪽에 같은 짝 키(SIMPLELAY_LINK_KEY, 2026-10-12) — 개발자 조작도 서명된 봉투로 오간다."""
    loop, thread = start_background_loop()
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=False, z_mode="solenoid", solenoid_on_max_ms=800)
    motion = SerialMotionClient(pipe.host, _CONFIG, poll_s=0.01)
    motion.connect()

    async def build():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        controller = ClosedLoopController(grbl=MockGrblClient(), verifier=MockVerifier(outcomes=[True] * 10),
                                          alerts=MockAlertSink(), safety=MockSafetyController())
        executor = ActExecutor(reader=rpi4_reader, writer=_PipeWriter(loop, rpi5_reader), controller=controller,
                               dev_motion=DevMotionService(motion), link_key=request.param)
        executor.act_info = {"motion": "serial", "outlet": "none", "done_watch": []}
        task = asyncio.create_task(executor.run())
        client = ActClient(rpi5_reader, _PipeWriter(loop, rpi4_reader), hello=True, link_key=request.param)
        await client.start()
        return executor, task, client

    executor, task, client = asyncio.run_coroutine_threadsafe(build(), loop).result(5)
    act = ActClientController(loop, client)
    deadline = time.monotonic() + 3
    while not act.dev_motion_link()["act_info"].get("dev_motion_protocol") and time.monotonic() < deadline:
        time.sleep(0.01)
    yield act, mcu
    asyncio.run_coroutine_threadsafe(client.stop(), loop).result(5)
    loop.call_soon_threadsafe(task.cancel)
    time.sleep(0.05)
    loop.call_soon_threadsafe(loop.stop)
    thread.join(2)
    mcu.close()


def _manager(act) -> DeveloperSessionManager:
    return DeveloperSessionManager(
        adapter=ActDevMotionAdapter(lambda: act, max_step_mm=1.0),
        clock=_Clock(),
        arbiter=ControlArbiter(),
        is_calibrated=lambda _a: True,
        known_appliance=lambda a: a == "microwave",
        known_button=lambda _a, b: b == "BT-05",
        allow_real_adapter=True,
    )


def test_home_jog_press_and_stop_reach_the_motion_mcu(link) -> None:
    act, mcu = link
    manager = _manager(act)
    session = manager.start("microwave", "phone")

    refused = manager.submit(session.session_id, "microwave", "jog x + 1")
    assert refused.accepted is False and refused.code == "not_homed"
    assert "move" not in mcu.cmds()

    assert manager.submit(session.session_id, "microwave", "home").accepted
    jog = manager.submit(session.session_id, "microwave", "jog x + 1")
    assert jog.accepted, jog
    assert [d for d in mcu.received if d.get("cmd") == "move"][-1]["x_mm"] == pytest.approx(1.0, abs=0.05)
    press = manager.submit(session.session_id, "microwave", "press BT-05")
    assert press.accepted, press
    assert [d["mode"] for d in mcu.received if d.get("cmd") == "press"] == ["duration"]

    too_far = manager.submit(session.session_id, "microwave", "jog y + 2")
    assert too_far.accepted is False and too_far.code == "step_too_large"

    manager.emergency_stop("emergency_stop")
    deadline = time.monotonic() + 2
    while "stop" not in mcu.cmds() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert "stop" in mcu.cmds()
    assert manager.state().phase == "idle"
    manager.close()


def test_dev_stop_level_comes_back_through_both_boards(link) -> None:
    """정지 확인 단계(2026-10-13): RPi4가 MCU 응답·멈춤 확인을 읽어 RPi5 매니저까지 올린다(가짜 MCU)."""
    act, mcu = link
    manager = _manager(act)
    session = manager.start("microwave", "phone")
    assert manager.submit(session.session_id, "microwave", "home").accepted
    info = manager.emergency_stop("emergency_stop")
    assert info is not None and info["stop_level"] in ("mcu_ack", "verified")
    assert isinstance(info["ack_ms"], int)

    mcu.handlers["stop"] = lambda d: None  # 답하지 않는 MCU — '보냄'까지만
    info = manager.emergency_stop("emergency_stop")
    assert info == {"stop_level": "sent", "ack_ms": None}
    manager.close()


def test_sensor_read_reports_the_mcu_position(link) -> None:
    act, mcu = link
    manager = _manager(act)
    session = manager.start("microwave", "phone")
    manager.submit(session.session_id, "microwave", "home")
    manager.submit(session.session_id, "microwave", "jog y + 1")
    result = manager.submit(session.session_id, "microwave", "sensor read")
    assert result.accepted
    assert result.sensor["homed"] == 1.0
    assert result.sensor["y_mm"] == pytest.approx(1.0, abs=0.05)
    manager.close()
