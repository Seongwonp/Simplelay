"""TCP Touch Bridge simulator + the unchanged adapter over pyserial ``socket://`` (simulation only)."""

from __future__ import annotations

import io
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from rpi.controller.models import ExecutionMode
from rpi.controller.closed_loop import motion_abort_reason
from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import (
    MotionAlarm, MotionPressFailed, MotionStopped, PySerialLineTransport,
)
from rpi.controller.touchbridge_motion import TouchBridgeConfig, TouchBridgeMotionClient
from rpi.tools.touchbridge_sim import Faults, TcpFrontEnd, Timing, TouchBridgeSim

pytest.importorskip("serial")

FAST = Timing(scale=0.02)  # 50 mm takes ~1.2 s at sketch defaults → ~25 ms here


class Rig:
    def __init__(self, *, timing=FAST, faults=None, homed=False):
        self.lines: list[tuple[str, str]] = []
        self._lock = threading.Lock()
        self.front = TcpFrontEnd("127.0.0.1", 0, log=self._log, timing=timing,
                                 faults=faults or Faults(), homed=homed)
        self.thread = threading.Thread(target=self.front.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.front.address
        self.url = f"socket://{host}:{port}"
        self.client = None

    def _log(self, direction, text):
        with self._lock:
            self.lines.append((direction, text))

    def open(self, **config):
        cfg = dict(status_timeout_s=1.0, connect_timeout_s=2.0, home_timeout_s=3.0,
                   move_timeout_s=3.0, press_timeout_s=3.0)
        cfg.update(config)
        self.client = TouchBridgeMotionClient(PySerialLineTransport(self.url, 115200),
                                              TouchBridgeConfig(**cfg))
        return self.client

    def states(self, action):
        """States the simulator sent for commands of ``action`` (in order)."""
        ids = set()
        out = []
        with self._lock:
            lines = list(self.lines)
        for direction, text in lines:
            if not text.startswith("{"):
                continue
            doc = json.loads(text.split("   (no client)")[0])
            if direction == ">>" and doc.get("action") == action:
                ids.add(doc["commandId"])
            elif direction == "<<" and doc.get("commandId") in ids:
                out.append(doc["state"])
        return out

    def close(self):
        if self.client is not None:
            self.client.close()
        self.front.close()


@pytest.fixture
def rig():
    made = []

    def make(**kwargs):
        made.append(Rig(**kwargs))
        return made[-1]

    yield make
    for r in made:
        r.close()


def test_socket_url_runs_home_move_press_to_completed_end_to_end(rig):
    r = rig()
    client = r.open()
    assert not client.connect().homed  # the sketch boots unhomed; the adapter does not home by itself
    client.home()
    assert client.homed and client.position_xy() == (0.0, 0.0)
    client.press(PressCommand("start", x_mm=30.5, y_mm=40.25))
    assert client.last_position == {"x_mm": 30.5, "y_mm": 40.25}
    assert r.states("home") == ["RECEIVED", "HOMING", "HOMED", "COMPLETED"]
    assert r.states("move_only") == ["RECEIVED", "MOVING", "POSITIONED", "COMPLETED"]
    assert r.states("press") == ["RECEIVED", "PRESSING", "COMPLETED"]


def test_stop_mid_move_over_socket_reports_stopped_and_leaves_a_partial_position(rig):
    r = rig(timing=Timing(speed_mm_s=20, scale=1.0), homed=True)
    client = r.open(move_timeout_s=20)
    client.connect()
    with ThreadPoolExecutor() as pool:
        move = pool.submit(client.move_to, 150, 0)
        deadline = time.monotonic() + 2
        while "MOVING" not in r.states("move_only") and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.2)
        assert client.request_stop()
        report = client.confirm_stop(ack_timeout_s=1.0)
        with pytest.raises(MotionStopped):
            move.result(timeout=2)
    assert report.level == "mcu_ack"  # simulator ack only — never a physical verification
    assert r.states("move_only")[-1] == "STOPPED" and r.states("stop") == ["STOPPED"]
    x, y = r.front.sim.position()
    assert 0 < x < 150 and y == 0


