"""모션 MCU 어댑터 — 메모리 파이프 + 가짜 MCU로만 시험한다(실물 미검증).

**여기의 기구·누름·타임아웃 수치는 전부 시험용 임의 값이다.** 실물 값이 아니다.
"""

from __future__ import annotations

import json
import threading
import time

import pytest

from rpi.controller import (
    ButtonTarget,
    ClosedLoopController,
    Correction,
    ExecutionMode,
    ExecutionStatus,
    MissingButtonCoordinates,
    PressCommand,
)
from rpi.controller.kinematics import CoreXYConfig, KinematicsNotConfigured, SoftLimitExceeded
from rpi.controller.mock import MockAlertSink
from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionAlarm,
    MotionConfig,
    MotionConfigError,
    MotionRefused,
    MotionSafetyController,
    MotionState,
    MotionStopped,
    MotionTimeout,
    SerialMotionClient,
)
from rpi.tools.fake_mcu import FakeMcu
from rpi.verifier import MockVerifier

# 시험용 임의 값 — 실물 값 아님
TEST_KIN = CoreXYConfig(
    counts_per_output_rev=1000.0,
    pulley_teeth=10,
    belt_pitch_mm=3.0,
    x_min_mm=0.0,
    x_max_mm=100.0,
    y_min_mm=0.0,
    y_max_mm=100.0,
    a_sign=1,
    b_sign=1,
)
TEST_CONFIG = MotionConfig(
    kinematics=TEST_KIN,
    press_mode="depth",
    press_depth_counts=40,
    press_depth_step_counts=10,
    press_depth_max_counts=60,
    press_dwell_ms=100,
    retry_xy_offsets_mm=((0.5, 0.0), (-0.5, 0.0)),
    status_timeout_s=1.0,
    home_timeout_s=1.0,
    move_timeout_s=1.0,
    press_timeout_s=1.0,
)


@pytest.fixture
def link():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    yield pipe, mcu
    mcu.close()


def _client(pipe, config=TEST_CONFIG, **kwargs) -> SerialMotionClient:
    return SerialMotionClient(pipe.host, config, poll_s=0.01, **kwargs)


def _homed_client(pipe, config=TEST_CONFIG, **kwargs) -> SerialMotionClient:
    client = _client(pipe, config, **kwargs)
    client.home()
    return client


@pytest.mark.parametrize("failure", ["timeout", "write"])
def test_uncertain_press_never_rehomes_or_represses_in_same_run(link, monkeypatch, failure):
    from dataclasses import replace

    pipe, mcu = link
    client = _homed_client(pipe, replace(TEST_CONFIG, auto_home=True, press_timeout_s=0.03))
    original_write = pipe.host.write_line
    sent = []

    def write(line):
        doc = json.loads(line)
        sent.append(doc["cmd"])
        if doc["cmd"] == "press" and sent.count("press") == 1:
            if failure == "write":
                raise OSError("uncertain serial write")
            return  # 응답 유실을 모의한다.
        original_write(line)

    monkeypatch.setattr(pipe.host, "write_line", write)
    controller = ClosedLoopController(client, MockVerifier([True]), MockAlertSink(), MotionSafetyController(client))
    result = controller.execute(["시작"], targets={"시작": ButtonTarget(1, 1)})
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert sent.count("press") == 1
    assert "home" not in sent
    assert sent.count("move") == 1
    # 사람의 다음 요청 경계에서만 해제한다.
    client.reset_stop()
    client.press(PressCommand("시작", x_mm=1, y_mm=1))
    assert sent.count("home") == 1
    assert sent.count("press") == 2


def test_declares_real_execution_and_requires_coordinates():
    assert SerialMotionClient.execution_mode is ExecutionMode.REAL
    assert SerialMotionClient.requires_coordinates is True


def test_default_config_refuses_everything_before_sending(link):
    pipe, mcu = link
    client = _client(pipe, MotionConfig())
    with pytest.raises(MotionConfigError):
        client.status()
    with pytest.raises(MotionConfigError):
        client.home()
    with pytest.raises(KinematicsNotConfigured):
        client.move_to(1.0, 1.0)
    with pytest.raises(KinematicsNotConfigured):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    time.sleep(0.05)
    assert mcu.received == []  # 아무것도 MCU로 나가지 않았다


