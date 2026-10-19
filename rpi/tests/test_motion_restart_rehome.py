"""실행기 시작·포트 재연결 뒤에는 MCU의 ``homed`` 보고를 믿지 않고 원점부터 다시 잡는다(2026-10-19).

수리 전: ``connect()``가 MCU의 ``homed: true``를 그대로 믿어 READY로 두었다. MCU 전원은 그대로인 채 RPi4 실행기만
다시 시작했거나(이동 도중 죽음 포함) 포트만 다시 붙었으면, 그사이 손으로 캐리지를 옮겼어도 원점 확인 없이 좌표로
이동·누름을 했다. 이제:

- 실행기 시작·포트 재연결 뒤 연결 확인(``connect``)은 MCU가 homed라고 해도 UNHOMED로 둔다. 이 프로세스의 ``home()``
  성공만 위치 기준을 되살린다(뒤이은 ``status()`` 조회도 되살리지 않는다).
- 자동 원점이 켜져 있으면 새로 승인된 다음 실행의 첫 누름이 원점부터 잡는다. 꺼져 있으면 준비 안 됨('원점을 다시 잡아야 해요').
- 포트를 잃었던 그 실행 안에서는 여전히 원점을 다시 잡지 않는다(``_reset_mid_run``).
- 개발자 원점 잡기는 막히지 않는다.

전부 가짜 MCU다(실물 미검증).
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionNotReady,
    MotionState,
    SerialMotionClient,
)
from rpi.tests.test_serial_motion import TEST_CONFIG
from rpi.tools.fake_mcu import FakeMcu

READY_PHRASE = "원점을 다시 잡아야 해요"


@pytest.fixture
def homed_link():
    """MCU 전원은 유지된 채(이미 homed라고 보고) 실행기만 새로 붙는 상황."""
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    yield pipe, mcu
    mcu.close()


def _client(pipe, **overrides) -> SerialMotionClient:
    config = replace(TEST_CONFIG, move_timeout_s=5.0, **overrides)
    return SerialMotionClient(pipe.host, config, poll_s=0.01)


def test_fresh_executor_does_not_trust_mcu_homed_flag(homed_link):
    pipe, _mcu = homed_link
    client = _client(pipe)
    status = client.connect()
    assert status.homed is True  # MCU는 homed라고 보고했다
    assert client.state is MotionState.UNHOMED
    reason = client.not_ready_reason()
    assert reason is not None and READY_PHRASE in reason
    # 뒤이은 상태 조회도 위치 기준을 되살리지 않는다
    client.status()
    assert client.state is MotionState.UNHOMED
    # 사람이(개발자 조작 등) 원점을 잡으면 준비된다
    assert client.link_not_ready_reason() is None
    client.home()
    assert client.state is MotionState.READY
    assert client.not_ready_reason() is None
    client.status()
    assert client.state is MotionState.READY


def test_fresh_executor_with_auto_home_homes_before_first_press(homed_link):
    pipe, mcu = homed_link
    client = _client(pipe, auto_home=True)
    client.connect()
    assert client.state is MotionState.UNHOMED
    assert client.not_ready_reason() is None
    client.reset_stop()  # 새로 승인된 실행
    client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds()[-3:] == ["home", "move", "press"], mcu.cmds()


def test_port_reconnect_requires_rehome_but_not_inside_the_same_run(homed_link):
    pipe, mcu = homed_link
    client = _client(pipe, auto_home=True)
    client.connect()
    client.home()
    assert client.state is MotionState.READY
    # 실행 도중 포트를 잃고 다시 붙었다 — MCU는 그대로 homed라고 보고한다
    client.note_link_down("test")
    client.connect()
    assert client.state is MotionState.UNHOMED
    # 포트를 잃었던 그 실행 안: 자동 재홈·재누름 없이 멈춘다
    homes = mcu.cmds().count("home")
    with pytest.raises(MotionNotReady):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds().count("home") == homes
    # 새로 승인된 다음 실행 — 원점부터 잡고 누른다
    client.reset_stop()
    assert client.not_ready_reason() is None
    client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds()[-3:] == ["home", "move", "press"], mcu.cmds()


def test_rpi4_startup_path_reports_rehome_needed(homed_link, monkeypatch):
    """RPi4 실행기 시작 경로(act_main ``_build_motion`` → ``connect``)가 MCU의 homed를 믿지 않고 준비 안 됨으로 둔다."""
    import rpi4.act_main as act_main
    from rpi.controller.serial_motion import MotionConfig

    pipe, mcu = homed_link
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    monkeypatch.setattr(MotionConfig, "from_env", classmethod(lambda cls, env=None: TEST_CONFIG))
    try:
        act_main._build_motion()
        client = act_main._motion_watch._client  # noqa: SLF001
        readiness = act_main._motion_readiness(client)  # noqa: SLF001
        assert readiness is not None
        reason = readiness()
        assert reason is not None and READY_PHRASE in reason
        assert "home" not in mcu.cmds() and "move" not in mcu.cmds()
        client.home()  # 개발자 원점 잡기와 같은 길
        assert readiness() is None
    finally:
        if act_main._motion_watch is not None:  # noqa: SLF001
            act_main._motion_watch.stop()  # noqa: SLF001
            act_main._motion_watch = None  # noqa: SLF001


def test_port_reconnect_without_auto_home_is_not_ready(homed_link):
    pipe, _mcu = homed_link
    client = _client(pipe)
    client.connect()
    client.home()
    assert client.not_ready_reason() is None
    client.note_link_down("test")
    client.connect()
    client.reset_stop()
    reason = client.not_ready_reason()
    assert reason is not None and READY_PHRASE in reason
    with pytest.raises(MotionNotReady):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
