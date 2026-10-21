"""Z 누름 방식(모터/솔레노이드)·위치 일치 검사·보드 설정 한 파일 — 2026-10-05 팀원 코드 합치기 준비.

메모리 파이프와 가짜 MCU로만 시험한다(실물 미검증). 솔레노이드 시간·냉각 값, 위치 허용 오차는
시험용 임의 값이며 실측값이 아니다.

1. MCU가 ``ready``·``status``에 ``z_mode``를 실어 보내면 호스트가 알고, 솔레노이드면 ``depth`` 누름을
   **움직이기 전에** 거절한다. 필드가 없는 MCU(팀원 펌웨어 원본)는 제한하지 않는다(MCU가 거절한다).
2. 솔레노이드 MCU의 거절(``z_unsupported``·``z_cooldown``)은 위치를 잃지 않은 거절이라 재홈을 요구하지 않는다.
3. 이동 뒤 MCU가 보고한 엔코더 위치가 명령 카운트와 허용 오차 넘게 다르면 그 이동을 실패로 끝내고
   재홈 전까지 준비 안 됨으로 둔다(가짜 MCU에 미끄럼을 주입).
"""

from __future__ import annotations

import dataclasses
import json
import re
from pathlib import Path

import pytest

from rpi.controller import PressCommand
from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionConfig,
    MotionPositionMismatch,
    MotionRefused,
    MotionState,
    SerialMotionClient,
)
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu

ROOT = Path(__file__).resolve().parents[2]
FW = ROOT / "firmware-motion"
TABLE = json.loads((FW / "protocol_table.json").read_text(encoding="utf-8"))

DURATION = dataclasses.replace(REHEARSAL_CONFIG, press_mode="duration", press_drive_ms=120)
SWITCHBOT = MotionConfig(
    kinematics=REHEARSAL_CONFIG.kinematics,
    status_timeout_s=1.0,
    home_timeout_s=1.0,
    move_timeout_s=1.0,
    press_timeout_s=1.0,
)


def _link(config=REHEARSAL_CONFIG, **mcu_kwargs):
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, **mcu_kwargs)
    client = SerialMotionClient(pipe.host, config, poll_s=0.01)
    return mcu, client


# ── 1. z_mode 능력 표시 ──────────────────────────────────────────────────────


def test_table_declares_z_mode_capability():
    assert TABLE["z_modes"] == ["motor", "solenoid", "switchbot"]
    assert "z_mode" in TABLE["events"]["ready"]
    assert "z_mode" in TABLE["commands"]["status"]["reply"]
    assert {"z_unsupported", "z_cooldown"} <= set(TABLE["errors"])


def test_switchbot_press_needs_no_duration_environment_and_uses_reply_result():
    mcu, client = _link(SWITCHBOT, z_mode="switchbot", homed=True)
    try:
        client.connect()
        client.home()
        client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0))
        press = next(d for d in mcu.received if d["cmd"] == "press")
    finally:
        mcu.close()
    assert press == {"id": press["id"], "cmd": "press", "mode": "switchbot"}
    assert SWITCHBOT.missing_for_press("switchbot") == ()
    assert client.state is MotionState.READY


@pytest.mark.parametrize(
    ("bot_result", "reason", "outcome"),
    [
        ("connect_failed", "switchbot_connect_failed", "not_pressed"),
        ("ack_timeout", "switchbot_ack_timeout", "unknown"),
        (0x06, "switchbot_low_battery", "not_pressed"),
    ],
)
def test_switchbot_failures_preserve_honest_press_outcome(bot_result, reason, outcome):
    from rpi.controller.serial_motion import MotionPressFailed

    mcu, client = _link(SWITCHBOT, z_mode="switchbot", homed=True, switchbot_result=bot_result)
    try:
        client.connect()
        client.home()
        with pytest.raises(MotionPressFailed) as caught:
            client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0))
    finally:
        mcu.close()
    assert caught.value.reason == reason
    assert caught.value.press_outcome == outcome
    assert client.state is MotionState.READY  # Bot 실패가 CoreXY 원점을 거짓으로 지우지 않는다.


