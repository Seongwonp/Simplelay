"""그래프 3 — 정지 요청부터 모터 정지까지 지연 분포(구간별).

입력 CSV 열(한 행 = 정지 한 번, 시각은 같은 시각축의 ms — 맞춤 오차는 note에):
  trial, path, stop_phase, t0_press_ms, t1_accepted_ms, t2_loop_end_ms, t3_physical_stop_ms
  [, data_kind, note]
  - t0: 사람이 정지를 누른 순간(영상 프레임)
  - t1: 서버 정지 접수(실행 이력 stop_requested_at)
  - t2: 실행 루프 종료(실행 이력 종료 시각)
  - t3: 모터가 실제로 멈춘 순간(영상 프레임 또는 엔코더 속도 0)
구간 정의는 docs/실측-기록표.md §5. 시각 순서가 어긋나면(t0 ≤ t1 ≤ t2 ≤ t3가 아니면) 거절한다.

    python -m scripts.plots.stop_latency stop.csv --out stop.png [--data-kind measured]
"""

from __future__ import annotations

import argparse
import statistics
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .common import DataError, add_kind_args, finish_figure, pyplot, read_table, run_cli, save, to_float

TIMES = ("t0_press_ms", "t1_accepted_ms", "t2_loop_end_ms", "t3_physical_stop_ms")
REQUIRED = ("trial", "path", "stop_phase", *TIMES)
SEGMENTS = (
    ("누름→접수 (t0→①)", 0, 1),
    ("접수→루프 종료 (①→②)", 1, 2),
    ("루프 종료→물리 정지 (②→③)", 2, 3),
    ("누름→물리 정지 (t0→③)", 0, 3),
)


@dataclass(frozen=True)
class StopTrial:
    trial: str
    path: str
    phase: str
    times_ms: tuple[float, float, float, float]

    def segment(self, a: int, b: int) -> float:
        return self.times_ms[b] - self.times_ms[a]


def load(path: str | Path, flag: str | None = None) -> tuple[list[StopTrial], str]:
    rows, kind = read_table(path, REQUIRED, optional=("note",), flag=flag)
    trials = []
    for i, row in enumerate(rows, start=1):
        where = f"{Path(path).name} {i}번째 정지"
        times = tuple(to_float(row, c, where) for c in TIMES)
        if any(b < a for a, b in zip(times, times[1:])):
            raise DataError(f"{where}: 시각 순서가 t0 ≤ t1 ≤ t2 ≤ t3가 아닙니다 {times} — 시각 맞춤을 확인하세요")
        trials.append(StopTrial(row["trial"], row["path"], row["stop_phase"], times))  # type: ignore[arg-type]
    return trials, kind


def render(trials: Sequence[StopTrial], kind: str):
    if not trials:
        raise DataError("정지 기록이 없습니다")
    plt = pyplot()
    fig, ax = plt.subplots(figsize=(7.2, 4.4))
    paths = list(dict.fromkeys(t.path for t in trials))
    for row, (label, a, b) in enumerate(SEGMENTS):
        y = len(SEGMENTS) - 1 - row
        values = [t.segment(a, b) for t in trials]
        for p_index, p in enumerate(paths):
            mine = [(i, t.segment(a, b)) for i, t in enumerate(trials) if t.path == p]
            # 결정적 흩뿌림(무작위 없음) — 같은 입력이면 같은 그림
            ys = [y + ((i % 7) - 3) * 0.035 for i, _ in mine]
            ax.scatter([v for _, v in mine], ys, s=16, alpha=0.75, color=f"C{p_index}",
                       label=p if row == 0 else None)
        med = statistics.median(values)
        ax.plot([med, med], [y - 0.3, y + 0.3], color="black", lw=2)
        ax.text(max(values), y + 0.18, f"  p50 {med:.0f} · 최대 {max(values):.0f} ms", fontsize=8, va="center")
    ax.set_yticks(range(len(SEGMENTS)), [s[0] for s in reversed(SEGMENTS)], fontsize=9)
    ax.set_xlabel("지연 (ms)")
    ax.set_title(f"정지 요청 → 모터 정지 지연 (n={len(trials)})")
    ax.legend(title="정지 경로", fontsize=8, title_fontsize=8, loc="upper left", bbox_to_anchor=(1.01, 1.0))
    ax.grid(axis="x", alpha=0.3)
    ax.set_xlim(left=0)
    ax.margins(x=0.25)
    ax.text(0.01, 0.99, "합격선: 실측 후 정함 · 검은 막대 = 중앙값", transform=ax.transAxes,
            fontsize=8, va="top", color="#555")
    finish_figure(fig, kind)
    return fig


def _main(argv: Sequence[str] | None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv")
    add_kind_args(parser)
    args = parser.parse_args(argv)
    trials, kind = load(args.csv, args.data_kind)
    print(save(render(trials, kind), args.out))


def main(argv: Sequence[str] | None = None) -> int:
    return run_cli(_main, argv)


if __name__ == "__main__":
    raise SystemExit(main())
