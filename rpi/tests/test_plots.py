"""scripts/plots/ — 실측 그래프 4종 도구(docs/실측-계획-결선.md §도구).

지키는 것:
  1. 빈 파일·머리행만·빈 칸·열 빠짐·파일 없음은 그림 없이 거절한다(빈칸은 '모름').
  2. 실측/합성은 data_kind 열·--data-kind·기록기 source(mock_*)로만 정한다. 정해지지 않거나
     어긋나거나 섞이면 거절한다 — 추측하지 않는다.
  3. "예시(합성 데이터)" 워터마크는 합성일 때만, 실측일 때는 절대 붙지 않는다.
"""

from __future__ import annotations

import csv
from pathlib import Path

import pytest

from scripts.plots import common, make_synthetic, offset_scatter, power_decision, stop_latency, success_rate
from scripts.plots.common import DataError

LOADERS = {
    "offset": offset_scatter,
    "success": success_rate,
    "stop": stop_latency,
    "power": power_decision,
}


@pytest.fixture()
def synthetic(tmp_path: Path) -> dict[str, Path]:
    return make_synthetic.write_inputs(tmp_path / "syn")


def _rewrite_kind(src: Path, dst: Path, kind: str | None) -> Path:
    """표 CSV의 data_kind 열을 바꾸거나(kind) 지운다(None)."""
    with src.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    header = [c for c in rows[0] if c != "data_kind"] + ([] if kind is None else ["data_kind"])
    with dst.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, header, lineterminator="\n", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            if kind is not None:
                row["data_kind"] = kind
            writer.writerow(row)
    return dst


def _measured_recording(src: Path, dst: Path) -> Path:
    """합성 기록의 source를 실측 이름으로 바꾼 사본(워터마크 없음 확인용)."""
    dst.write_text(src.read_text(encoding="utf-8").replace(",mock_power,", ",power,"), encoding="utf-8")
    return dst


def _measured_inputs(synthetic: dict[str, Path], tmp_path: Path) -> dict[str, Path]:
    out = tmp_path / "real"
    out.mkdir()
    paths = {k: _rewrite_kind(v, out / v.name, common.MEASURED) for k, v in synthetic.items() if k != "power"}
    paths["power"] = _measured_recording(synthetic["power"], out / "power_recording.csv")
    return paths


# ── 1. 빈 입력·결측 거절 ───────────────────────────────────────────────────


@pytest.mark.parametrize("name", list(LOADERS))
def test_missing_file_is_rejected(name: str, tmp_path: Path) -> None:
    with pytest.raises(DataError, match="없습니다"):
        LOADERS[name].load(tmp_path / "nope.csv", common.MEASURED)


@pytest.mark.parametrize("name", list(LOADERS))
def test_zero_byte_file_is_rejected(name: str, tmp_path: Path) -> None:
    path = tmp_path / "empty.csv"
    path.write_bytes(b"")
    with pytest.raises(DataError, match="비었습니다"):
        LOADERS[name].load(path, common.MEASURED)


@pytest.mark.parametrize("name", ["offset", "success", "stop"])
def test_header_only_table_is_rejected(name: str, tmp_path: Path) -> None:
    path = tmp_path / "header.csv"
    path.write_text(",".join(LOADERS[name].REQUIRED) + "\n\n", encoding="utf-8")
    with pytest.raises(DataError, match="데이터 행이 없습니다"):
        LOADERS[name].load(path, common.MEASURED)


def test_header_only_recording_is_rejected(tmp_path: Path) -> None:
    from rpi.verifier.recorder import COLUMNS

    path = tmp_path / "rec.csv"
    path.write_text(",".join(COLUMNS) + "\n", encoding="utf-8")
    with pytest.raises(DataError, match="기록 행이 없습니다"):
        power_decision.load(path)


@pytest.mark.parametrize("name", ["offset", "success", "stop"])
def test_blank_required_cell_is_rejected_with_row_number(name: str, synthetic, tmp_path: Path) -> None:
    lines = synthetic[name].read_text(encoding="utf-8").splitlines()
    cells = lines[3].split(",")
    cells[-2] = ""  # data_kind 앞의 마지막 필수 열
    lines[3] = ",".join(cells)
    path = tmp_path / f"{name}.csv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    with pytest.raises(DataError, match="4행: 빈 칸"):
        LOADERS[name].load(path)