def test_status_reports_unhomed_until_home(link):
    pipe, mcu = link
    client = _client(pipe)
    status = client.connect()
    assert status.homed is False
    assert client.state is MotionState.UNHOMED
    client.home()
    assert client.state is MotionState.READY
    assert mcu.cmds() == ["status", "home"]


def test_status_trusts_mcu_homed_report():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    try:
        client = _client(pipe)
        client.connect()
        assert client.homed
    finally:
        mcu.close()


def test_status_alarm_blocks_motion(link):
    pipe, mcu = link
    mcu.handlers["status"] = lambda d: [{"id": d["id"], "ok": True, "state": "alarm", "homed": True, "alarm": "limit"}]
    client = _client(pipe)
    client.connect()
    assert client.state is MotionState.ALARM
    with pytest.raises(MotionRefused):
        client.move_to(10.0, 10.0)


def test_move_refused_before_home(link):
    pipe, mcu = link
    client = _client(pipe)
    with pytest.raises(MotionRefused, match="원점"):
        client.move_to(10.0, 10.0)
    assert mcu.received == []


def test_move_sends_motor_counts_from_kinematics(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    client.move_to(10.0, 5.0)
    move = mcu.received[-1]
    # ΔA = 15 mm → 500, ΔB = 5 mm → 166.67 → 167 (시험용 값)
    assert (move["cmd"], move["a"], move["b"]) == ("move", 500, 167)
    assert (move["x_mm"], move["y_mm"]) == (10.0, 5.0)
    assert client.state is MotionState.READY


def test_soft_limit_refuses_before_sending(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    sent = len(mcu.received)
    with pytest.raises(SoftLimitExceeded):
        client.move_to(150.0, 5.0)
    with pytest.raises(SoftLimitExceeded):
        client.press(PressCommand("시작", x_mm=50.0, y_mm=-1.0))
    time.sleep(0.05)
    assert len(mcu.received) == sent


def test_press_without_coordinates_is_refused(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    with pytest.raises(MotionRefused, match="좌표"):
        client.press(PressCommand("시작"))
    assert mcu.cmds() == ["home"]


def test_press_moves_then_presses_with_configured_depth(link):
    pipe, mcu = link
    events = []
    client = _homed_client(pipe, on_event=lambda name, fields: events.append(name))
    client.press(PressCommand("시작", x_mm=20.0, y_mm=10.0))
    assert mcu.cmds() == ["home", "move", "press"]
    press = mcu.received[-1]
    assert press == {"id": press["id"], "cmd": "press", "mode": "depth", "z_counts": 40, "dwell_ms": 100}
    # 2026-09-29: 가짜 MCU가 move·press ok 직전에 선택 이벤트 position을 보낸다(펌웨어와 같음).
    assert [e for e in events if e != "position"] == ["press_command", "press_start", "press_end", "press_done"]
    assert events.count("position") == 2


def test_button_press_ms_overrides_configured_dwell(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    client.press(PressCommand("시작", x_mm=20.0, y_mm=10.0, press_ms=250))
    assert mcu.received[-1]["dwell_ms"] == 250


def test_duration_mode_sends_drive_ms(link):
    pipe, mcu = link
    config = MotionConfig(
        kinematics=TEST_KIN,
        press_mode="duration",
        press_drive_ms=120,
        press_dwell_ms=80,
        move_timeout_s=1.0,
        press_timeout_s=1.0,
        home_timeout_s=1.0,
    )
    client = _homed_client(pipe, config)
    client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    press = mcu.received[-1]
    assert (press["mode"], press["drive_ms"], press["dwell_ms"]) == ("duration", 120, 80)


def test_press_mode_unset_refuses(link):
    pipe, mcu = link
    config = MotionConfig(kinematics=TEST_KIN, home_timeout_s=1.0, move_timeout_s=1.0, press_timeout_s=1.0)
    client = _homed_client(pipe, config)
    with pytest.raises(MotionConfigError, match="press_mode"):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds() == ["home"]  # 이동도 하지 않았다


def test_retry_correction_uses_configured_offset_and_deeper_press(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    client.press(
        PressCommand("시작", Correction(2, xy_adjustment_required=True, increase_press_depth=True), x_mm=20.0, y_mm=10.0)
    )
    move, press = mcu.received[-2], mcu.received[-1]
    assert move["x_mm"] == pytest.approx(19.5)  # 두 번째 오프셋(-0.5, 0)
    assert press["z_counts"] == 60  # 40 + 10*2, 상한 60 이내


def test_retry_depth_above_cap_is_refused(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    with pytest.raises(MotionRefused, match="상한"):
        client.press(PressCommand("시작", Correction(3, False, True), x_mm=20.0, y_mm=10.0))
    assert mcu.cmds() == ["home"]


def test_retry_without_offsets_configured_is_refused(link):
    pipe, mcu = link
    config = MotionConfig(**{**TEST_CONFIG.__dict__, "retry_xy_offsets_mm": None})
    client = _homed_client(pipe, config)
    with pytest.raises(MotionConfigError, match="retry_xy_offsets_mm"):
        client.press(PressCommand("시작", Correction(1, True, False), x_mm=20.0, y_mm=10.0))


def test_auto_home_only_when_enabled(link):
    pipe, mcu = link
    client = _client(pipe)
    with pytest.raises(MotionRefused):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    auto = _client(pipe, MotionConfig(**{**TEST_CONFIG.__dict__, "auto_home": True}))
    auto.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    assert mcu.cmds() == ["home", "move", "press"]


def test_timeout_sends_stop_and_requires_rehome(link):
    pipe, mcu = link
    config = MotionConfig(**{**TEST_CONFIG.__dict__, "move_timeout_s": 0.1})
    client = _homed_client(pipe, config)
    mcu.handlers["move"] = lambda d: None  # 응답 없음
    with pytest.raises(MotionTimeout):
        client.move_to(10.0, 10.0)
    time.sleep(0.05)
    assert mcu.cmds()[-1] == "stop"
    assert client.state is MotionState.UNHOMED
    with pytest.raises(MotionRefused):
        client.move_to(10.0, 10.0)


def test_late_reply_for_abandoned_request_is_not_taken_as_next_reply(link):
    pipe, mcu = link
    config = MotionConfig(**{**TEST_CONFIG.__dict__, "move_timeout_s": 0.1})
    client = _homed_client(pipe, config)
    held = []
    mcu.handlers["move"] = lambda d: held.append(d) or None
    with pytest.raises(MotionTimeout):
        client.move_to(10.0, 10.0)
    # 늦은 응답이 도착한 뒤 재홈 → 다음 이동은 자기 응답을 기다린다
    pipe.device.write_line(json.dumps({"id": held[0]["id"], "ok": True}))
    client.home()
    mcu.handlers["move"] = lambda d: None
    with pytest.raises(MotionTimeout):
        client.move_to(20.0, 20.0)


def test_mcu_error_reply_raises_alarm(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    mcu.handlers["move"] = lambda d: [{"id": d["id"], "ok": False, "error": "stall"}]
    with pytest.raises(MotionAlarm, match="stall"):
        client.move_to(10.0, 10.0)
    assert client.state is MotionState.ALARM


def test_unsolicited_alarm_event_aborts_wait(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    mcu.handlers["move"] = lambda d: [{"event": "alarm", "reason": "limit"}]
    with pytest.raises(MotionAlarm, match="limit"):
        client.move_to(10.0, 10.0)
    assert client.state is MotionState.ALARM


def test_garbage_lines_are_ignored(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    mcu.handlers["move"] = lambda d: ["not json", "[1,2]", {"id": d["id"], "ok": True}]
    client.move_to(10.0, 10.0)


def test_request_stop_interrupts_a_blocking_move_from_another_thread(link):
    pipe, mcu = link
    config = MotionConfig(**{**TEST_CONFIG.__dict__, "move_timeout_s": 5.0})
    client = _homed_client(pipe, config)
    mcu.handlers["move"] = lambda d: None  # 이동이 끝나지 않는 상황
    errors = []

    def _run():
        try:
            client.move_to(10.0, 10.0)
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    worker = threading.Thread(target=_run)
    started = time.monotonic()
    worker.start()
    time.sleep(0.1)
    client.request_stop()
    worker.join(timeout=2.0)
    assert time.monotonic() - started < 2.0  # 기한(5s)까지 기다리지 않았다
    assert isinstance(errors[0], MotionStopped)
    assert "stop" in mcu.cmds()
    assert client.state is MotionState.STOPPED
    # 정지 뒤: reset_stop만으로는 준비되지 않는다 — 재홈 필요
    client.reset_stop()
    with pytest.raises(MotionRefused):
        client.move_to(10.0, 10.0)
    client.home()
    assert client.homed


def test_stop_request_refuses_new_commands_until_reset(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    client.request_stop()
    with pytest.raises(MotionStopped):
        client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))
    client.reset_stop()
    client.press(PressCommand("시작", x_mm=1.0, y_mm=1.0))


def test_env_config_parses_offsets_and_mode():
    config = MotionConfig.from_env(
        {
            "SIMPLELAY_MOTION_PRESS_MODE": "Duration",
            "SIMPLELAY_MOTION_RETRY_XY_OFFSETS_MM": "0.5,0; -0.5,0",
            "SIMPLELAY_MOTION_AUTO_HOME": "true",
            "SIMPLELAY_MOTION_PRESS_TIMEOUT_S": "3",
        }
    )
    assert config.press_mode == "duration"
    assert config.retry_xy_offsets_mm == ((0.5, 0.0), (-0.5, 0.0))
    assert config.auto_home is True
    assert config.press_timeout_s == 3.0
    assert config.kinematics == CoreXYConfig()


def test_missing_for_press_lists_everything_unset():
    missing = MotionConfig().missing_for_press()
    for name in ("counts_per_output_rev", "pulley_teeth", "belt_pitch_mm", "x_max_mm", "a_sign", "press_mode"):
        assert name in missing
    assert TEST_CONFIG.missing_for_press() == ()


# ── 폐루프와 함께 ─────────────────────────────────────────────────────────


def _controller(client: SerialMotionClient) -> ClosedLoopController:
    return ClosedLoopController(
        grbl=client,
        verifier=MockVerifier(outcomes=[True] * 10),
        alerts=MockAlertSink(),
        safety=MotionSafetyController(client),
    )


def test_closed_loop_refuses_sequence_with_uncalibrated_button_before_moving(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    controller = _controller(client)
    with pytest.raises(MissingButtonCoordinates) as info:
        controller.execute(["해동", "시작"], {"해동": ButtonTarget(10.0, 10.0)})
    assert info.value.missing == ("시작",)
    assert mcu.cmds() == ["home"]


def test_closed_loop_drives_adapter_with_coordinates(link):
    pipe, mcu = link
    client = _homed_client(pipe)
    controller = _controller(client)
    result = controller.execute(
        ["해동", "시작"],
        {"해동": ButtonTarget(10.0, 10.0), "시작": ButtonTarget(30.0, 20.0, press_ms=150)},
    )
    assert result.status is ExecutionStatus.SUCCEEDED
    assert controller.execution_mode is ExecutionMode.REAL
    assert mcu.cmds() == ["home", "move", "press", "move", "press"]
    assert mcu.received[-1]["dwell_ms"] == 150


def test_closed_loop_stop_reaches_the_adapter_mid_press(link):
    pipe, mcu = link
    config = MotionConfig(**{**TEST_CONFIG.__dict__, "press_timeout_s": 5.0})
    client = _homed_client(pipe, config)
    controller = _controller(client)
    mcu.handlers["press"] = lambda d: None  # Z가 내려간 채 응답 없음
    results = []
    worker = threading.Thread(
        target=lambda: results.append(controller.execute(["시작"], {"시작": ButtonTarget(10.0, 10.0)}))
    )
    started = time.monotonic()
    worker.start()
    time.sleep(0.15)
    controller.request_stop()
    worker.join(timeout=3.0)
    assert time.monotonic() - started < 3.0
    assert results[0].status is ExecutionStatus.SAFETY_STOPPED
    assert "stop" in mcu.cmds()
    assert mcu.cmds().count("press") == 1  # 정지 뒤 재시도하지 않았다
