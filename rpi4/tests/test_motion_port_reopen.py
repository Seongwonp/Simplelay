"""모션 포트가 USB 재열거로 사라진 뒤 다시 열기(2026-10-14, 보드 날 발견 1).

10/13 실물: 모터 배터리를 꽂는 순간 RPi4 저전압 → ESP32가 ``ttyACM0``에서 ``ttyACM1``로 다시 잡혔다. 실행기는 사라진
포트에 계속 쓰다 EIO가 났고 다시 열지 못했다(실행기 재시작으로만 복구). 여기서는 가짜 시리얼(메모리 파이프 + 끊기는
포트)로만 본다 — 실물 재열거 재현은 다음 보드 날.

지키는 것: 쓰기·읽기 EIO나 포트 사라짐이면 포트를 닫고 설정 경로(by-id 권장)로 백오프하며 다시 연다. 다시 연결을
확인하기 전에는 준비 안 됨으로 보고하고, 같은 실행 안의 자동 재홈·재누름 차단은 그대로 둔다.
"""

from __future__ import annotations

import asyncio
import errno
import json
import time
from dataclasses import replace

import pytest

from rpi.controller import PressCommand
from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionNotReady,
    MotionState,
    ReopeningLineTransport,
    SerialMotionClient,
)
from rpi.tests.test_serial_motion import TEST_CONFIG
from rpi.tools.fake_mcu import FakeMcu

import rpi4.act_main as act_main

BY_ID = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_TEST-if00"


class _DyingPort:
    """끊길 수 있는 포트 — ``dead``가 되면 쓰기·읽기가 EIO(USB 재열거로 사라진 ttyACM0)."""

    def __init__(self, inner) -> None:
        self.inner = inner
        self.dead = False
        self.closed = False

    def write_line(self, line: str) -> None:
        if self.dead:
            raise OSError(errno.EIO, "Input/output error")
        self.inner.write_line(line)

    def read_line(self, timeout_s: float):
        if self.dead:
            raise OSError(errno.EIO, "Input/output error")
        return self.inner.read_line(timeout_s)

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def mcus():
    made = []

    def make():
        pipe = InMemoryLinePipe()
        pipe.fake = FakeMcu(pipe)
        made.append(pipe.fake)
        return pipe

    yield make
    for mcu in made:
        mcu.close()


def test_eio_closes_the_port_and_reopens_the_configured_path_with_backoff(mcus):
    pipe1, pipe2 = mcus(), mcus()
    first = _DyingPort(pipe1.host)
    plan: list = [FileNotFoundError(errno.ENOENT, f"could not open port {BY_ID}"), pipe2.host]
    opened: list[int] = []

    def opener():
        opened.append(1)
        item = plan.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    now = [100.0]
    transport = ReopeningLineTransport(opener, describe=BY_ID, initial=first, backoff_s=(0.5, 1.0),
                                       clock=lambda: now[0])
    client = SerialMotionClient(transport, replace(TEST_CONFIG, auto_home=True), poll_s=0.01)
    transport.set_link_listener(client.note_link_down)
    client.connect()
    client.home()
    assert client.not_ready_reason() is None

    first.dead = True  # 모터 전원 투입 → 저전압 → USB 재열거
    with pytest.raises(OSError):
        client.status()
    assert first.closed  # 죽은 포트를 붙잡지 않는다
    assert transport.link_down_reason is not None
    reason = client.not_ready_reason()
    assert reason is not None and "끊" in reason  # 준비 안 됨으로 보고
    with pytest.raises(OSError):
        client.status()  # 다시 열기 전에는 죽은 포트에 쓰지 않는다

    assert transport.try_reopen() is False and opened == []  # 백오프 전
    now[0] += 0.5
    assert transport.try_reopen() is False and len(opened) == 1  # by-id 경로가 아직 없다(재열거 중)
    now[0] += 0.5
    assert transport.try_reopen() is False and len(opened) == 1  # 다음 간격 1.0 s 전
    now[0] += 0.5
    assert transport.try_reopen() is True and len(opened) == 2
    assert transport.link_down_reason is None
    assert client.not_ready_reason() is not None  # 포트는 열렸지만 연결 확인 전

    client.connect()  # 새 MCU(재부팅) — 원점 기준 없음
    assert client.not_ready_reason() is None
    assert client.state is MotionState.UNHOMED
    # 같은 실행 안에서는 auto_home이 켜져 있어도 스스로 재홈·재누름하지 않는다(기존 차단 규칙 유지).
    with pytest.raises(MotionNotReady):
        client.press(PressCommand("시작", x_mm=10.0, y_mm=10.0))
    assert "home" not in pipe2.fake.cmds() and "press" not in pipe2.fake.cmds()


