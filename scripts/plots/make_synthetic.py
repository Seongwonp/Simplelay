"""그래프 4종의 **합성** 입력을 만든다 — 도구 점검·문서 예시용. 실측이 아니다.

표 CSV에는 ``data_kind=synthetic`` 열을, 기록기 파일에는 ``mock_power`` source를 넣는다.
그래서 이 입력으로 만든 그림에는 항상 "예시(합성 데이터)" 워터마크가 붙는다.
숫자는 고정 시드의 가짜 값이며 발표·보고서에 수치로 쓰지 않는다.

    python -m scripts.plots.make_synthetic --out-dir data/bench/plots_example --render
"""

from __future__ import annotations

import argparse
import csv
import io
import math
import random
from collections.abc import Sequence
from pathlib import Path

from rpi.verifier.power import PowerSample
from rpi.verifier.recorder import CsvSink, PressWindowRecorder

from . import offset_scatter, power_decision, stop_latency, success_rate
from .common import SYNTHETIC

BUTTONS = ("즉석밥", "시작", "취소")
DECISION_EVENT = power_decision.DEFAULT_DECISION_EVENT


def _write_table(path: Path, header: Sequence[str], rows: list[list[object]]) -> Path:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow([*header, "data_kind"])
        for row in rows:
            writer.writerow([*row, SYNTHETIC])
    return path


def write_inputs(out_dir: str | Path, seed: int = 7) -> dict[str, Path]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    paths: dict[str, Path] = {}

    rows: list[list[object]] = []
    for b_index, button in enumerate(BUTTONS):
        tx, ty = 20.0 + 25.0 * b_index, 40.0
        for trial in range(1, 31):
            rows.append([button, trial, tx, ty, round(tx + rng.gauss(0.3, 0.6), 2), round(ty + rng.gauss(-0.2, 0.5), 2)])
    paths["offset"] = _write_table(out / "offset.csv", offset_scatter.REQUIRED, rows)

    rows = []
    for button in BUTTONS:
        for trial in range(1, 33):
            injected = 1 if trial > 30 else 0
            first = 1 if rng.random() < 0.85 else 0
            final = 1 if first or rng.random() < 0.8 else 0
            retries = 0 if first else rng.randint(1, 2)
            rows.append([button, trial, injected, first, final, retries])
    paths["success"] = _write_table(out / "success.csv", success_rate.REQUIRED, rows)

    rows = []
    for trial in range(1, 21):
        path = ("키오스크", "폰", "물리 버튼")[trial % 3]
        t0 = 1000.0 * trial
        t1 = t0 + max(5.0, rng.gauss(60, 20))
        t2 = t1 + max(5.0, rng.gauss(120, 50))
        t3 = t2 + max(5.0, rng.gauss(40, 15))
        rows.append([trial, path, ("이동 중", "누름 중")[trial % 2], t0, round(t1, 1), round(t2, 1), round(t3, 1)])
    paths["stop"] = _write_table(out / "stop.csv", stop_latency.REQUIRED, rows)

    buffer = io.StringIO()
    recorder = PressWindowRecorder(CsvSink(buffer))
    base = 10_000_000_000
    for i in range(400):  # 0.1 s 간격 40 s
        t_s = i * 0.1
        if t_s < 5.0:
            w = 2.0 + rng.gauss(0, 0.2)
        elif t_s < 6.0:
            w = 2.0 + (t_s - 5.0) * 1100 + rng.gauss(0, 10)
        elif t_s < 35.0:
            w = 1150 + 40 * math.sin(t_s) + rng.gauss(0, 15)
        else:
            w = 2.0 + rng.gauss(0, 0.2)
        recorder.record_power(PowerSample(t_s=t_s, watts=max(0.0, w)), t_ns=base + int(t_s * 1e9), source="mock_power")
    recorder.mark("press_start", "시작 (합성)", t_ns=base + int(4.6e9))
    recorder.mark("press_end", "시작 (합성)", t_ns=base + int(4.9e9))
    recorder.mark(DECISION_EVENT, "합성 판정 시각", t_ns=base + int(6.4e9))
    rec_path = out / "power_recording.csv"
    rec_path.write_text(buffer.getvalue(), encoding="utf-8", newline="")
    paths["power"] = rec_path
    return paths


def render_all(paths: dict[str, Path], out_dir: str | Path) -> list[Path]:
    from .common import save

    out = Path(out_dir)
    made = []
    points, kind = offset_scatter.load(paths["offset"])
    made.append(save(offset_scatter.render(points, kind), out / "example_1_offset.png"))
    rates, kind = success_rate.load(paths["success"])
    made.append(save(success_rate.render(rates, kind), out / "example_2_success.png"))
    trials, kind = stop_latency.load(paths["stop"])
    made.append(save(stop_latency.render(trials, kind), out / "example_3_stop.png"))
    trace, kind = power_decision.load(paths["power"])
    made.append(save(power_decision.render(trace, kind), out / "example_4_power.png"))
    return made


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", default=str(Path("data") / "bench" / "plots_example"))
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--render", action="store_true", help="합성 입력으로 예시 PNG 4장도 만든다(워터마크)")
    args = parser.parse_args(argv)
    paths = write_inputs(args.out_dir, args.seed)
    for p in paths.values():
        print(p)
    if args.render:
        for p in render_all(paths, args.out_dir):
            print(p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
