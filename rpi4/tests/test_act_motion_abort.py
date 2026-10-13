"""RPi4 결과 프레임이 모션 중단 원인과 실제 시도 수를 싣는다(2026-10-14, 보드 날 발견 2).

모션 알람(걸림)·MCU 재시작·기한 초과·준비 안 됨은 재시도하지 않고 바로 끝나며, 결과 프레임에 ``abort_reason``
(예: ``motion_alarm: stall``)을 싣는다. 원인이 없는 실행의 프레임 모양은 바뀌지 않는다(옛 RPi5 호환).
"""

from __future__ import annotations

import asyncio

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockRetryWaiter, MockSafetyController
from rpi.controller.models import ExecutionMode
from rpi.controller.serial_motion import MotionAlarm
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor
from rpi4.tests.test_act_executor import FakeWriter, _make_executor, feed


class _StallGrbl:
    execution_mode = ExecutionMode.REAL

    def __init__(self) -> None:
        self.presses = 0

    def press(self, command) -> None:
        self.presses += 1
        raise MotionAlarm("MCU 알람: stall", reason="stall")


def test_stall_result_frame_carries_cause_and_one_attempt():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        grbl = _StallGrbl()
        controller = ClosedLoopController(grbl, MockVerifier([True] * 10), MockAlertSink(),
                                          MockSafetyController(), retry_waiter=MockRetryWaiter())
        executor = ActExecutor(reader=reader, writer=writer, controller=controller)
        feed(reader, {"type": "execute", "appliance_id": "microwave", "sequence_id": "seq-stall",
                      "buttons": ["즉석밥", "시작"]})
        await executor.run_once()
        await executor.wait_idle()
        (result,) = [m for m in writer.messages() if m.get("type") == "result"]
        assert grbl.presses == 1
        assert result["success"] is False and result["outcome"] == "safety_stop"
        assert result["abort_reason"] == "motion_alarm: stall"
        assert result["retry"] == 0
        assert result["button_results"] == [{"button": "즉석밥", "ok": False, "attempts": 1, "layer": None,
                                              "corrections": []}]

    asyncio.run(_t())


def test_ordinary_result_frame_has_no_abort_field():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)
        feed(reader, {"type": "execute", "appliance_id": "microwave", "sequence_id": "seq-ok", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()
        (result,) = [m for m in writer.messages() if m.get("type") == "result"]
        assert "abort_reason" not in result

    asyncio.run(_t())