def test_fake_switchbot_stop_reports_that_a_sent_press_cannot_be_recalled():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, z_mode="switchbot", homed=True)
    mcu.delays["press"] = 1.0
    try:
        pipe.host.write_line(json.dumps({"id": 1, "cmd": "press", "mode": "switchbot"}))
        for _ in range(100):
            if any(d.get("cmd") == "press" for d in mcu.received):
                break
            import time

            time.sleep(0.01)
        pipe.host.write_line(json.dumps({"id": 2, "cmd": "stop"}))
        stopped = json.loads(pipe.host.read_line(1.0) or "{}")
        stop_ack = json.loads(pipe.host.read_line(1.0) or "{}")
    finally:
        mcu.close()
    assert stopped == {
        "id": 1,
        "ok": False,
        "error": "switchbot_press_sent_cannot_recall",
        "press_outcome": "unknown",
    }
    assert stop_ack == {"id": 2, "ok": True}


@pytest.mark.parametrize("z_mode", ["motor", "solenoid", "switchbot"])
def test_fake_mcu_reports_z_mode_in_ready_and_status(z_mode):
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, ready_banner=True, z_mode=z_mode)
    try:
        ready = json.loads(pipe.host.read_line(1.0) or "{}")
        status = mcu.handlers["status"]({"id": 1, "cmd": "status"})[0]
    finally:
        mcu.close()
    assert ready["event"] == "ready" and ready["z_mode"] == z_mode
    assert sorted(ready) == sorted(TABLE["events"]["ready"])
    assert status["z_mode"] == z_mode
    assert sorted(status) == sorted(TABLE["commands"]["status"]["reply"])


def test_client_learns_z_mode_from_status_and_ready():
    mcu, client = _link(z_mode="solenoid")
    try:
        assert client.z_mode is None  # 묻기 전에는 모른다 — 지어내지 않는다
        client.connect()
        assert client.z_mode == "solenoid"
    finally:
        mcu.close()

    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, ready_banner=True, z_mode="motor")
    try:
        client = SerialMotionClient(pipe.host, REHEARSAL_CONFIG, poll_s=0.01)
        client.connect()  # 배너를 먼저 읽든 status를 먼저 받든 같은 값
        assert client.z_mode == "motor"
    finally:
        mcu.close()


def test_solenoid_refuses_depth_press_before_moving():
    mcu, client = _link(REHEARSAL_CONFIG, z_mode="solenoid", homed=True)  # press_mode=depth
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        assert client.state is MotionState.READY
        with pytest.raises(MotionRefused, match="솔레노이드"):
            client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
        cmds = mcu.cmds()
    finally:
        mcu.close()
    assert cmds == ["status", "home"]  # move도 press도 보내지 않았다
    assert client.state is MotionState.READY  # 위치를 잃지 않았다 — 재홈 불필요


def test_solenoid_duration_press_goes_through():
    mcu, client = _link(DURATION, z_mode="solenoid", homed=True)
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
        press = next(d for d in mcu.received if d["cmd"] == "press")
    finally:
        mcu.close()
    assert press["mode"] == "duration" and press["drive_ms"] == 120 and press["dwell_ms"] == 100
    assert client.state is MotionState.READY


def test_motor_mode_and_unknown_mode_still_allow_depth():
    for z_mode in ("motor", None):  # None = z_mode 필드를 보내지 않는 MCU(팀원 펌웨어 원본)
        mcu, client = _link(REHEARSAL_CONFIG, z_mode=z_mode, homed=True)
        try:
            client.connect()
            client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
            assert client.z_mode == z_mode
            client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
            press = next(d for d in mcu.received if d["cmd"] == "press")
        finally:
            mcu.close()
        assert press["mode"] == "depth"


# ── 2. 솔레노이드 MCU 쪽 거절 ────────────────────────────────────────────────


def _raw(mcu: FakeMcu, doc: dict) -> dict:
    return mcu.handlers[doc["cmd"]](doc)[-1]


def test_fake_solenoid_rejects_depth_and_over_long_press():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, z_mode="solenoid", homed=True, solenoid_on_max_ms=300)
    try:
        depth = _raw(mcu, {"id": 1, "cmd": "press", "mode": "depth", "z_counts": 10, "dwell_ms": 0})
        too_long = _raw(mcu, {"id": 2, "cmd": "press", "mode": "duration", "drive_ms": 200, "dwell_ms": 150})
        fine = _raw(mcu, {"id": 3, "cmd": "press", "mode": "duration", "drive_ms": 100, "dwell_ms": 100})
    finally:
        mcu.close()
    assert depth == {"id": 1, "ok": False, "error": "z_unsupported"}
    assert too_long == {"id": 2, "ok": False, "error": "soft_limit"}  # 켜짐 시간 = drive + dwell > 상한
    assert fine == {"id": 3, "ok": True}