@pytest.mark.parametrize("name", ["offset", "success", "stop"])
def test_missing_column_is_rejected(name: str, synthetic, tmp_path: Path) -> None:
    dropped = LOADERS[name].REQUIRED[-1]
    with synthetic[name].open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    path = tmp_path / f"{name}.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, [c for c in rows[0] if c != dropped], extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    with pytest.raises(DataError, match=f"필수 열이 없습니다: {dropped}"):
        LOADERS[name].load(path)


def test_non_numeric_value_is_rejected(synthetic, tmp_path: Path) -> None:
    text = synthetic["offset"].read_text(encoding="utf-8").splitlines()
    cells = text[1].split(",")
    cells[4] = "약 20"
    text[1] = ",".join(cells)
    path = tmp_path / "offset.csv"
    path.write_text("\n".join(text) + "\n", encoding="utf-8")
    with pytest.raises(DataError, match="숫자가 아닙니다"):
        offset_scatter.load(path)


def test_success_contradiction_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "s.csv"
    path.write_text(
        "button,trial,fault_injected,first_press_ok,final_press_ok,retries\n시작,1,0,1,0,0\n", encoding="utf-8"
    )
    with pytest.raises(DataError, match="모순"):
        success_rate.load(path, common.MEASURED)


def test_success_button_with_only_injected_trials_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "s.csv"
    path.write_text(
        "button,trial,fault_injected,first_press_ok,final_press_ok,retries\n시작,1,1,0,1,1\n", encoding="utf-8"
    )
    with pytest.raises(DataError, match="자연 시도가 없는 버튼"):
        success_rate.load(path, common.MEASURED)


def test_stop_time_order_violation_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "stop.csv"
    path.write_text(
        ",".join(stop_latency.REQUIRED) + "\n1,폰,이동 중,100,90,200,250\n", encoding="utf-8"
    )
    with pytest.raises(DataError, match="시각 순서"):
        stop_latency.load(path, common.MEASURED)


def test_recording_without_power_rows_is_rejected(tmp_path: Path) -> None:
    from io import StringIO

    from rpi.verifier.recorder import CsvSink, PressWindowRecorder

    buf = StringIO()
    rec = PressWindowRecorder(CsvSink(buf))
    rec.record_current_voltage(2.5, t_ns=1, source="current")
    rec.mark("press_start", t_ns=2)
    path = tmp_path / "rec.csv"
    path.write_text(buf.getvalue(), encoding="utf-8")
    with pytest.raises(DataError, match="전력 파형 행"):
        power_decision.load(path, decision_t_ns=1)


def test_recording_without_decision_is_rejected(synthetic, tmp_path: Path) -> None:
    with pytest.raises(DataError, match="판정 이벤트"):
        power_decision.load(synthetic["power"], decision_event="no_such_event")
    with pytest.raises(DataError, match="파형 구간"):
        power_decision.load(synthetic["power"], decision_t_ns=1)


# ── 2. 실측/합성은 메타데이터로만 ─────────────────────────────────────────


@pytest.mark.parametrize("name", ["offset", "success", "stop"])
def test_table_without_kind_needs_explicit_flag(name: str, synthetic, tmp_path: Path) -> None:
    bare = _rewrite_kind(synthetic[name], tmp_path / f"{name}.csv", None)
    with pytest.raises(DataError, match="추측하지 않습니다"):
        LOADERS[name].load(bare)
    assert LOADERS[name].load(bare, common.MEASURED)[1] == common.MEASURED
    assert LOADERS[name].load(bare, common.SYNTHETIC)[1] == common.SYNTHETIC


@pytest.mark.parametrize("name", ["offset", "success", "stop"])
def test_flag_contradicting_input_is_rejected(name: str, synthetic) -> None:
    with pytest.raises(DataError, match="입력은 synthetic인데"):
        LOADERS[name].load(synthetic[name], common.MEASURED)


