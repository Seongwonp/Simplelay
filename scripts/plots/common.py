"""그래프 4종이 함께 쓰는 입력 검사·데이터 종류 판정·워터마크.

데이터 종류(실측/합성)는 **추측하지 않는다.** 다음 둘 중 하나로만 정한다.
  - 표 CSV: ``data_kind`` 열(모든 행이 같은 값) 또는 명령줄 ``--data-kind``. 둘 다 있으면 같아야 한다.
  - 원시 기록기 출력: 쓰는 행의 ``source`` 칸. ``mock_*``이면 합성, 접두 없는 이름이면 실측이다
    (`rpi/verifier/recorder.py`가 합성 입력을 ``mock_*``로 적는 규칙). 섞여 있으면 거절한다.
어느 쪽으로도 정해지지 않으면 그리지 않는다.

합성 데이터로 만든 그림에는 "예시(합성 데이터)" 워터마크를 반드시 넣는다. 실측 그림에는 넣지 않는다.
"""

from __future__ import annotations

import csv
import json
import math
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Any

MEASURED = "measured"
SYNTHETIC = "synthetic"
DATA_KINDS = (MEASURED, SYNTHETIC)

WATERMARK_TEXT = "예시(합성 데이터)"
WATERMARK_GID = "simplelay-synthetic-watermark"

#: 한글 글꼴 후보(있는 것부터). 없으면 matplotlib 기본 글꼴로 그리며 한글이 네모로 보일 수 있다.
KOREAN_FONTS = ["Malgun Gothic", "NanumGothic", "Noto Sans CJK KR", "AppleGothic", "DejaVu Sans"]


class DataError(ValueError):
    """입력이 비었거나 빠졌거나 모순일 때. 그림을 만들지 않는다."""


# 데이터 종류


def check_kind_flag(flag: str | None) -> str | None:
    if flag is None:
        return None
    if flag not in DATA_KINDS:
        raise DataError(f"--data-kind는 {'/'.join(DATA_KINDS)} 중 하나여야 합니다: {flag!r}")
    return flag


def resolve_kind(from_input: str | None, flag: str | None, where: str) -> str:
    """입력 메타데이터와 명령줄 표시를 맞춰 하나로 정한다. 정해지지 않거나 어긋나면 거절."""
    flag = check_kind_flag(flag)
    if from_input is None and flag is None:
        raise DataError(
            f"{where}: 실측인지 합성인지 알 수 없습니다 — data_kind 열을 넣거나 "
            f"--data-kind {MEASURED}|{SYNTHETIC}를 주세요(추측하지 않습니다)"
        )
    if from_input is not None and flag is not None and from_input != flag:
        raise DataError(f"{where}: 입력은 {from_input}인데 --data-kind는 {flag}입니다")
    return from_input if from_input is not None else flag  # type: ignore[return-value]


# 표 CSV


def _require_file(path: Path) -> None:
    if not path.exists():
        raise DataError(f"입력 파일이 없습니다: {path}")
    if not path.is_file():
        raise DataError(f"파일이 아닙니다: {path}")
    if path.stat().st_size == 0:
        raise DataError(f"입력 파일이 비었습니다: {path}")


def read_table(
    path: str | Path,
    required: Sequence[str],
    *,
    optional: Sequence[str] = (),
    flag: str | None = None,
) -> tuple[list[dict[str, str]], str]:
    """머리행 있는 UTF-8 CSV를 읽는다. 필수 열의 빈 칸은 행 번호와 함께 거절한다."""
    path = Path(path)
    _require_file(path)
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        header = [h.strip() for h in (reader.fieldnames or [])]
        if not header:
            raise DataError(f"{path.name}: 머리행이 없습니다")
        missing = [c for c in required if c not in header]
        if missing:
            raise DataError(f"{path.name}: 필수 열이 없습니다: {', '.join(missing)}")
        rows: list[dict[str, str]] = []
        for line_no, raw in enumerate(reader, start=2):
            row = {(k or "").strip(): (v or "").strip() for k, v in raw.items() if k is not None}
            if not any(row.values()):
                continue  # 완전히 빈 줄은 기록이 아니다
            blank = [c for c in required if not row.get(c)]
            if blank:
                raise DataError(f"{path.name} {line_no}행: 빈 칸 {', '.join(blank)} (빈칸은 '모름' — 그리지 않습니다)")
            rows.append({c: row.get(c, "") for c in (*required, *optional, "data_kind") if c in row})
    if not rows:
        raise DataError(f"{path.name}: 데이터 행이 없습니다")
    kinds = {r.get("data_kind", "") for r in rows} if "data_kind" in header else set()
    from_input: str | None = None
    if kinds:
        if "" in kinds:
            raise DataError(f"{path.name}: data_kind 열에 빈 칸이 있습니다")
        if len(kinds) > 1:
            raise DataError(f"{path.name}: 실측과 합성이 섞여 있습니다({sorted(kinds)}) — 파일을 나누세요")
        (from_input,) = kinds
        if from_input not in DATA_KINDS:
            raise DataError(f"{path.name}: data_kind 값이 {'/'.join(DATA_KINDS)}가 아닙니다: {from_input!r}")
    return rows, resolve_kind(from_input, flag, path.name)