def test_solenoid_cooldown_is_a_refusal_not_an_alarm():
    mcu, client = _link(DURATION, z_mode="solenoid", homed=True, solenoid_min_off_s=5.0)
    command = PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100)
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        client.press(command)
        with pytest.raises(MotionRefused, match="z_cooldown"):
            client.press(command)  # 코일 냉각 시간 안 — MCU가 거절
        state = client.state
    finally:
        mcu.close()
    assert state is MotionState.READY  # 알람·재홈으로 번지지 않는다
    assert mcu.alarm is None


# ── 3. 위치 일치 검사(벨트 미끄럼 등) ────────────────────────────────────────

CHECKED = dataclasses.replace(REHEARSAL_CONFIG, position_tolerance_counts=5)


def test_position_tolerance_env_and_validation():
    assert MotionConfig().position_tolerance_counts is None  # 기본 꺼짐 — 값은 측정 필요
    env = {"SIMPLELAY_MOTION_POSITION_TOLERANCE_COUNTS": "12"}
    assert MotionConfig.from_env(env).position_tolerance_counts == 12
    with pytest.raises(ValueError):
        MotionConfig(position_tolerance_counts=0)


def test_move_fails_when_encoder_report_disagrees_with_command():
    mcu, client = _link(CHECKED, homed=True, slip_counts=(0, 9))
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        with pytest.raises(MotionPositionMismatch, match="b"):
            client.move_to(10.0, 5.0)
        state = client.state
    finally:
        mcu.close()
    assert state is MotionState.UNHOMED  # 어디 있는지 믿을 수 없다 — 재홈 전까지 거절


def test_press_does_not_press_at_the_wrong_place():
    mcu, client = _link(CHECKED, homed=True, slip_counts=(-20, 0))
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        with pytest.raises(MotionPositionMismatch):
            client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
        cmds = mcu.cmds()
    finally:
        mcu.close()
    assert "press" not in cmds


def test_small_slip_within_tolerance_passes_and_check_off_ignores_slip():
    for config, slip in ((CHECKED, (3, -4)), (REHEARSAL_CONFIG, (0, 50))):
        mcu, client = _link(config, homed=True, slip_counts=slip)
        try:
            client.connect()
            client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
            client.move_to(10.0, 5.0)
        finally:
            mcu.close()
        assert client.state is MotionState.READY


def test_check_on_but_no_position_report_is_a_failure():
    mcu, client = _link(CHECKED, homed=True, report_position=False)
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        with pytest.raises(MotionPositionMismatch, match="위치 보고"):
            client.move_to(10.0, 5.0)
    finally:
        mcu.close()
    assert client.state is MotionState.UNHOMED


def test_mismatch_then_retry_rehomes_first_with_auto_home():
    config = dataclasses.replace(CHECKED, auto_home=True)
    mcu, client = _link(config, homed=True, slip_counts=(0, 30))
    command = PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100)
    try:
        client.connect()
        with pytest.raises(MotionPositionMismatch):
            client.press(command)
        mcu.slip_counts = (0, 0)  # 원점 복귀가 어긋남을 지웠다고 가정
        client.press(command)  # L1 재시도 — 재홈부터
        cmds = mcu.cmds()
    finally:
        mcu.close()
    # 실행기 시작 뒤 첫 누름은 원점부터(10/19), 어긋남 뒤 재시도도 재홈부터
    assert cmds == ["status", "home", "move", "home", "move", "press"]


# ── 4. 펌웨어 소스 — 보드 설정 한 파일 · Z 방식 빌드 플래그 ─────────────────


def _defines(text: str) -> set[str]:
    return set(re.findall(r"^\s*#\s*define\s+(\w+)", text, flags=re.M))


