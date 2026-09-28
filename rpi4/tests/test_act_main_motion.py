"""act_main의 모션 배선 — 기본은 mock, SIMPLELAY_MOTION_MODE=serial이면 MCU 어댑터.

serial 어댑터는 실물 미검증이다. 여기서는 전송을 메모리 파이프로 바꿔 끼워
배선과 거절 동작만 확인한다.
"""

from __future__ import annotations

import json
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
]


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _MOTION_ENV:
        monkeypatch.delenv(name, raising=False)


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
