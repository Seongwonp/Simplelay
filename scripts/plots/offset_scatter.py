"""그래프 1 — 목표 좌표 대비 실제 누른 위치 오차(버튼별 산점도, 목표를 원점으로).

입력 CSV 열: button, trial, target_x_mm, target_y_mm, actual_x_mm, actual_y_mm [, data_kind, note]
합격선은 실측 후 정한다 — ``--tolerance-mm``을 줄 때만 원을 그린다.

    python -m scripts.plots.offset_scatter offset.csv --out offset.png [--data-kind measured]
"""

from __future__ import annotations

import argparse
import math
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .common import DataError, add_kind_args, finish_figure, pyplot, read_table, run_cli, save, to_float

REQUIRED = ("button", "trial", "target_x_mm", "target_y_mm", "actual_x_mm", "actual_y_mm")


@dataclass(frozen=True)
class OffsetPoint:
    button: str
    dx_mm: float
    dy_mm: float


def load(path: str | Path, flag: str | None = None) -> tuple[list[OffsetPoint], str]:
    rows, kind = read_table(path, REQUIRED, optional=("note",), flag=flag)
    points = []
    for i, row in enumerate(rows, start=1):
        where = f"{Path(path).name} {i}번째 시도"
        points.append(OffsetPoint(
            row["button"],
            to_float(row, "actual_x_mm", where) - to_float(row, "target_x_mm", where),
            to_float(row, "actual_y_mm", where) - to_float(row, "target_y_mm", where),
        ))
    return points, kind


def render(points: Sequence[OffsetPoint], kind: str, tolerance_mm: float | None = None):
    if not points:
        raise DataError("오차 점이 없습니다")
    plt = pyplot()
    fig, ax = plt.subplots(figsize=(6.4, 6.0))
    buttons = list(dict.fromkeys(p.button for p in points))
    for button in buttons:
        mine = [p for p in points if p.button == button]
        rms = math.sqrt(sum(p.dx_mm ** 2 + p.dy_mm ** 2 for p in mine) / len(mine))
        ax.scatter([p.dx_mm for p in mine], [p.dy_mm for p in mine], s=22, alpha=0.75,
                   label=f"{button} (n={len(mine)}, RMS {rms:.2f} mm)")
    ax.axhline(0, color="#888", lw=0.8)
    ax.axvline(0, color="#888", lw=0.8)
    ax.plot([0], [0], marker="+", color="black", ms=14, mew=1.5)
    if tolerance_mm is not None:
        if not (math.isfinite(tolerance_mm) and tolerance_mm > 0):
            raise DataError(f"--tolerance-mm은 양수여야 합니다: {tolerance_mm!r}")
        ax.add_patch(plt.Circle((0, 0), tolerance_mm, fill=False, ls="--", color="#2c7"))
        ax.text(0, tolerance_mm, f" 합격선 {tolerance_mm:g} mm", va="bottom", fontsize=9, color="#2a6")
        lim_extra = tolerance_mm
    else:
        lim_extra = 0.0
        ax.text(0.02, 0.02, "합격선: 실측 후 정함", transform=ax.transAxes, fontsize=9, color="#555")
    lim = max(max(abs(p.dx_mm), abs(p.dy_mm)) for p in points)
    lim = max(lim, lim_extra, 0.5) * 1.15
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect("equal")
    ax.set_xlabel("X 오차 (실제 − 목표, mm)")
    ax.set_ylabel("Y 오차 (실제 − 목표, mm)")
    ax.set_title("목표 좌표 대비 실제 누른 위치 오차")
    ax.legend(fontsize=8, loc="upper right")
    ax.grid(alpha=0.3)
    finish_figure(fig, kind)
    return fig


def _main(argv: Sequence[str] | None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv")
    parser.add_argument("--tolerance-mm", type=float, default=None)
    add_kind_args(parser)
    args = parser.parse_args(argv)
    points, kind = load(args.csv, args.data_kind)
    print(save(render(points, kind, args.tolerance_mm), args.out))


def main(argv: Sequence[str] | None = None) -> int:
    return run_cli(_main, argv)


if __name__ == "__main__":
    raise SystemExit(main())
