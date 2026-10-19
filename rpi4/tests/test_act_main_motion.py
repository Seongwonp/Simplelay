"""act_main의 모션 배선 — 기본은 mock, SIMPLELAY_MOTION_MODE=serial이면 MCU 어댑터.

serial 어댑터는 실물 미검증이다. 여기서는 전송을 메모리 파이프로 바꿔 끼워
배선과 거절 동작만 확인한다.
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading

import pytest

from rpi.controller import ExecutionMode
from rpi.controller.mock import MockGrblClient, MockSafetyController
from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionSafetyController,
    MotionState,
    SerialMotionClient,
)

import rpi4.act_main as act_main

_MOTION_ENV = [
    "SIMPLELAY_MOTION_MODE",
    "SIMPLELAY_MOTION_PORT",
    "SIMPLELAY_MOTION_BAUD",
    "SIMPLELAY_MOTION_STATUS_TIMEOUT_S",
    "SIMPLELAY_MOTION_CONNECT_TIMEOUT_S",
    "SIMPLELAY_MOTION_HEARTBEAT_MS",
]


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _MOTION_ENV:
        monkeypatch.delenv(name, raising=False)
    yield
    if act_main._motion_retry is not None:  # 배경 재연결 스레드를 다음 시험으로 넘기지 않는다
        act_main._motion_retry.stop()
        act_main._motion_retry = None
    if act_main._motion_watch is not None:  # 포트 감시 스레드(2026-10-14)도 넘기지 않는다
        act_main._motion_watch.stop()
        act_main._motion_watch = None


def test_default_motion_is_mock():
    grbl, safety = act_main._build_motion()
    assert isinstance(grbl, MockGrblClient)
    assert isinstance(safety, MockSafetyController)


def test_unknown_mode_is_refused(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "grbl")
    with pytest.raises(RuntimeError, match="SIMPLELAY_MOTION_MODE"):
        act_main._build_motion()


@pytest.mark.parametrize("env", [{}, {"SIMPLELAY_MOTION_PORT": "/dev/ttyUSB0"}, {"SIMPLELAY_MOTION_BAUD": "115200"}])
def test_serial_mode_needs_explicit_port_and_baud(monkeypatch, env):
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    with pytest.raises(RuntimeError, match="SIMPLELAY_MOTION_PORT"):
        act_main._build_motion()


def _answer_status(pipe: InMemoryLinePipe, stop: threading.Event) -> None:
    while not stop.is_set():
        line = pipe.device.read_line(0.02)
        if line is None:
            continue
        doc = json.loads(line)
        pipe.device.write_line(json.dumps({"id": doc["id"], "ok": True, "state": "idle", "homed": False}))


def test_serial_mode_wires_the_adapter_and_checks_status(monkeypatch):
    pipe = InMemoryLinePipe()
    stop = threading.Event()
    threading.Thread(target=_answer_status, args=(pipe, stop), daemon=True).start()
    opened = []
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: opened.append((port, baud)) or pipe.host)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "57600")
    monkeypatch.setenv("SIMPLELAY_MOTION_STATUS_TIMEOUT_S", "1")
    try:
        grbl, safety = act_main._build_motion()
    finally:
        stop.set()
    assert opened == [("/dev/test-mcu", 57600)]
    assert isinstance(grbl, SerialMotionClient)
    assert isinstance(safety, MotionSafetyController)
    assert grbl.execution_mode is ExecutionMode.REAL
    assert grbl.state is MotionState.UNHOMED  # 홈 전 — 누름은 거절된다


def test_serial_mode_starts_even_when_status_is_unconfigured(monkeypatch):
    """상태 조회 기한이 없으면 조회를 못 하지만 시작은 한다 — 준비 안 됨으로 남는다."""
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: InMemoryLinePipe().host)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "57600")
    grbl, _ = act_main._build_motion()
    assert grbl.state is MotionState.UNKNOWN
    assert grbl.homed is False


def test_build_executor_uses_the_selected_motion(monkeypatch):
    class _RealLooking(MockGrblClient):
        execution_mode = ExecutionMode.REAL

    monkeypatch.setattr(act_main, "_build_motion", lambda: (_RealLooking(), MockSafetyController()))
    executor = act_main._build_executor(object(), object())  # type: ignore[arg-type]
    # 기본 mock이 아니라 _build_motion이 고른 어댑터가 폐루프에 들어갔다
    assert executor._controller.execution_mode is ExecutionMode.REAL


def test_build_executor_wires_the_motion_stop_confirmation_only_for_serial(monkeypatch, tmp_path):
    """정지 확인 단계(2026-10-13): serial이면 실행기의 정지 보고가 실제 어댑터의 confirm_stop을 쓰고,
    줄 기록(SIMPLELAY_MOTION_LOG_PATH)에 보낸 정지(>>)와 MCU의 정지 응답(<<)이 둘 다 남는다."""
    from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu
    from rpi.controller.serial_motion import MotionConfig

    assert act_main._build_executor(object(), object())._motion_stop is None  # 기본 mock — 확인할 어댑터 없음

    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    log_path = tmp_path / "motion.log"
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    monkeypatch.setattr(MotionConfig, "from_env", classmethod(lambda cls, env=None: REHEARSAL_CONFIG))
    monkeypatch.setenv("SIMPLELAY_MOTION_LOG_PATH", str(log_path))
    _serial_env(monkeypatch)
    line_log, stream = act_main._build_motion_log()
    try:
        executor = act_main._build_executor(object(), object(), motion_log=line_log)  # type: ignore[arg-type]
        client = executor._motion_stop
        assert isinstance(client, SerialMotionClient)
        client.request_stop()
        report = client.confirm_stop(verify=False)
    finally:
        mcu.close()
        stream.close()
    assert report.level == "mcu_ack"
    text = log_path.read_text(encoding="utf-8")
    stop_lines = [line for line in text.splitlines() if f'"id": {report.stop_id}' in line]
    assert any(" >> " in line and '"stop"' in line for line in stop_lines)
    assert any(" << " in line and '"ok": true' in line for line in stop_lines)


# ── 연결 재시도·readiness·heartbeat 경고(2026-09-29 첫날 위험 보완) ─────────


def _serial_env(monkeypatch, **extra):
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setenv("SIMPLELAY_MOTION_STATUS_TIMEOUT_S", "0.1")
    monkeypatch.setenv("SIMPLELAY_MOTION_CONNECT_TIMEOUT_S", "0.3")
    for key, value in extra.items():
        monkeypatch.setenv(key, value)


def test_silent_mcu_is_retried_in_background_and_reported_not_ready(monkeypatch):
    pipe = InMemoryLinePipe()
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    monkeypatch.setattr(act_main, "MOTION_CONNECT_BACKOFF_S", (0.05, 0.1))
    _serial_env(monkeypatch)
    grbl, _ = act_main._build_motion()  # 시작은 막히지 않는다
    assert grbl.state is MotionState.UNKNOWN
    assert "연결 확인 전" in (grbl.not_ready_reason() or "")
    retry = act_main._motion_retry
    assert retry is not None and not retry.connected.is_set()

    # MCU가 늦게 살아난다(부팅·케이블) — 배경 재시도가 붙는다.
    stop = threading.Event()
    threading.Thread(target=_answer_status, args=(pipe, stop), daemon=True).start()
    try:
        assert retry.connected.wait(5.0)
    finally:
        stop.set()
    assert retry.attempts >= 1
    assert grbl.link_not_ready_reason() is None
    assert "원점을 다시 잡아야" in (grbl.not_ready_reason() or "")  # 원점 전(자동 원점 꺼짐) — 누르기 전 거절(2026-10-19)
    assert grbl.state is MotionState.UNHOMED


def test_config_error_is_not_retried(monkeypatch):
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: InMemoryLinePipe().host)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "57600")
    act_main._build_motion()  # status 기한 미설정 — 다시 시도해도 풀리지 않는다
    assert act_main._motion_retry is None


class _Writer:
    def __init__(self) -> None:
        self.lines: list[dict] = []

    def write(self, data: bytes) -> None:
        self.lines.extend(json.loads(x) for x in data.splitlines() if x.strip())

    async def drain(self) -> None:
        pass


def test_executor_refuses_execute_while_motion_not_ready(monkeypatch):
    pipe = InMemoryLinePipe()  # 아무도 답하지 않는 MCU
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    monkeypatch.setattr(act_main, "MOTION_CONNECT_BACKOFF_S", (30.0,))
    _serial_env(monkeypatch)

    async def _t():
        reader = asyncio.StreamReader()
        writer = _Writer()
        executor = act_main._build_executor(reader, writer)  # type: ignore[arg-type]
        line = json.dumps({"type": "execute", "appliance_id": "microwave", "sequence_id": "seq-nr", "buttons": ["시작"]}, ensure_ascii=False)
        reader.feed_data((line + "\n").encode("utf-8"))
        await executor.run_once()
        await executor.wait_idle()
        return writer.lines

    lines = asyncio.run(_t())
    assert len(lines) == 1
    assert lines[0]["type"] == "error" and lines[0]["sequence_id"] == "seq-nr"
    assert lines[0]["reason"] == "motion_not_ready"
    assert "연결 확인 전" in lines[0]["detail"]
    sent = []
    while (line := pipe.device.read_line(0.0)) is not None:
        sent.append(json.loads(line)["cmd"])
    assert set(sent) == {"status"}  # 누름·이동은 한 줄도 나가지 않았다


def test_heartbeat_off_logs_a_startup_warning(monkeypatch, caplog):
    pipe = InMemoryLinePipe()
    stop = threading.Event()
    threading.Thread(target=_answer_status, args=(pipe, stop), daemon=True).start()
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    _serial_env(monkeypatch, SIMPLELAY_MOTION_HEARTBEAT_MS="off", SIMPLELAY_MOTION_CONNECT_TIMEOUT_S="2")
    try:
        with caplog.at_level(logging.WARNING, logger=act_main.log.name):
            grbl, _ = act_main._build_motion()
    finally:
        stop.set()
    assert grbl.config.heartbeat_ms is None
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any("HEARTBEAT_MS=off" in w and "host_timeout" in w for w in warnings)