def test_mixed_data_kind_rows_are_rejected(synthetic, tmp_path: Path) -> None:
    lines = synthetic["offset"].read_text(encoding="utf-8").splitlines()
    lines[2] = lines[2].rsplit(",", 1)[0] + "," + common.MEASURED
    path = tmp_path / "offset.csv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    with pytest.raises(DataError, match="섞여"):
        offset_scatter.load(path)


def test_unknown_kind_value_is_rejected(synthetic, tmp_path: Path) -> None:
    path = _rewrite_kind(synthetic["offset"], tmp_path / "offset.csv", "real")
    with pytest.raises(DataError, match="data_kind 값"):
        offset_scatter.load(path)


def test_recording_kind_comes_from_source_column(synthetic, tmp_path: Path) -> None:
    assert power_decision.load(synthetic["power"])[1] == common.SYNTHETIC
    real = _measured_recording(synthetic["power"], tmp_path / "real.csv")
    assert power_decision.load(real)[1] == common.MEASURED
    with pytest.raises(DataError, match="입력은 measured인데"):
        power_decision.load(real, common.SYNTHETIC)


def test_recording_mixing_mock_and_real_power_is_rejected(synthetic, tmp_path: Path) -> None:
    lines = synthetic["power"].read_text(encoding="utf-8").splitlines()
    lines[5] = lines[5].replace(",mock_power,", ",power,")
    path = tmp_path / "mixed.csv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    with pytest.raises(DataError, match="섞여"):
        power_decision.load(path)


def test_jsonl_recording_is_read(tmp_path: Path) -> None:
    from rpi.verifier.power import PowerSample
    from rpi.verifier.recorder import JsonlSink, PressWindowRecorder

    path = tmp_path / "rec.jsonl"
    with path.open("w", encoding="utf-8") as handle:
        rec = PressWindowRecorder(JsonlSink(handle))
        for i in range(5):
            rec.record_power(PowerSample(t_s=i * 0.1, watts=2.0 + i), t_ns=i * 100)
        rec.mark("l3_start_confirmed", t_ns=250)
    trace, kind = power_decision.load(path)
    assert kind == common.MEASURED and trace.decision_ns == 250 and len(trace.watts) == 5


# ── 3. 워터마크: 합성일 때만 ───────────────────────────────────────────────


def _render(name: str, path: Path):
    data, kind = LOADERS[name].load(path)
    return LOADERS[name].render(data, kind)


def _all_text(fig) -> list[str]:
    texts = [t.get_text() for t in fig.texts]
    for ax in fig.axes:
        texts += [t.get_text() for t in ax.texts] + [ax.get_title()]
    return texts


@pytest.mark.parametrize("name", list(LOADERS))
def test_synthetic_figure_has_watermark(name: str, synthetic) -> None:
    pytest.importorskip("matplotlib")
    fig = _render(name, synthetic[name])
    assert common.has_watermark(fig)
    assert common.WATERMARK_TEXT in _all_text(fig)


@pytest.mark.parametrize("name", list(LOADERS))
def test_measured_figure_has_no_watermark(name: str, synthetic, tmp_path: Path) -> None:
    pytest.importorskip("matplotlib")
    fig = _render(name, _measured_inputs(synthetic, tmp_path)[name])
    assert not common.has_watermark(fig)
    assert not any("합성" in t for t in _all_text(fig))


def test_finish_figure_rejects_unknown_kind() -> None:
    plt = pytest.importorskip("matplotlib.pyplot")
    fig = plt.figure()
    with pytest.raises(DataError):
        common.finish_figure(fig, "real")


def test_cli_writes_png_for_valid_input_and_nothing_for_bad(synthetic, tmp_path: Path, capsys) -> None:
    pytest.importorskip("matplotlib")
    out = tmp_path / "out" / "offset.png"
    assert offset_scatter.main([str(synthetic["offset"]), "--out", str(out)]) == 0
    assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    bad = tmp_path / "bad.png"
    assert offset_scatter.main([str(tmp_path / "missing.csv"), "--out", str(bad)]) == 2
    assert not bad.exists()
    assert "그리지 않음" in capsys.readouterr().err
