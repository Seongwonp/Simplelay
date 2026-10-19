"""act_main의 원시 기록기 배선 — 기본 꺼짐, SIMPLELAY_RECORDER_PATH가 있으면 켠다.

실기기 리더(ADS1115·마이크)는 열지 않는다. 합성 입력은 source가 mock_*로 찍히는지,
그리고 시작 로그가 합성임을 밝히는지를 본다. 모션 수치는 시험용 임의 값이다.
"""

from __future__ import annotations

import json
import logging
import tempfile
import time
from pathlib import Path

import pytest

from rpi.controller import ExecutionMode
from rpi.controller.mock import MockGrblClient, MockSafetyController
from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import InMemoryLinePipe, SerialMotionClient
from rpi.tools.fake_mcu import FakeMcu
from rpi.verifier.recorder import LiveRecorder, RecordingGrblClient

import rpi4.act_main as act_main

_ENV = [
    "SIMPLELAY_RECORDER_PATH",
    "SIMPLELAY_RECORDER_PRE_S",
    "SIMPLELAY_RECORDER_POST_S",
    "SIMPLELAY_RECORDER_ADC_GAIN",
    "SIMPLELAY_RECORDER_ADC_CHANNEL",
    "SIMPLELAY_RECORDER_AUDIO",
    "SIMPLELAY_MOTION_MODE",
    "SIMPLELAY_MOTION_PORT",
    "SIMPLELAY_MOTION_BAUD",
]

# 시험용 임의 값 — 실물 값 아님
_MOTION_TEST_ENV = {
    "SIMPLELAY_MOTION_R_OUT": "1000",
    "SIMPLELAY_MOTION_PULLEY_TEETH": "10",
    "SIMPLELAY_MOTION_BELT_PITCH_MM": "3",
    "SIMPLELAY_MOTION_X_MIN_MM": "0",
    "SIMPLELAY_MOTION_X_MAX_MM": "100",
    "SIMPLELAY_MOTION_Y_MIN_MM": "0",
    "SIMPLELAY_MOTION_Y_MAX_MM": "100",
    "SIMPLELAY_MOTION_A_SIGN": "1",
    "SIMPLELAY_MOTION_B_SIGN": "1",
    "SIMPLELAY_MOTION_PRESS_MODE": "depth",
    "SIMPLELAY_MOTION_PRESS_DEPTH_COUNTS": "40",
    "SIMPLELAY_MOTION_PRESS_DWELL_MS": "100",
    "SIMPLELAY_MOTION_STATUS_TIMEOUT_S": "1",
    "SIMPLELAY_MOTION_MOVE_TIMEOUT_S": "1",
    "SIMPLELAY_MOTION_PRESS_TIMEOUT_S": "1",
}


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _ENV + list(_MOTION_TEST_ENV):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def rec_dir():
    # pytest tmp_path는 이 기기에서 권한 오류가 나는 경우가 있어 표준 임시 폴더를 쓴다.
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        yield Path(tmp)


def _rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def _raise(exc):
    raise exc


def test_recorder_is_off_by_default(caplog):
    caplog.set_level(logging.INFO, logger=act_main.log.name)
    assert act_main._build_recorder() is None
    assert "press recorder off" in caplog.text


def test_executor_without_recorder_keeps_the_plain_client():
    executor = act_main._build_executor(object(), object())  # type: ignore[arg-type]
    assert isinstance(executor._controller._grbl, MockGrblClient)


def test_recorder_off_does_not_pass_a_hook(monkeypatch):
    calls = []
    monkeypatch.setattr(
        act_main,
        "_build_motion",
        lambda *a, **k: calls.append((a, k)) or (MockGrblClient(), MockSafetyController()),
    )
    act_main._build_executor(object(), object())  # type: ignore[arg-type]
    assert calls == [((), {})]


def test_recorder_on_logs_path_and_every_mock_source(monkeypatch, rec_dir, caplog):
    caplog.set_level(logging.INFO, logger=act_main.log.name)
    path = rec_dir / "sub" / "press.jsonl"
    monkeypatch.setenv("SIMPLELAY_RECORDER_PATH", str(path))
    live = act_main._build_recorder()
    try:
        assert isinstance(live, LiveRecorder)
        assert f"press recorder ON -> {path}" in caplog.text
        assert "no window" in caplog.text
        assert live.mock_sources == ["mock_current", "mock_audio", "mock_power"]
        warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
        for kind in ("current", "audio", "power"):
            assert any(f"source {kind} is MOCK" in w for w in warnings)
    finally:
        live.close()
    start = _rows(path)[0]
    assert start["event"] == "marker" and "mock_current(ADC gain 미설정)" in start["note"]


