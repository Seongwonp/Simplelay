"""그래프 2 — 버튼별 누름 성공률(첫 시도 / 재시도 포함 최종).

입력 CSV 열(한 행 = 한 버튼 누름, 판정은 사람):
  button, trial, fault_injected, first_press_ok, final_press_ok, retries [, data_kind, note]
``fault_injected=1``(실패 주입) 시도는 자연 성공률에서 뺀다(docs/실측-기록표.md §4).
버튼당 계획 표본은 30회 이상이다. 그보다 적으면 그림에 "표본 부족"을 적는다.

    python -m scripts.plots.success_rate success.csv --out success.png [--data-kind measured]
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .common import DataError, add_kind_args, finish_figure, pyplot, read_table, run_cli, save, to_flag01

REQUIRED = ("button", "trial", "fault_injected", "first_press_ok", "final_press_ok", "retries")
PLANNED_TRIALS_PER_BUTTON = 30


@dataclass(frozen=True)
class ButtonRate:
    button: str
    n: int
    first_ok: int
    final_ok: int
    excluded_injected: int

    @property
    def first_rate(self) -> float:
        return self.first_ok / self.n

    @property
    def final_rate(self) -> float:
        return self.final_ok / self.n


def load(path: str | Path, flag: str | None = None) -> tuple[list[ButtonRate], str]:
    rows, kind = read_table(path, REQUIRED, optional=("note",), flag=flag)
    stats: dict[str, list[int]] = {}
    for i, row in enumerate(rows, start=1):
        where = f"{Path(path).name} {i}번째 시도"
        injected = to_flag01(row, "fault_injected", where)
        first = to_flag01(row, "first_press_ok", where)
        final = to_flag01(row, "final_press_ok", where)
        try:
            retries = int(row["retries"])
        except ValueError:
            raise DataError(f"{where}: retries가 정수가 아닙니다: {row['retries']!r}") from None
        if retries < 0:
            raise DataError(f"{where}: retries가 음수입니다")
        if first and not final:
            raise DataError(f"{where}: 첫 시도 성공인데 최종 실패 — 기록이 모순입니다")
        if first and retries:
            raise DataError(f"{where}: 첫 시도 성공인데 재시도 {retries}회 — 기록이 모순입니다")
        s = stats.setdefault(row["button"], [0, 0, 0, 0])  # n, first, final, injected
        if injected:
            s[3] += 1
            continue
        s[0] += 1
        s[1] += first
        s[2] += final
    rates = [ButtonRate(b, n, f1, f2, inj) for b, (n, f1, f2, inj) in stats.items()]
    empty = [r.button for r in rates if r.n == 0]
    if empty:
        raise DataError(f"실패 주입을 뺀 자연 시도가 없는 버튼: {', '.join(empty)}")
    return rates, kind


def render(rates: Sequence[ButtonRate], kind: str):
    if not rates:
        raise DataError("버튼 기록이 없습니다")
    plt = pyplot()
    fig, ax = plt.subplots(figsize=(max(5.0, 1.6 * len(rates) + 2), 4.6))
    xs = range(len(rates))
    width = 0.38
    first = ax.bar([x - width / 2 for x in xs], [100 * r.first_rate for r in rates], width, label="첫 시도")
    final = ax.bar([x + width / 2 for x in xs], [100 * r.final_rate for r in rates], width, label="재시도 포함 최종")
    for bars, values in ((first, [r.first_rate for r in rates]), (final, [r.final_rate for r in rates])):
        for bar, v in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1, f"{100 * v:.0f}%",
                    ha="center", va="bottom", fontsize=8)
    labels = []
    for r in rates:
        note = f"\nn={r.n}"
        if r.excluded_injected:
            note += f" (주입 {r.excluded_injected} 제외)"
        if r.n < PLANNED_TRIALS_PER_BUTTON:
            note += "\n표본 부족"
        labels.append(r.button + note)
    ax.set_xticks(list(xs), labels, fontsize=9)
    ax.set_ylim(0, 112)
    ax.set_ylabel("성공률 (%, 사람 판정)")
    ax.set_title("버튼별 누름 성공률")
    ax.legend(fontsize=8, loc="lower right")
    ax.grid(axis="y", alpha=0.3)
    ax.text(0.01, 0.98, f"합격선: 실측 후 정함 · 계획 표본 버튼당 {PLANNED_TRIALS_PER_BUTTON}회 이상",
            transform=ax.transAxes, fontsize=8, va="top", color="#555")
    finish_figure(fig, kind)
    return fig


def _main(argv: Sequence[str] | None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv")
    add_kind_args(parser)
    args = parser.parse_args(argv)
    rates, kind = load(args.csv, args.data_kind)
    print(save(render(rates, kind), args.out))


def main(argv: Sequence[str] | None = None) -> int:
    return run_cli(_main, argv)


if __name__ == "__main__":
    raise SystemExit(main())