def to_float(row: dict[str, str], column: str, where: str) -> float:
    try:
        value = float(row[column])
    except (KeyError, ValueError):
        raise DataError(f"{where}: {column} 값이 숫자가 아닙니다: {row.get(column)!r}") from None
    if not math.isfinite(value):
        raise DataError(f"{where}: {column} 값이 유한한 수가 아닙니다: {row.get(column)!r}")
    return value


def to_flag01(row: dict[str, str], column: str, where: str) -> int:
    value = row.get(column, "")
    if value not in ("0", "1"):
        raise DataError(f"{where}: {column}는 0 또는 1이어야 합니다(사람 판정): {value!r}")
    return int(value)


# 원시 기록기 출력(rpi/verifier/recorder.py)


def read_recorder(path: str | Path) -> list[dict[str, Any]]:
    """recorder의 CSV(.csv) 또는 JSONL(.jsonl)을 dict 행으로 읽는다. 빈 칸은 키를 뺀다."""
    path = Path(path)
    _require_file(path)
    rows: list[dict[str, Any]] = []
    if path.suffix.lower() == ".jsonl":
        with path.open(encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise DataError(f"{path.name} {line_no}행: JSON이 아닙니다 ({exc.msg})") from None
                if not isinstance(item, dict):
                    raise DataError(f"{path.name} {line_no}행: 객체가 아닙니다")
                rows.append(item)
    else:
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames or "t_monotonic_ns" not in reader.fieldnames or "source" not in reader.fieldnames:
                raise DataError(f"{path.name}: 기록기 CSV 머리행(t_monotonic_ns·source)이 없습니다")
            for raw in reader:
                rows.append({k: v for k, v in raw.items() if k is not None and v not in ("", None)})
    if not rows:
        raise DataError(f"{path.name}: 기록 행이 없습니다")
    for i, row in enumerate(rows, start=1):
        if "t_monotonic_ns" not in row or "source" not in row:
            raise DataError(f"{path.name} {i}번째 기록: t_monotonic_ns 또는 source가 없습니다")
        try:
            row["t_monotonic_ns"] = int(row["t_monotonic_ns"])
        except (TypeError, ValueError):
            raise DataError(f"{path.name} {i}번째 기록: t_monotonic_ns가 정수가 아닙니다") from None
    return rows


def kind_from_sources(sources: Iterable[str], where: str) -> str:
    """``mock_*``만 있으면 합성, 접두 없는 것만 있으면 실측. 섞이면 거절."""
    seen = set(sources)
    if not seen:
        raise DataError(f"{where}: 판정할 source가 없습니다")
    mock = {s for s in seen if s.startswith("mock_")}
    if mock and mock != seen:
        raise DataError(f"{where}: 실측과 합성 source가 섞여 있습니다({sorted(seen)}) — 그리지 않습니다")
    return SYNTHETIC if mock else MEASURED


# 그림


def pyplot():
    """Agg 백엔드로 pyplot을 가져온다. matplotlib이 없으면 설치 안내와 함께 실패."""
    try:
        import matplotlib
    except ImportError as exc:  # pragma: no cover - 환경 의존
        raise SystemExit(
            'matplotlib이 없습니다: .venv/Scripts/python.exe -m pip install -e ".[test]"'
        ) from exc
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    from matplotlib import font_manager

    installed = {f.name for f in font_manager.fontManager.ttflist}
    plt.rcParams["font.family"] = [f for f in KOREAN_FONTS if f in installed] or ["DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    return plt


def finish_figure(fig, kind: str) -> None:
    """합성이면 워터마크를 넣는다. 실측이면 아무것도 넣지 않는다."""
    if kind not in DATA_KINDS:
        raise DataError(f"알 수 없는 데이터 종류: {kind!r}")
    if kind == SYNTHETIC:
        fig.text(
            0.5, 0.5, WATERMARK_TEXT,
            ha="center", va="center", rotation=25, fontsize=44, color="#c0392b",
            alpha=0.28, zorder=1000, gid=WATERMARK_GID,
        )
        fig.text(
            0.99, -0.02, "합성 데이터 — 실측 아님", ha="right", va="top", fontsize=9,
            color="#c0392b", gid=WATERMARK_GID + "-footer",
        )


def has_watermark(fig) -> bool:
    return any(t.get_gid() == WATERMARK_GID and t.get_text() == WATERMARK_TEXT for t in fig.texts)


def save(fig, out: str | Path) -> Path:
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=150, bbox_inches="tight")
    return out


def add_kind_args(parser) -> None:
    parser.add_argument(
        "--data-kind", choices=DATA_KINDS, default=None,
        help="입력에 data_kind 열이 없을 때 필수. 있으면 그 값과 같아야 한다.",
    )
    parser.add_argument("--out", required=True, help="출력 PNG 경로")


def run_cli(main_fn, argv: Sequence[str] | None) -> int:
    try:
        main_fn(argv)
    except DataError as exc:
        import sys

        print(f"그리지 않음: {exc}", file=sys.stderr)
        return 2
    return 0