def test_after_a_stop_the_next_run_is_not_refused_and_can_press_again(rig):
    """10/24 모의 보드 시험: 정지(개발자 세션 종료 포함) 한 번 뒤로 '중단 요청이 남아 있어요'로 일반 실행이 늘 거절됐다.
    지난 정지 표시는 준비 거절 이유가 아니고, 새 실행을 시작시키는 쪽의 reset_stop이 지운다."""
    r = rig(homed=True)
    client = r.open()
    client.connect()
    assert client.request_stop()
    client.confirm_stop(ack_timeout_s=1.0)
    assert client.not_ready_reason() is None
    client.reset_stop()  # ActExecutor._begin_execute가 하는 일
    client.press(PressCommand("start", x_mm=10.0, y_mm=10.0))
    assert r.states("press")[-1] == "COMPLETED"


def test_bot_failure_and_stall_injection_reach_the_adapter_unchanged(rig):
    r = rig(faults=Faults(press_fail="BOT_BUSY", stall_on_move=2), homed=True)
    client = r.open()
    client.connect()
    with pytest.raises(MotionPressFailed) as failed:
        client.press(PressCommand("start", x_mm=10, y_mm=10))
    assert failed.value.press_outcome == "unknown"
    assert r.states("press") == ["RECEIVED", "PRESSING", "ERROR_PROTOCOL"]
    with pytest.raises(MotionAlarm) as stalled:
        client.move_to(60, 60)
    assert motion_abort_reason(stalled.value) == "motion_alarm: ERROR_STALL"
    assert r.front.sim.position() != (60.0, 60.0)


def test_press_timeout_injection_is_an_unknown_press(rig):
    r = rig(faults=Faults(press_timeout=True), homed=True)
    client = r.open()
    client.connect()
    with pytest.raises(MotionPressFailed) as failed:
        client.press(PressCommand("start", x_mm=5, y_mm=5))
    assert failed.value.press_outcome == "unknown" and failed.value.reason == "ERROR_TIMEOUT"


def test_executor_factory_opens_a_socket_url_through_the_real_transport(rig, monkeypatch):
    import rpi4.act_main as act_main

    r = rig(homed=True)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PROTOCOL", "touchbridge-v2")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", r.url)
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    built = None
    try:
        built, _ = act_main._build_motion()
        assert isinstance(built, TouchBridgeMotionClient)
        assert built.homed and built.position_xy() == (0.0, 0.0)
        # 모의 보드 표시가 없으면 종전대로 실제 — 표시는 명시적으로만.
        assert built.execution_mode is ExecutionMode.REAL
    finally:
        for name in ("_motion_watch", "_motion_retry"):
            watcher = getattr(act_main, name)
            if watcher is not None:
                watcher.stop()
                setattr(act_main, name, None)
        if built is not None:
            built.close()


def test_simulated_board_is_recorded_as_practice_not_real(rig, monkeypatch):
    """모의 보드(SIMPLELAY_MOTION_SIMULATED=1)로 누른 결과는 '연습'(mock) — 실제 누름 기록과 섞이지 않는다(10/24)."""
    import rpi4.act_main as act_main

    r = rig(homed=True)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PROTOCOL", "touchbridge-v2")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", r.url)
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setenv("SIMPLELAY_MOTION_SIMULATED", "1")
    built = None
    try:
        built, _ = act_main._build_motion()
        assert built.execution_mode is ExecutionMode.MOCK
    finally:
        for name in ("_motion_watch", "_motion_retry"):
            watcher = getattr(act_main, name)
            if watcher is not None:
                watcher.stop()
                setattr(act_main, name, None)
        if built is not None:
            built.close()


# ── simulator model without sockets ──

def _sim(**kwargs):
    out: list[str] = []
    sim = TouchBridgeSim(out.append, timing=Timing(scale=0.01), **kwargs)
    return sim, out


