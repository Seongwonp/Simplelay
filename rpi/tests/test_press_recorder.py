"""누름 주변 원시 기록기 — 값·시각·이벤트를 남기고 판정하지 않는다."""

from __future__ import annotations

import csv
import io
import json
import tempfile
import threading
from itertools import count
from pathlib import Path

import numpy as np
import pytest

import rpi.verifier.recorder as recorder_module
from rpi.controller import ExecutionMode, PressCommand
from rpi.controller.mock import MockGrblClient
from rpi.verifier.power import PowerSample
from rpi.verifier.recorder import (
    COLUMNS,
    CsvSink,
    JsonlSink,
    PressWindowRecorder,
    RecordingGrblClient,
    audio_reader_step,
    current_reader_step,
    main,
    mock_sources,
    motion_event_hook,
    power_sensor_step,
    run_source_loop,
)


def _jsonl(pre_s=None, post_s=None, keep_audio_samples=False):
    buffer = io.StringIO()
    ticks = count(1_000)
    rec = PressWindowRecorder(
        JsonlSink(buffer),
        clock=lambda: next(ticks),
        pre_s=pre_s,
        post_s=post_s,
        keep_audio_samples=keep_audio_samples,
    )
    return rec, buffer


def _rows(buffer: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in buffer.getvalue().splitlines()]


def test_no_judgement_columns():
    for banned in ("pressed", "threshold", "confidence", "success", "result", "current_a"):
        assert not any(banned in column for column in COLUMNS)


def test_recorder_does_not_import_judging_code():
    source = Path(recorder_module.__file__).read_text(encoding="utf-8")
    imports = [l for l in source.splitlines() if l.lstrip().startswith(("import ", "from "))]
    for judge in ("CurrentSensor,", "AudioSensor,", "fusion", "PowerSignatureDetector", "SensorVerifier"):
        assert not any(judge in line for line in imports), judge
    assert ".is_pressed(" not in source and "fuse(" not in source


def test_current_is_kept_as_raw_voltage_not_amperes():
    rec, buffer = _jsonl()
    rec.record_current_voltage(2.51234567)
    (row,) = _rows(buffer)
    assert row == {"t_monotonic_ns": 1000, "source": "current", "current_voltage": 2.51234567}


def test_power_keeps_sensor_time_and_host_time():
    rec, buffer = _jsonl()
    rec.record_power(PowerSample(t_s=12.5, watts=1180.25))
    (row,) = _rows(buffer)
    assert (row["power_watts"], row["power_sensor_t_s"], row["t_monotonic_ns"]) == (1180.25, 12.5, 1000)


def test_audio_frame_level_and_optional_pcm():
    rec, buffer = _jsonl(keep_audio_samples=True)
    rec.record_audio_frame(np.array([0.5, -1.0, 0.0, 0.5]))
    (row,) = _rows(buffer)
    assert row["audio_samples"] == 4
    assert row["audio_peak"] == 1.0
    assert row["audio_rms"] == pytest.approx(np.sqrt((0.25 + 1 + 0 + 0.25) / 4))
    assert row["audio_pcm"] == [0.5, -1.0, 0.0, 0.5]


def test_csv_sink_writes_fixed_header_and_full_precision():
    buffer = io.StringIO()
    rec = PressWindowRecorder(CsvSink(buffer), clock=lambda: 7)
    rec.record_current_voltage(0.1 + 0.2)
    rows = list(csv.DictReader(io.StringIO(buffer.getvalue())))
    assert list(rows[0].keys()) == list(COLUMNS)
    assert rows[0]["current_voltage"] == repr(0.1 + 0.2)


def test_event_names_are_validated():
    rec, _ = _jsonl()
    rec.mark("press_start")
    rec.mark("mcu_press_end")
    for bad in ("", "Press", "a,b", "x" * 40, "시작"):
        with pytest.raises(ValueError):
            rec.mark(bad)