def test_failed_real_reader_falls_back_to_mock_loudly(monkeypatch, rec_dir, caplog):
    """ADC gain을 줬는데 장치를 못 열면 합성으로 대체하되 이유를 남긴다."""
    caplog.set_level(logging.INFO, logger=act_main.log.name)
    monkeypatch.setenv("SIMPLELAY_RECORDER_PATH", str(rec_dir / "p.jsonl"))
    monkeypatch.setenv("SIMPLELAY_RECORDER_ADC_GAIN", "1")
    monkeypatch.setattr(
        "rpi.verifier.recorder._open_ads1115", lambda gain, ch: _raise(RuntimeError("no i2c"))
    )
    live = act_main._build_recorder()
    try:
        assert "mock_current" in live.mock_sources
        assert "ADS1115 열기 실패: no i2c" in caplog.text
    finally:
        live.close()


def test_real_reader_is_used_when_it_opens(rec_dir):
    class _Reader:
        def read_voltage(self):
            return 1.25

    live = LiveRecorder(rec_dir / "r.jsonl", adc_gain=1, open_current=lambda g, c: _Reader())
    live.start()
    time.sleep(0.05)
    live.close()
    sources = {r["source"] for r in _rows(rec_dir / "r.jsonl")}
    assert "current" in sources and "mock_current" not in sources
    assert {"mock_audio", "mock_power"} <= sources


def test_window_env_must_come_in_pairs(monkeypatch, rec_dir):
    monkeypatch.setenv("SIMPLELAY_RECORDER_PATH", str(rec_dir / "p.jsonl"))
    monkeypatch.setenv("SIMPLELAY_RECORDER_PRE_S", "0.5")
    with pytest.raises(RuntimeError, match="pre_s와 post_s"):
        act_main._build_recorder()
    assert not (rec_dir / "p.jsonl").exists()  # 설정이 틀리면 파일도 열지 않는다


def test_csv_append_writes_the_header_once(rec_dir):
    path = rec_dir / "p.csv"
    LiveRecorder(path).close()
    LiveRecorder(path).close()
    lines = path.read_text(encoding="utf-8").splitlines()
    assert sum(1 for line in lines if line.startswith("t_monotonic_ns,")) == 1


def test_presses_are_recorded_through_the_mock_motion(monkeypatch, rec_dir):
    path = rec_dir / "press.jsonl"
    monkeypatch.setenv("SIMPLELAY_RECORDER_PATH", str(path))
    live = act_main._build_recorder()
    executor = act_main._build_executor(object(), object(), live)  # type: ignore[arg-type]
    grbl = executor._controller._grbl
    assert isinstance(grbl, RecordingGrblClient)
    assert grbl.execution_mode is MockGrblClient.execution_mode  # 기록기가 실행 출처를 바꾸지 않는다
    live.start()
    try:
        time.sleep(0.05)
        grbl.press(PressCommand(button="start"))
        time.sleep(0.05)
    finally:
        live.close()
    rows = _rows(path)
    events = [r["event"] for r in rows if r["source"] == "event"]
    assert events[1:3] == ["press_start", "press_end"]
    sources = {r["source"] for r in rows}
    assert {"mock_current", "mock_audio", "mock_power"} <= sources
    assert not {"current", "audio", "power"} & sources  # 합성이 실측처럼 찍히지 않는다

    # 이어 쓰기: 다시 켜도 앞 기록이 남는다
    LiveRecorder(path).close()
    assert len(_rows(path)) > len(rows)


def test_serial_motion_gets_the_mcu_event_hook(monkeypatch, rec_dir):
    for key, value in _MOTION_TEST_ENV.items():
        monkeypatch.setenv(key, value)
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "57600")
    monkeypatch.setenv("SIMPLELAY_MOTION_HOME_TIMEOUT_S", "5")  # 누르기 전 원점 잡기용(10/19)
    path = rec_dir / "serial.jsonl"
    monkeypatch.setenv("SIMPLELAY_RECORDER_PATH", str(path))
    live = act_main._build_recorder()
    try:
        executor = act_main._build_executor(object(), object(), live)  # type: ignore[arg-type]
        grbl = executor._controller._grbl
        assert isinstance(grbl, RecordingGrblClient)
        assert isinstance(grbl._inner, SerialMotionClient)
        assert grbl.execution_mode is ExecutionMode.REAL
        assert grbl.requires_coordinates is True
        grbl._inner.home()  # 실행기 시작 뒤에는 MCU의 homed를 믿지 않는다 — 이 프로세스가 원점을 잡는다(10/19)
        grbl.press(PressCommand(button="start", x_mm=10.0, y_mm=5.0))
    finally:
        live.close()
        mcu.close()
    # mcu_position(선택 위치 이벤트, 2026-09-29)은 이 시험의 관심 밖이라 뺀다.
    events = [r["event"] for r in _rows(path) if r["source"] == "event" and r["event"] != "mcu_position"]
    assert events[1:] == [
        "press_start",
        "mcu_press_command",
        "mcu_press_start",
        "mcu_press_end",
        "mcu_press_done",
        "press_end",
        "marker",
    ]
