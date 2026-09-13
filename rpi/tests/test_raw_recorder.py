"""원시 센서 기록기 — 값·시각·이벤트를 그대로 남기고, 판정은 하지 않는다."""

import csv
import io
import threading
from datetime import datetime
from itertools import count
from pathlib import Path

import pytest

import rpi.bench.raw_recorder as raw_recorder
from rpi.bench.raw_recorder import (
    COLUMNS,
    RawCsvRecorder,
    default_out_path,
    handle_command,
    main,
    run_adc_loop,
)


def _recorder(start: int = 1_000):
    ticks = count(start)
    buffer = io.StringIO()
    return RawCsvRecorder(buffer, clock=lambda: next(ticks)), buffer


def _rows(buffer: io.StringIO) -> list[dict[str, str]]:
    return list(csv.DictReader(io.StringIO(buffer.getvalue())))


def test_header_is_the_fixed_column_set():
    _, buffer = _recorder()

    assert buffer.getvalue().splitlines()[0].split(",") == list(COLUMNS)


def test_columns_carry_no_judgement():
    """판정 결과·임계값 열이 없다 — 측정값을 먼저 본다."""
    for banned in ("pressed", "threshold", "confidence", "success", "result"):
        assert not any(banned in column for column in COLUMNS)


def test_recorder_does_not_depend_on_the_verifier():
    source = Path(raw_recorder.__file__).read_text(encoding="utf-8")
    import_lines = [
        line for line in source.splitlines() if line.lstrip().startswith(("import ", "from "))
    ]
    assert not any("verifier" in line for line in import_lines)


def test_adc_row_keeps_raw_value_and_full_precision_voltage():
    recorder, buffer = _recorder()

    recorder.record_adc(20_123, 2.51234567)

    (row,) = _rows(buffer)
    assert row["source"] == "adc"
    assert row["t_monotonic_ns"] == "1000"
    assert row["adc_value"] == "20123"
    assert float(row["adc_voltage"]) == 2.51234567
    assert row["audio_rms"] == row["event"] == ""


def test_audio_block_level_is_rms_peak_and_sample_count():
    recorder, buffer = _recorder()

    recorder.record_audio_block([0.5, -0.5, 0.5, -0.5])
    recorder.record_audio_block([0.0, 0.25, -1.0])

    first, second = _rows(buffer)
    assert float(first["audio_rms"]) == pytest.approx(0.5)
    assert float(first["audio_peak"]) == pytest.approx(0.5)
    assert first["audio_samples"] == "4"
    assert float(second["audio_peak"]) == pytest.approx(1.0)
    assert second["adc_value"] == ""


def test_empty_audio_block_is_recorded_without_levels():
    recorder, buffer = _recorder()

    recorder.record_audio_block([])

    (row,) = _rows(buffer)
    assert row["audio_samples"] == "0"
    assert row["audio_rms"] == row["audio_peak"] == ""


def test_press_events_share_the_same_clock():
    recorder, buffer = _recorder()

    recorder.mark("press_start")
    recorder.record_adc(1, 0.1)
    recorder.mark("press_end", note="버튼 3")

    rows = _rows(buffer)
    assert [r["event"] for r in rows] == ["press_start", "", "press_end"]
    assert [int(r["t_monotonic_ns"]) for r in rows] == [1000, 1001, 1002]
    assert rows[2]["note"] == "버튼 3"


def test_explicit_timestamp_is_kept_as_given():
    recorder, buffer = _recorder()

    recorder.record_audio_block([0.1], t_ns=42)

    assert _rows(buffer)[0]["t_monotonic_ns"] == "42"


def test_unknown_event_is_rejected():
    recorder, _ = _recorder()

    with pytest.raises(ValueError):
        recorder.mark("pressed")


def test_concurrent_writers_do_not_interleave_rows():
    recorder, buffer = _recorder()

    def adc():
        for i in range(300):
            recorder.record_adc(i, 0.001 * i)

    def audio():
        for _ in range(300):
            recorder.record_audio_block([0.1, -0.1])

    threads = [threading.Thread(target=adc), threading.Thread(target=audio)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    rows = _rows(buffer)
    assert len(rows) == recorder.rows == 600
    assert all(len(row) == len(COLUMNS) for row in rows)
    # 시각을 넘기지 않은 행은 파일 순서가 곧 시각 순서다
    stamps = [int(row["t_monotonic_ns"]) for row in rows]
    assert stamps == sorted(stamps)


class _FlakySource:
    def __init__(self, stop: threading.Event, fail_on: set[int], total: int) -> None:
        self._stop = stop
        self._fail_on = fail_on
        self._total = total
        self.calls = 0

    def read(self):
        self.calls += 1
        if self.calls >= self._total:
            self._stop.set()
        if self.calls in self._fail_on:
            raise OSError("i2c nack")
        return self.calls, self.calls * 0.001


def test_adc_loop_records_errors_and_keeps_going_until_stopped():
    recorder, buffer = _recorder()
    stop = threading.Event()
    source = _FlakySource(stop, fail_on={2}, total=4)

    run_adc_loop(source, recorder, stop)

    rows = _rows(buffer)
    assert [r["source"] for r in rows] == ["adc", "event", "adc", "adc"]
    assert rows[1]["event"] == "error"
    assert "i2c nack" in rows[1]["note"]


@pytest.mark.parametrize(
    ("line", "event", "note", "keep_going"),
    [
        ("s\n", "press_start", "", True),
        ("e\n", "press_end", "", True),
        ("빗맞음 의심\n", "marker", "빗맞음 의심", True),
        ("q\n", None, None, False),
        ("\n", None, None, True),
    ],
)
def test_keyboard_commands_map_to_events(line, event, note, keep_going):
    recorder, buffer = _recorder()

    assert handle_command(line, recorder) is keep_going

    rows = _rows(buffer)
    if event is None:
        assert rows == []
    else:
        assert (rows[0]["event"], rows[0]["note"]) == (event, note)


def test_default_output_is_under_the_ignored_data_directory():
    path = default_out_path(datetime(2026, 9, 28, 14, 5, 9))

    assert path == Path("data") / "bench" / "raw-20260928-140509.csv"


@pytest.mark.parametrize(
    "argv",
    [[], ["--adc"]],
    ids=["no-source", "adc-without-gain"],
)
def test_cli_refuses_ambiguous_setups(argv, capsys):
    with pytest.raises(SystemExit) as exc:
        main(argv)

    assert exc.value.code == 2