def test_reopened_port_carries_new_commands(mcus):
    pipe1, pipe2 = mcus(), mcus()
    first = _DyingPort(pipe1.host)
    transport = ReopeningLineTransport(lambda: pipe2.host, describe=BY_ID, initial=first, backoff_s=(0.0,))
    client = SerialMotionClient(transport, TEST_CONFIG, poll_s=0.01)
    transport.set_link_listener(client.note_link_down)
    client.connect()
    first.dead = True
    with pytest.raises(OSError):
        client.status()
    assert transport.try_reopen() is True
    status = client.connect()
    assert status.homed is False
    client.reset_stop()  # 사람의 다음 요청 경계
    client.home()
    assert client.state is MotionState.READY


def test_act_main_watch_reopens_and_reconnects_without_restarting_the_executor(monkeypatch, mcus):
    pipe1, pipe2 = mcus(), mcus()
    first = _DyingPort(pipe1.host)
    ports = [first, pipe2.host]
    opened: list[tuple[str, int]] = []

    def fake_open(port, baud):
        opened.append((port, baud))
        return ports.pop(0)

    monkeypatch.setattr(act_main, "_open_motion_transport", fake_open)
    monkeypatch.setattr(act_main, "MOTION_REOPEN_BACKOFF_S", (0.05, 0.1))
    monkeypatch.setattr(act_main, "MOTION_WATCH_INTERVAL_S", 0.02)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", BY_ID)
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setenv("SIMPLELAY_MOTION_STATUS_TIMEOUT_S", "1")
    try:
        grbl, _ = act_main._build_motion()
        assert grbl.not_ready_reason() is None
        first.dead = True
        with pytest.raises(OSError):
            grbl.status()
        assert grbl.not_ready_reason() is not None
        deadline = time.monotonic() + 5.0
        while grbl.not_ready_reason() is not None and time.monotonic() < deadline:
            time.sleep(0.02)
        assert grbl.not_ready_reason() is None  # 배경에서 다시 열고 연결 확인까지 했다
        assert opened == [(BY_ID, 115200), (BY_ID, 115200)]  # 같은 설정 경로로 다시 열었다
    finally:
        if act_main._motion_watch is not None:
            act_main._motion_watch.stop()
            act_main._motion_watch = None


def test_executor_reports_not_ready_while_the_port_is_down(monkeypatch, mcus):
    pipe1 = mcus()
    first = _DyingPort(pipe1.host)

    def fake_open(port, baud):
        if fake_open.calls:
            raise FileNotFoundError(errno.ENOENT, f"could not open port {port}")
        fake_open.calls += 1
        return first

    fake_open.calls = 0
    monkeypatch.setattr(act_main, "_open_motion_transport", fake_open)
    monkeypatch.setattr(act_main, "MOTION_REOPEN_BACKOFF_S", (30.0,))
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", BY_ID)
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setenv("SIMPLELAY_MOTION_STATUS_TIMEOUT_S", "1")

    class _Writer:
        def __init__(self) -> None:
            self.lines: list[dict] = []

        def write(self, data: bytes) -> None:
            self.lines.extend(json.loads(x) for x in data.splitlines() if x.strip())

        async def drain(self) -> None:
            pass

    async def _t():
        reader = asyncio.StreamReader()
        writer = _Writer()
        executor = act_main._build_executor(reader, writer)  # type: ignore[arg-type]
        first.dead = True
        with pytest.raises(OSError):
            executor._controller._grbl.status()  # noqa: SLF001 -- 끊김을 일으킨다
        line = json.dumps({"type": "execute", "appliance_id": "microwave", "sequence_id": "seq-down",
                           "buttons": ["시작"]}, ensure_ascii=False)
        reader.feed_data((line + "\n").encode("utf-8"))
        await executor.run_once()
        await executor.wait_idle()
        return writer.lines

    try:
        lines = asyncio.run(_t())
    finally:
        if act_main._motion_watch is not None:
            act_main._motion_watch.stop()
            act_main._motion_watch = None
    assert lines[-1]["type"] == "error" and lines[-1]["reason"] == "motion_not_ready"
    assert "끊" in lines[-1]["detail"]


def test_tty_name_port_logs_a_by_id_hint(monkeypatch, caplog, mcus):
    pipe = mcus()
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/ttyACM0")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setenv("SIMPLELAY_MOTION_STATUS_TIMEOUT_S", "1")
    try:
        with caplog.at_level("WARNING"):
            act_main._build_motion()
    finally:
        if act_main._motion_watch is not None:
            act_main._motion_watch.stop()
            act_main._motion_watch = None
    assert any("/dev/serial/by-id" in r.getMessage() for r in caplog.records)
