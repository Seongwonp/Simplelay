"""정지·알람·원점 없음이면 누르기 전에 '준비 안 됨'으로 알린다 — 그리고 자동 원점이면 다음 새 실행이 원점부터(2026-10-19).

수리 전: 실행 중 정지로 모션 어댑터가 STOPPED(위치를 믿을 수 없어 재홈 필요)에 남아도 ``not_ready_reason``은 연결 확인
전(UNKNOWN)만 보고 None을 돌려줬다. RPi4는 준비됐다며 다음 실행을 받았고, 누를 때마다 ``motion_not_ready``로 실패했다
(자동 원점이 켜져 있어도 STOPPED에서는 원점을 잡지 않았다). 이제:

- STOPPED·ALARM, 그리고 자동 원점이 꺼진 UNHOMED는 준비 안 됨(이유 '원점을 다시 잡아야 해요')으로 누르기 전에 거절한다.
- 자동 원점이 켜져 있으면 지난 실행의 정지로 STOPPED가 된 어댑터는 **새로 승인된 다음 실행**(``reset_stop`` 뒤)이
  UNHOMED처럼 원점부터 잡는다. 정지된 그 실행 안에서는 여전히 원점을 다시 잡지 않는다(정지 표시가 남아 거절).
- 개발자 원점 잡기는 이 준비 확인에 막히지 않는다(연결 확인만) — 그래야 사람이 원점을 다시 잡을 수 있다.

전부 가짜 MCU다(실물 미검증).
"""

from __future__ import annotations

import asyncio
import json
import threading
import time
from dataclasses import replace

import pytest

from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionNotReady,
    MotionState,
    MotionStopped,
    SerialMotionClient,
)
from rpi.controller.models import PressCommand
from rpi.tests.test_serial_motion import TEST_CONFIG
from rpi.tools.fake_mcu import FakeMcu

READY_PHRASE = "원점을 다시 잡아야 해요"


@pytest.fixture
def link():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    yield pipe, mcu
    mcu.close()


def _client(pipe, **overrides) -> SerialMotionClient:
    config = replace(TEST_CONFIG, move_timeout_s=5.0, **overrides)
    client = SerialMotionClient(pipe.host, config, poll_s=0.01)
    client.connect()
    return client


def _stop_mid_move(client, mcu) -> None:
    held = mcu.handlers.get("move")
    mcu.handlers["move"] = lambda d: None  # 이동이 끝나지 않는다
    errors = []

    def _run():
        try:
            client.move_to(10.0, 10.0)
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    worker = threading.Thread(target=_run)
    worker.start()
    time.sleep(0.1)
    client.request_stop()
    worker.join(timeout=2.0)
    assert errors and isinstance(errors[0], MotionStopped)
    assert client.state is MotionState.STOPPED
    if held is None:
        mcu.handlers.pop("move", None)
    else:
        mcu.handlers["move"] = held


def test_stopped_is_not_ready_without_auto_home(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    assert client.not_ready_reason() is None
    _stop_mid_move(client, mcu)
    client.reset_stop()  # 다음 실행 경계
    reason = client.not_ready_reason()
    assert reason is not None and READY_PHRASE in reason
    # 연결 확인만 보는 쪽(개발자 원점 잡기)은 막지 않는다
    assert client.link_not_ready_reason() is None
    client.home()
    assert client.not_ready_reason() is None


def test_unhomed_is_not_ready_only_without_auto_home(link):
    pipe, _mcu = link
    manual = _client(pipe)
    assert manual.state is MotionState.UNHOMED
    reason = manual.not_ready_reason()
    assert reason is not None and READY_PHRASE in reason
    auto = _client(pipe, auto_home=True)
    assert auto.state is MotionState.UNHOMED
    assert auto.not_ready_reason() is None


def test_alarm_is_not_ready(link):
    pipe, mcu = link
    client = _client(pipe, auto_home=True)
    client.home()
    mcu.handlers["move"] = lambda d: [{"id": d["id"], "ok": False, "error": "stall"}]
    with pytest.raises(Exception):  # noqa: B017 - MotionAlarm
        client.move_to(10.0, 10.0)
    assert client.state is MotionState.ALARM
    reason = client.not_ready_reason()
    assert reason is not None and READY_PHRASE in reason


def test_auto_home_rehomes_the_next_fresh_run_after_a_stop(link):
    pipe, mcu = link
    client = _client(pipe, auto_home=True)
    client.home()
    _stop_mid_move(client, mcu)
    # 정지된 그 실행 안: 정지 표시가 남아 누르지도, 원점을 다시 잡지도 않는다
    before = mcu.cmds().count("home")
    with pytest.raises(MotionStopped):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds().count("home") == before
    # 새로 승인된 다음 실행(reset_stop) — 준비됨, 원점부터 잡고 누른다
    client.reset_stop()
    assert client.not_ready_reason() is None
    client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    tail = mcu.cmds()[-3:]
    assert tail == ["home", "move", "press"], mcu.cmds()


def test_auto_home_does_not_rehome_after_a_mid_run_reset_in_the_same_run(link):
    pipe, mcu = link
    client = _client(pipe, auto_home=True)
    client.home()
    _stop_mid_move(client, mcu)
    client.reset_stop()
    # 새 실행 안에서 MCU 재시작·통신 오류를 이미 본 상태(_run_busy·_request가 세우는 표시) — 이번 실행은 자동 재홈 금지
    client._reset_mid_run = True  # noqa: SLF001
    before = mcu.cmds().count("home")
    with pytest.raises(MotionNotReady):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds().count("home") == before


def test_rpi4_refuses_before_pressing_and_dev_home_is_still_allowed(link):
    from rpi.controller import ClosedLoopController
    from rpi.controller.mock import MockAlertSink, MockSafetyController
    from rpi.verifier import MockVerifier
    from rpi4.act_main import _motion_readiness
    from rpi4.services.act_executor import ActExecutor
    from rpi4.services.dev_motion import DevMotionService

    pipe, mcu = link
    client = _client(pipe)
    client.home()
    _stop_mid_move(client, mcu)
    client.reset_stop()

    class _Writer:
        def __init__(self):
            self.docs = []

        def write(self, data):
            self.docs.extend(json.loads(x) for x in data.splitlines() if x.strip())

        async def drain(self):
            pass

    async def _t():
        reader, writer = asyncio.StreamReader(), _Writer()
        controller = ClosedLoopController(client, MockVerifier([True]), MockAlertSink(), MockSafetyController())
        executor = ActExecutor(reader, writer, controller, readiness=_motion_readiness(client),
                               dev_motion=DevMotionService(client))
        reader.feed_data((json.dumps({"type": "execute", "sequence_id": "s-1", "buttons": ["시작"],
                                      "appliance_id": "microwave"}) + "\n").encode())
        await executor.run_once()
        await executor.wait_idle()
        return writer, executor._dev_refusal()  # noqa: SLF001

    presses_before = mcu.cmds().count("press")
    writer, dev_refusal = asyncio.run(_t())
    (error,) = [d for d in writer.docs if d.get("type") == "error"]
    assert error["reason"] == "motion_not_ready" and READY_PHRASE in error["detail"]
    assert mcu.cmds().count("press") == presses_before
    assert dev_refusal is None