def _wait_for(out, predicate, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for line in list(out):
            if predicate(line):
                return line
        time.sleep(0.005)
    raise AssertionError(f"no matching line in {out}")


def _cmd(sim, cid, action, **fields):
    sim.feed((json.dumps({"version": 2, "commandId": cid, "action": action, **fields}) + "\n").encode())


def test_position_token_is_single_use_and_bound_to_the_last_move():
    sim, out = _sim(homed=True)
    try:
        _cmd(sim, "m1", "move_only", target={"xMm": 3, "yMm": 4})
        positioned = json.loads(_wait_for(out, lambda l: '"POSITIONED"' in l))
        _wait_for(out, lambda l: '"m1"' in l and '"COMPLETED"' in l)
        token = positioned["positionToken"]
        assert len(token) == 16 and int(token, 16) >= 0
        _cmd(sim, "p0", "press", positionToken="0" * 16)  # wrong token also burns the real one
        _wait_for(out, lambda l: '"p0"' in l and "ERROR_INVALID_TOKEN" in l)
        _cmd(sim, "p1", "press", positionToken=token)
        _wait_for(out, lambda l: '"p1"' in l and "ERROR_INVALID_TOKEN" in l)
    finally:
        sim.close()


def test_unhomed_busy_and_text_commands_follow_the_sketch_shapes():
    sim, out = _sim()
    try:
        _cmd(sim, "m1", "move_only", target={"xMm": 3, "yMm": 4})
        _wait_for(out, lambda l: '"m1"' in l and "ERROR_NOT_HOMED" in l)
        sim.feed(b"P\n")
        assert _wait_for(out, lambda l: l.startswith("STATE ")).startswith("STATE IDLE homed=0")
        _cmd(sim, "h1", "home")
        _cmd(sim, "h2", "home")
        _wait_for(out, lambda l: '"h2"' in l and '"BUSY"' in l)
        _wait_for(out, lambda l: '"h1"' in l and '"HOMED"' in l)
        sim.feed(b"G 1 2\n")
        _wait_for(out, lambda l: l == "DONE 1.00 2.00")
        sim.feed(b"{bad\n")
        _wait_for(out, lambda l: l == "ERROR:JSON")
    finally:
        sim.close()


def test_bang_byte_stops_without_a_newline():
    sim, out = _sim(homed=True)
    sim.timing = Timing(speed_mm_s=5, scale=1.0)
    try:
        _cmd(sim, "m1", "move_only", target={"xMm": 100, "yMm": 0})
        _wait_for(out, lambda l: '"MOVING"' in l)
        sim.feed(b"!")
        _wait_for(out, lambda l: '"m1"' in l and '"STOPPED"' in l)
        assert not sim.busy()
    finally:
        sim.close()


def test_cli_rejects_bad_listen_and_logs_to_stdout(capsys):
    from rpi.tools import touchbridge_sim

    with pytest.raises(SystemExit):
        touchbridge_sim.main(["--listen", "nope"])
    stream = io.StringIO()
    front = TcpFrontEnd("127.0.0.1", 0, log=touchbridge_sim._Log(stream))
    try:
        front.sim.boot()
        assert "Touch Bridge CoreXY v4 ready" in stream.getvalue()
        assert "(no client)" in stream.getvalue()
    finally:
        front.close()


def test_simulated_board_hold_uses_a_mock_appliance_that_ends():
    """10/24 실패널: 모의 보드의 연습 대기가 실물처럼 최대 대기 시간(30분)까지 남아 키오스크를 다시 켤 때마다 대기가 떴다.
    모의 보드면 대기의 가전 확인은 모의 가전(정해진 시간 뒤 꺼짐)이다."""
    import rpi4.act_main as act_main
    from rpi4.services.stop_hold import MockApplianceRun

    class _SimBoard:
        execution_mode = ExecutionMode.MOCK

    board = _SimBoard()
    hardware = act_main._build_hold(board, board)

    class _Plan:
        stop_presses = 1

    assert isinstance(hardware.probe_factory(_Plan()), MockApplianceRun)


def test_set_origin_mode_marks_here_as_origin_without_moving():
    """HW 담당 안내(10/25): 원본 스케치의 ``Z``는 지금 자리를 원점으로 정한다. home_mode=set_origin이면 home()이
    벽 찾기 대신 Z를 보내고, 원점이 잡힌 것을 상태로 확인한다. 움직이지 않는다."""
    r = Rig()
    try:
        client = r.open(home_mode="set_origin")
        client.connect()
        assert client.homed is False
        with client.diagnostic_context('explicit-origin-1028'):
            client.home()
        assert client.homed is True
        origins = [row for row in client.motion_trace() if row.get('action') == 'set_origin']
        assert origins[-1]['context_id'] == 'explicit-origin-1028'
        assert any(text.strip() == "Z" for _, text in r.lines), r.lines
        assert not any('"action":"home"' in text for _, text in r.lines)
        client.move_to(10.0, 5.0)  # 원점이 잡혔으니 이동이 받아들여진다
    finally:
        if r.client is not None:
            r.client.close()


def test_home_mode_from_env_and_unknown_value_rejected():
    assert TouchBridgeConfig.from_env({"SIMPLELAY_TOUCHBRIDGE_HOME_MODE": "set_origin"}).home_mode == "set_origin"
    assert TouchBridgeConfig.from_env({}).home_mode == "stall"
    with pytest.raises(ValueError):
        TouchBridgeConfig(home_mode="anywhere")
