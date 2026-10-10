"""그래프 4 — CT 전력 파형 위에 "시작 확인"(L3) 판정 시점을 표시(전자레인지 1회 사이클).

입력: 원시 기록기(`rpi/verifier/recorder.py`) 출력 CSV 또는 JSONL 한 파일.
  - 파형: ``power_watts`` 값이 있는 행(source ``power`` 또는 ``mock_power``)
  - 누름 구간: ``event=press_start``/``press_end`` 행(있으면 음영)
  - 판정 시점: ``--decision-event`` 이름의 이벤트 행 **정확히 하나**, 또는 ``--decision-t-ns``
    (같은 단조 시각축의 ns). 지금 기록기는 L3 판정 이벤트를 스스로 찍지 않는다 —
    판정 시각은 실행 이력에서 옮겨 ``--decision-t-ns``로 주거나, 기록 중 marker로 찍는다.
데이터 종류는 파형 행의 source로 정한다(``mock_*`` = 합성). ``--data-kind``는 확인용이다.

    python -m scripts.plots.power_decision rec.csv --decision-t-ns 123 --out power.png
"""

from __future__ import annotations

import argparse
import math
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .common import (
    DataError,
    add_kind_args,
    finish_figure,
    kind_from_sources,
    pyplot,
    read_recorder,
    resolve_kind,
    run_cli,
    save,
)

DEFAULT_DECISION_EVENT = "l3_start_confirmed"
POWER_SOURCES = ("power", "mock_power")


@dataclass(frozen=True)
class PowerTrace:
    t_ns: list[int]
    watts: list[float]
    presses: list[tuple[int, int]]  # (press_start, press_end) ns
    decision_ns: int


def load(
    path: str | Path,
    flag: str | None = None,
    *,
    decision_event: str = DEFAULT_DECISION_EVENT,
    decision_t_ns: int | None = None,
) -> tuple[PowerTrace, str]:
    name = Path(path).name
    rows = read_recorder(path)
    power_rows = [r for r in rows if r["source"] in POWER_SOURCES and r.get("event") is None]
    if not power_rows:
        raise DataError(f"{name}: 전력 파형 행(source power·mock_power)이 없습니다")
    t_ns: list[int] = []
    watts: list[float] = []
    for r in sorted(power_rows, key=lambda r: r["t_monotonic_ns"]):
        try:
            w = float(r["power_watts"])
        except (KeyError, TypeError, ValueError):
            raise DataError(f"{name}: t={r['t_monotonic_ns']} 전력 행에 power_watts 값이 없습니다") from None
        if not math.isfinite(w):
            raise DataError(f"{name}: t={r['t_monotonic_ns']} power_watts가 유한한 수가 아닙니다")
        t_ns.append(r["t_monotonic_ns"])
        watts.append(w)
    if len(t_ns) < 2:
        raise DataError(f"{name}: 전력 표본이 2개 미만이라 파형이 아닙니다")
    kind = resolve_kind(kind_from_sources((r["source"] for r in power_rows), name), flag, name)

    events = sorted((r for r in rows if r.get("event")), key=lambda r: r["t_monotonic_ns"])
    presses: list[tuple[int, int]] = []
    open_at: int | None = None
    for e in events:
        if e["event"] == "press_start" and open_at is None:
            open_at = e["t_monotonic_ns"]
        elif e["event"] == "press_end" and open_at is not None:
            presses.append((open_at, e["t_monotonic_ns"]))
            open_at = None

    if decision_t_ns is None:
        hits = [e["t_monotonic_ns"] for e in events if e["event"] == decision_event]
        if not hits:
            raise DataError(
                f"{name}: 판정 이벤트 {decision_event!r}가 없습니다 — --decision-t-ns로 판정 시각을 주세요"
            )
        if len(hits) > 1:
            raise DataError(f"{name}: 판정 이벤트 {decision_event!r}가 {len(hits)}개입니다 — 1회 사이클만 잘라 주세요")
        decision_t_ns = hits[0]
    if not (t_ns[0] <= decision_t_ns <= t_ns[-1]):
        raise DataError(f"{name}: 판정 시각 {decision_t_ns}가 파형 구간 [{t_ns[0]}, {t_ns[-1]}] 밖입니다")
    return PowerTrace(t_ns, watts, presses, int(decision_t_ns)), kind


def render(trace: PowerTrace, kind: str):
    if len(trace.t_ns) < 2:
        raise DataError("전력 표본이 2개 미만입니다")
    plt = pyplot()
    t0 = trace.t_ns[0]
    sec = [(t - t0) / 1e9 for t in trace.t_ns]
    fig, ax = plt.subplots(figsize=(8.0, 4.2))
    ax.plot(sec, trace.watts, lw=1.4, color="C0", label="CT 전력 (W)")
    for i, (a, b) in enumerate(trace.presses):
        ax.axvspan((a - t0) / 1e9, (b - t0) / 1e9, color="#f39c12", alpha=0.25,
                   label="누름 구간" if i == 0 else None)
    d = (trace.decision_ns - t0) / 1e9
    ax.axvline(d, color="#c0392b", lw=1.8, ls="--", label="시작 확인 판정")
    peak = max(trace.watts)
    ax.annotate(f"시작 확인 {d:.2f} s", xy=(d, 0.55 * peak), xytext=(6, 0),
                textcoords="offset points", fontsize=9, color="#c0392b", va="center", ha="left")
    if trace.presses:
        lag = (trace.decision_ns - trace.presses[0][1]) / 1e9
        ax.text(0.01, 0.98, f"첫 누름 끝 → 판정 {lag:.2f} s", transform=ax.transAxes, fontsize=8,
                va="top", color="#555")
    ax.set_xlabel("시간 (s, 첫 전력 표본 기준)")
    ax.set_ylabel("전력 (W)")
    ax.set_title("전자레인지 1회 사이클 — CT 전력과 시작 확인 판정 시점")
    ax.set_ylim(bottom=0, top=max(peak * 1.2, 1.0))
    ax.legend(fontsize=8, loc="upper right", ncols=3)
    ax.grid(alpha=0.3)
    finish_figure(fig, kind)
    return fig


def _main(argv: Sequence[str] | None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("recording", help="recorder 출력(.csv 또는 .jsonl)")
    parser.add_argument("--decision-event", default=DEFAULT_DECISION_EVENT)
    parser.add_argument("--decision-t-ns", type=int, default=None)
    add_kind_args(parser)
    args = parser.parse_args(argv)
    trace, kind = load(args.recording, args.data_kind,
                       decision_event=args.decision_event, decision_t_ns=args.decision_t_ns)
    print(save(render(trace, kind), args.out))


def main(argv: Sequence[str] | None = None) -> int:
    return run_cli(_main, argv)


if __name__ == "__main__":
    raise SystemExit(main())
