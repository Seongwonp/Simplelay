"""홈·조그 CLI — 가짜 MCU로만 시험한다(실물 미검증).

리허설 설정(`REHEARSAL_CONFIG`)의 수치는 임의 값이다. 실물 값이 아니다.
"""

from __future__ import annotations

import io
import json
import tempfile
from pathlib import Path

import pytest

from rpi.controller.kinematics import KinematicsNotConfigured
from rpi.tools import jog


@pytest.fixture
def log_path():
    # pytest tmp_path는 이 기기에서 권한 오류가 나는 경우가 있어 표준 임시 폴더를 쓴다.
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        yield Path(tmp) / "jog.log"


def _run(argv, stdin_text=None, env=None):
    out = io.StringIO()
    code = jog.main(
        argv,
        stdin=io.StringIO(stdin_text) if stdin_text is not None else None,
        stdout=out,
        env={} if env is None else env,
    )
    return code, out.getvalue()


def _sent(log_path: Path) -> list[dict]:
    docs = []
    for line in log_path.read_text(encoding="utf-8").splitlines():
        parts = line.split(" ", 3)
        if parts[2] == ">>":
            docs.append(json.loads(parts[3]))
    return docs


def test_scripted_repl_session_on_fake_mcu(log_path):
    script = "status\nhome\njog 5 2\ngoto 10 10\npress\npress --duration 100 --dwell 50\nstop\nquit\nstatus\n"
    code, out = _run(["--fake-mcu", "--rehearsal-config", "--log", str(log_path)], script)
    assert code == 0, out
    assert "시작 시 자동 홈 없음" in out
    assert "리허설용 임의" in out
    assert "홈 완료 — 어댑터 상태=ready" in out
    assert "조그 완료 (0.000,0.000) →" in out
    assert "이동 완료 x=10 y=10" in out
    assert out.count("누름 완료") == 2
    assert "정지 명령 전송" in out
    cmds = [d["cmd"] for d in _sent(log_path)]
    # quit 뒤의 status는 실행되지 않았다
    assert cmds == ["status", "home", "status", "move", "move", "status", "move", "press", "status", "move", "press", "stop"]
    presses = [d for d in _sent(log_path) if d["cmd"] == "press"]
    assert presses[0]["mode"] == "depth" and presses[0]["z_counts"] == 40
    assert presses[1]["mode"] == "duration" and presses[1]["drive_ms"] == 100 and presses[1]["dwell_ms"] == 50


def test_jog_is_relative_to_the_position_the_mcu_reports(log_path):
    code, out = _run(
        ["--fake-mcu", "--rehearsal-config", "--log", str(log_path), "-c", "home", "-c", "goto 30 20", "-c", "jog -10 5"]
    )
    assert code == 0, out
    moves = [d for d in _sent(log_path) if d["cmd"] == "move"]
    assert (moves[-1]["x_mm"], moves[-1]["y_mm"]) == pytest.approx((20.0, 25.0), abs=0.05)


@pytest.mark.parametrize("command", ["goto 10 10", "jog 1 1", "press"])
def test_motion_is_refused_before_home(log_path, command):
    code, out = _run(["--fake-mcu", "--rehearsal-config", "--log", str(log_path), "-c", "status", "-c", command])
    assert code == 1
    assert "거절 MotionRefused" in out and "홈 먼저" in out
    assert [d["cmd"] for d in _sent(log_path)] == ["status"]  # 움직이는 명령은 나가지 않았다


def test_never_auto_homes_even_if_env_asks(log_path):
    env = {"SIMPLELAY_MOTION_AUTO_HOME": "true", "SIMPLELAY_MOTION_STATUS_TIMEOUT_S": "1"}
    code, out = _run(["--fake-mcu", "--log", str(log_path), "-c", "status"], env=env)
    assert code == 0, out
    assert "SIMPLELAY_MOTION_AUTO_HOME은 이 도구에서 무시합니다" in out
    assert [d["cmd"] for d in _sent(log_path)] == ["status"]


def test_soft_limit_refusal_sends_nothing(log_path):
    code, out = _run(
        ["--fake-mcu", "--rehearsal-config", "--log", str(log_path), "-c", "home", "-c", "goto 150 0"]
    )
    assert code == 1
    assert "거절 SoftLimitExceeded: x=150 mm가 소프트 리밋 [0, 100] 밖입니다" in out
    assert "move" not in [d["cmd"] for d in _sent(log_path)]