def test_all_pins_live_in_board_config():
    board = (FW / "include" / "board_config.h").read_text(encoding="utf-8")
    config = (FW / "include" / "config.h").read_text(encoding="utf-8")
    assert '#include "board_config.h"' in config
    assert not {d for d in _defines(config) if d.startswith("PIN_")}
    for name in ("PIN_MOTOR_A_PWM", "PIN_ENC_A_CHA", "PIN_LIMIT_X", "PIN_STBY_AB", "PIN_SOLENOID",
                 "Z_MODE_MOTOR", "Z_MODE_SOLENOID", "SOLENOID_ON_MAX_MS", "SOLENOID_MIN_OFF_MS"):
        assert name in _defines(board), name
    assert "팀원 확인 필요" in board
    for z_mode in ("motor", "solenoid"):  # SwitchBot 선택 빌드는 firmware-motion-corexy 쪽이다.
        assert f'#define Z_MODE_NAME            "{z_mode}"' in board  # ready·status의 z_mode 값
    for src in (FW / "src").glob("*"):
        text = src.read_text(encoding="utf-8")
        assert not re.search(r"\bGPIO_NUM_\d+|\bpinMode\(\s*\d", text), src.name  # 핀 번호를 소스에 박지 않는다


def test_platformio_builds_both_z_modes():
    ini = (FW / "platformio.ini").read_text(encoding="utf-8")
    assert "-DZ_MODE=Z_MODE_SOLENOID" in ini
    envs = re.findall(r"^\[env:(\w+)\]", ini, flags=re.M)
    assert len(envs) >= 2


# ── 5. 솔레노이드 운용(2026-10-05 리뷰 L6) ────────────────────────────────────


def test_mcu_reports_solenoid_on_max_in_ready_and_status():
    assert "z_on_max_ms" in TABLE["events"]["ready"]
    assert "z_on_max_ms" in TABLE["commands"]["status"]["reply"]
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, ready_banner=True, z_mode="solenoid", solenoid_on_max_ms=300)
    try:
        ready = json.loads(pipe.host.read_line(1.0) or "{}")
        motor = FakeMcu(InMemoryLinePipe(), z_mode="motor")
        motor_status = motor.handlers["status"]({"id": 1, "cmd": "status"})[0]
        motor.close()
    finally:
        mcu.close()
    assert ready["z_on_max_ms"] == 300
    assert motor_status["z_on_max_ms"] is None  # 모터 방식은 켜짐 상한이 없다


def test_host_refuses_solenoid_press_over_reported_on_max_before_moving():
    mcu, client = _link(DURATION, z_mode="solenoid", homed=True, solenoid_on_max_ms=150)  # 120 + 100 > 150
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        assert client.z_on_max_ms == 150
        with pytest.raises(MotionRefused, match="켜짐"):
            client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
        cmds = mcu.cmds()
    finally:
        mcu.close()
    assert cmds == ["status", "home"]  # 움직이기 전에 거절
    assert client.state is MotionState.READY


def test_cooldown_waits_the_reported_remaining_time_and_retries_once():
    mcu, client = _link(DURATION, z_mode="solenoid", homed=True, solenoid_min_off_s=0.3)
    command = PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100)
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        client.press(command)
        client.press(command)  # 냉각 안 — 남은 시간만큼 기다렸다가 한 번 더
        cmds = mcu.cmds()
        refusal = [d for d in mcu.received if d.get("cmd") == "press"]
    finally:
        mcu.close()
    assert cmds == ["status", "home", "move", "press", "move", "press", "press"]
    assert len(refusal) == 3 and client.state is MotionState.READY and mcu.alarm is None


def test_cooldown_backoff_env():
    env = {"SIMPLELAY_MOTION_Z_COOLDOWN_BACKOFF_MS": "250"}
    assert MotionConfig.from_env(env).z_cooldown_backoff_ms == 250


def test_soft_limit_refusal_on_press_is_not_an_alarm():
    """MCU가 누름을 soft_limit으로 거절했을 뿐(움직이지 않음)이면 알람·재홈으로 번지지 않는다."""
    mcu, client = _link(DURATION, z_mode=None, homed=True)
    mcu.handlers["press"] = lambda d: [{"id": d["id"], "ok": False, "error": "soft_limit"}]
    try:
        client.connect()
        client.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        with pytest.raises(MotionRefused, match="soft_limit"):
            client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
        state = client.state
    finally:
        mcu.close()
    assert state is MotionState.READY