def test_window_mode_keeps_only_samples_around_presses():
    buffer = io.StringIO()
    now = {"t": 0}
    rec = PressWindowRecorder(JsonlSink(buffer), clock=lambda: now["t"], pre_s=1.0, post_s=0.5)
    s = 1_000_000_000
    for t in (0, 5 * s, 9 * s + s // 2):  # 9.5 s만 사전 창(1 s) 안
        rec.record_current_voltage(float(t), t_ns=t)
    rec.mark("press_start", t_ns=10 * s)
    rec.record_current_voltage(1.0, t_ns=10 * s + 1)
    rec.mark("press_end", t_ns=11 * s)
    rec.record_current_voltage(2.0, t_ns=11 * s + s // 4)  # 사후 창(0.5 s) 안
    rec.record_current_voltage(3.0, t_ns=12 * s)  # 창 밖
    rows = _rows(buffer)
    kept = [r["t_monotonic_ns"] for r in rows if r["source"] == "current"]
    assert kept == [9 * s + s // 2, 10 * s + 1, 11 * s + s // 4]
    assert [r["event"] for r in rows if r["source"] == "event"] == ["press_start", "press_end"]


def test_window_needs_both_lengths():
    with pytest.raises(ValueError):
        PressWindowRecorder(JsonlSink(io.StringIO()), pre_s=1.0)


def test_without_window_everything_is_kept():
    rec, buffer = _jsonl()
    rec.record_current_voltage(1.0)
    rec.mark("press_start")
    rec.mark("press_end")
    rec.record_current_voltage(2.0)
    assert [r["source"] for r in _rows(buffer)] == ["current", "event", "event", "current"]


def test_recording_client_marks_presses_and_keeps_mode():
    rec, buffer = _jsonl()
    inner = MockGrblClient(responses=[None, RuntimeError("jam")])
    client = RecordingGrblClient(inner, rec)
    assert client.execution_mode is ExecutionMode.MOCK
    client.press(PressCommand("시작", x_mm=1.0, y_mm=2.0))
    with pytest.raises(RuntimeError):
        client.press(PressCommand("취소"))
    events = [(r["event"], r.get("note")) for r in _rows(buffer)]
    assert events == [
        ("press_start", "시작 x_mm=1.0 y_mm=2.0"),
        ("press_end", "시작"),
        ("press_start", "취소"),
        ("error", "취소: jam"),
        ("press_end", "취소"),
    ]


def test_motion_hook_prefixes_mcu_events():
    rec, buffer = _jsonl()
    hook = motion_event_hook(rec)
    hook("press_start", {"event": "press_start", "t_ms": 5})
    (row,) = _rows(buffer)
    assert row["event"] == "mcu_press_start"
    assert json.loads(row["note"]) == {"t_ms": 5}


def test_source_loop_reuses_existing_reader_interfaces_and_records_errors():
    rec, buffer = _jsonl()
    current, audio, power = mock_sources(n=4)
    for step in (current_reader_step(current, rec), audio_reader_step(audio, rec), power_sensor_step(power, rec)):
        step()

    stop = threading.Event()
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("i2c")
        stop.set()

    run_source_loop(flaky, rec, stop, label="current")
    sources = [r["source"] for r in _rows(buffer)]
    assert sources[:3] == ["current", "audio", "power"]
    assert _rows(buffer)[-1]["note"] == "current: i2c"


def test_cli_mock_run_writes_rows():
    # tmp_path 대신 tempfile — 이 환경의 pytest 임시 루트 권한 오류를 피하고 저장소에 흔적을 남기지 않는다.
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "rec.jsonl"
        assert main(["--mock", "--duration", "0.3", "--out", str(out), "--no-stdin"]) == 0
        rows = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines()]
    sources = {r["source"] for r in rows}
    assert {"current", "audio", "power", "event"} <= sources
    events = [r["event"] for r in rows if r["source"] == "event"]
    assert events[0] == "marker" and events[-1] == "marker"
    assert "press_start" in events and "press_end" in events


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["--current"],  # gain 없음
        ["--mock", "--audio", "--duration", "1"],  # 합성과 실측 섞기
        ["--mock"],  # 기간 없음
        ["--mock", "--duration", "1", "--pre-s", "1"],
    ],
)
def test_cli_refuses_ambiguous_setups(argv, capsys):
    with pytest.raises(SystemExit):
        main(argv)