def test_press_override_still_respects_the_cap(log_path):
    code, out = _run(
        ["--fake-mcu", "--rehearsal-config", "--log", str(log_path), "-c", "home", "-c", "press --depth 70"]
    )
    assert code == 1
    assert "상한 60" in out
    assert "press" not in [d["cmd"] for d in _sent(log_path)]


def test_unconfigured_kinematics_message_is_printed_verbatim():
    env = {"SIMPLELAY_MOTION_STATUS_TIMEOUT_S": "1", "SIMPLELAY_MOTION_MOVE_TIMEOUT_S": "1"}
    code, out = _run(["--fake-mcu", "-c", "goto 1 1"], env=env)
    assert code == 1
    expected = KinematicsNotConfigured(
        "XY 소프트 리밋 검사", ("x_min_mm", "x_max_mm", "y_min_mm", "y_max_mm")
    )
    assert f"거절 KinematicsNotConfigured: {expected}" in out
    assert "SIMPLELAY_MOTION_X_MIN_MM" in out


def test_missing_timeouts_are_named_with_their_env_vars():
    code, out = _run(["--fake-mcu", "-c", "status"])
    assert code == 1
    assert "SIMPLELAY_MOTION_STATUS_TIMEOUT_S" in out
    assert "누름에 필요한데 비어 있는 설정:" in out


def test_raw_sends_a_line_and_prints_the_reply_but_refuses_motion(log_path):
    code, out = _run(
        [
            "--fake-mcu",
            "--rehearsal-config",
            "--log",
            str(log_path),
            "-c",
            'raw {"cmd":"status"}',
            "-c",
            'raw {"cmd":"move","a":1,"b":1}',
        ]
    )
    assert code == 1
    assert '<< {"id": 900001, "ok": true, "state": "idle"' in out
    assert "raw로 'move'는 보내지 않습니다" in out
    assert [d["cmd"] for d in _sent(log_path)] == ["status"]


def test_log_file_has_timestamps_and_directions(log_path):
    _run(["--fake-mcu", "--rehearsal-config", "--log", str(log_path), "-c", "status"])
    lines = log_path.read_text(encoding="utf-8").splitlines()
    tags = [line.split(" ", 3)[2] for line in lines]
    assert tags == ["##", "##", ">>", "<<"]
    wall, rel = lines[2].split(" ")[:2]
    assert wall[:4].isdigit() and "T" in wall
    assert rel.startswith("+") and rel.endswith("s")
    # 이어 쓰기: 두 번째 세션은 앞 기록을 지우지 않는다
    _run(["--fake-mcu", "--rehearsal-config", "--log", str(log_path), "-c", "status"])
    assert len(log_path.read_text(encoding="utf-8").splitlines()) == 8


def test_unknown_command_and_bad_args_do_not_crash():
    code, out = _run(["--fake-mcu", "--rehearsal-config"], "dance\njog 1\ngoto a b\nhelp\n")
    assert code == 1
    assert "알 수 없는 명령: dance" in out
    assert "jog에는 숫자 두 개가 필요합니다" in out
    assert "goto: 숫자가 아닙니다" in out
    assert "status | home" in out


def test_rehearsal_config_needs_fake_mcu():
    with pytest.raises(SystemExit):
        jog.main(["--rehearsal-config"], stdout=io.StringIO(), env={})


def test_real_port_needs_port_and_baud():
    code, out = _run(["-c", "status"])
    assert code == 2
    assert "SIMPLELAY_MOTION_PORT" in out


def test_keyboard_interrupt_during_a_command_sends_stop(log_path):
    out = io.StringIO()
    line_log = jog.LineLog(None)
    from rpi.controller.serial_motion import InMemoryLinePipe
    from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu

    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    try:
        client = jog.JogMotionClient(pipe.host, REHEARSAL_CONFIG, poll_s=0.01)
        session = jog.JogSession(client, pipe.host, out, line_log)

        def _interrupt(_rest):
            raise KeyboardInterrupt

        session._cmd_home = _interrupt  # type: ignore[method-assign]
        assert session.run_line("home") is False
        assert "정지 명령을 보냈습니다" in out.getvalue()
        import time

        time.sleep(0.1)
        assert "stop" in mcu.cmds()
    finally:
        mcu.close()
