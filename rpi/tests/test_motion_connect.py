"""모션 MCU 연결 — 포트 열기(자동 리셋 회피)·부트 잡음·ready 배너·status 재시도(2026-09-29).

메모리 파이프·가짜 MCU·가짜 pyserial 모듈로만 시험한다(실물 미검증). 실제 FireBeetle이 포트를 열 때
리셋되는지, 부트 로그가 어떤 줄인지는 보드로만 확인된다. 수치는 시험용 임의 값이다.
"""

from __future__ import annotations

import dataclasses
import logging
import threading
import time

import pytest

from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionConfig,
    MotionReset,
    MotionState,
    MotionTimeout,
    PySerialLineTransport,
    SerialMotionClient,
    heartbeat_off_warning,
)
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu

BOOT_NOISE = ("ets Jun  8 2016 00:22:57", "rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)", "\x00\xff{garbage")
CONFIG = dataclasses.replace(REHEARSAL_CONFIG, status_timeout_s=0.2, connect_timeout_s=2.0)


# ── 포트 열기 ────────────────────────────────────────────────────────────────


class _FakeSerial:
    """pyserial Serial 흉내 — 속성을 설정한 순서와 open 시점의 값을 남긴다."""

    log: list[tuple[str, object]] = []

    def __init__(self, *args, **kwargs) -> None:
        assert not args and not kwargs  # 인자로 열면 생성자에서 바로 열린다(DTR/RTS를 먼저 못 내린다)
        object.__setattr__(self, "is_open", False)
        object.__setattr__(self, "state_at_open", None)

    def __setattr__(self, name, value) -> None:
        type(self).log.append((name, value))
        object.__setattr__(self, name, value)

    def open(self) -> None:
        type(self).log.append(("open", None))
        object.__setattr__(
            self,
            "state_at_open",
            {k: getattr(self, k, None) for k in ("dtr", "rts", "dsrdtr", "rtscts", "xonxoff", "port", "baudrate")},
        )
        object.__setattr__(self, "is_open", True)

    def reset_input_buffer(self) -> None:
        type(self).log.append(("reset_input_buffer", None))


class _FakeSerialModule:
    Serial = _FakeSerial


def test_serial_port_opens_with_reset_lines_deasserted_before_open():
    _FakeSerial.log = []
    transport = PySerialLineTransport("/dev/ttyUSB9", 115200, serial_module=_FakeSerialModule)
    ser = transport._serial
    assert ser.is_open
    assert ser.state_at_open == {
        "dtr": False, "rts": False, "dsrdtr": False, "rtscts": False, "xonxoff": False,
        "port": "/dev/ttyUSB9", "baudrate": 115200,
    }
    names = [name for name, _ in _FakeSerial.log]
    assert names.index("dtr") < names.index("open") and names.index("rts") < names.index("open")
    assert names[-1] == "reset_input_buffer"  # 열기 전에 쌓인 줄은 버린다


# ── 부트 잡음·ready 배너 ──────────────────────────────────────────────────────


def test_connect_skips_boot_noise_and_retries_status_lost_during_boot(caplog):
    pipe = InMemoryLinePipe()
    events = []
    mcu = FakeMcu(pipe, ready_banner=True, boot_noise=BOOT_NOISE, boot_delay_s=0.4)
    client = SerialMotionClient(pipe.host, CONFIG, poll_s=0.01, on_event=lambda n, d: events.append(n))
    try:
        with caplog.at_level(logging.WARNING, logger="rpi.controller.serial_motion"):
            status = client.connect()
    finally:
        mcu.close()
    assert mcu.dropped_while_booting >= 1  # 부팅 중 보낸 status는 사라졌다
    assert status.homed is False and client.state is MotionState.UNHOMED
    assert client.ready_info == mcu.ready_event("poweron")
    assert "ready" in events
    assert client.connect_attempts >= 2
    assert client.link_not_ready_reason() is None  # 연결 확인은 됐다
    assert "원점을 다시 잡아야" in (client.not_ready_reason() or "")  # 자동 원점 꺼짐·원점 전 — 누르기 전 거절(2026-10-19)
    assert mcu.cmds() and set(mcu.cmds()) == {"status"}  # 연결 확인은 status만 — stop을 보내지 않는다
    assert not [r for r in caplog.records if "unparsable" in r.getMessage()]  # 부트 잡음은 경고하지 않는다


def test_stale_ready_banner_during_status_resends_the_query():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True, ready_banner=True)  # 배너가 이미 버퍼에 있다
    try:
        client = SerialMotionClient(pipe.host, CONFIG, poll_s=0.01)
        status = client.status()
    finally:
        mcu.close()
    assert status.homed is True and client.state is MotionState.READY
    assert client.ready_info is not None


def test_connect_backs_off_until_the_mcu_answers():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, boot_delay_s=0.7)  # 배너 없는 펌웨어(옛 빌드) — status 재시도만으로 붙는다
    try:
        client = SerialMotionClient(pipe.host, CONFIG, poll_s=0.01)
        started = time.monotonic()
        client.connect()
        elapsed = time.monotonic() - started
    finally:
        mcu.close()
    assert 0.6 <= elapsed < 2.0
    assert client.connect_attempts >= 3
    assert client.ready_info is None
    assert client.state is MotionState.UNHOMED


def test_connect_gives_up_after_budget_and_reports_not_ready():
    pipe = InMemoryLinePipe()  # 아무도 답하지 않는다
    config = dataclasses.replace(CONFIG, connect_timeout_s=0.6)
    client = SerialMotionClient(pipe.host, config, poll_s=0.01)
    assert client.not_ready_reason() == "모션 MCU 연결 확인 전"
    started = time.monotonic()
    with pytest.raises(MotionTimeout, match="연결 확인 실패"):
        client.connect()
    assert time.monotonic() - started < 1.5
    assert client.state is MotionState.UNKNOWN
    reason = client.not_ready_reason()
    assert reason is not None and "무응답" in reason
    sent = []
    while (line := pipe.device.read_line(0.0)) is not None:
        sent.append(line)
    assert sent and all('"status"' in line for line in sent)  # 연결 확인 중에는 stop을 보내지 않는다
    assert len(sent) == client.connect_attempts >= 2


def test_ready_during_a_motion_command_fails_it_and_requires_rehome():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, ready_banner=True)
    mcu.handlers["home"] = lambda d: None  # 답하기 전에 재부팅한다
    client = SerialMotionClient(pipe.host, CONFIG, poll_s=0.01)
    try:
        client.connect()
        threading.Timer(0.1, mcu.reboot, kwargs={"reset": "brownout"}).start()
        with pytest.raises(MotionReset, match="재시작"):
            client.home()
    finally:
        mcu.close()
    assert client.state is MotionState.UNHOMED
    assert client.ready_info == mcu.ready_event("brownout")


# ── heartbeat 끔 경고 ────────────────────────────────────────────────────────


def test_heartbeat_off_warning_text():
    assert heartbeat_off_warning(MotionConfig()) is None
    text = heartbeat_off_warning(MotionConfig.from_env({"SIMPLELAY_MOTION_HEARTBEAT_MS": "off"}))
    assert text is not None and "host_timeout" in text and "2 s" in text


def test_connect_timeout_env_and_validation():
    assert MotionConfig().connect_timeout_s == 5.0
    assert MotionConfig.from_env({"SIMPLELAY_MOTION_CONNECT_TIMEOUT_S": "8"}).connect_timeout_s == 8.0
    with pytest.raises(ValueError):
        MotionConfig(connect_timeout_s=0)
