"""인식 응답 → 버튼맵 초안. 네트워크를 모르는 순수 로직이다(호출은 client.py).

모델 응답은 **믿지 않는 입력**이다. 형식이 틀린 항목은 조용히 고치지 않고 버리며,
버린 이유를 사람이 볼 수 있게 남긴다 — 초안은 사람이 확인한 뒤에야 저장된다.

좌표계: 모델이 주는 ``box``는 이미지 폭·높이 기준 0~1000 정규화 값
``[x_min, y_min, x_max, y_max]``다. 최솟값이 최댓값보다 크면 뒤집어 맞추지 않고
버린다 — 축 순서를 다르게 준 응답(예: y가 먼저)을 추측으로 고치면 버튼 위치가
통째로 틀린다. 실제 서비스의 축 순서는 확인 스크립트로 검증한다.

격자: 버튼 중심을 행·열로 묶어 편집기 격자(최대 8x8) 칸 번호를 만든다. 이 칸은
화면 배치용이다. 누를 mm 좌표는 기준점이 있을 때만 ``map_draft_to_mm``이 채운다.
"""

from __future__ import annotations

import json
import math
import re
import statistics
from collections.abc import Sequence
from dataclasses import dataclass

from rpi.calibration import CalibrationResult, PointPair, calibrate, map_button_centers

#: box 정규화 기준(0~1000)
BOX_SCALE = 1000.0
#: 편집기 격자 한 변 상한 — 등록 API와 같다
MAX_GRID = 8
#: 가전당 버튼 상한 — 등록 API(MAX_KNOWN_BUTTONS)와 같다
MAX_CONTROLS = 50
#: 라벨 길이 상한 — 등록 API(MAX_BUTTON_LABEL_LEN)와 같다
MAX_LABEL_LEN = 40
#: 이 이상 겹치면 같은 버튼을 두 번 본 것으로 본다
_OVERLAP_IOU = 0.5
#: 범위를 살짝 넘는 값(반올림)은 허용하고 경계로 자른다
_BOX_TOLERANCE = 5.0
#: 행·열을 나누는 간격 — 버튼 크기 중앙값의 이 비율보다 벌어지면 다른 줄
_GROUP_GAP_RATIO = 0.5

_FENCE = re.compile(r"^```[\w-]*\s*\n?(?P<body>.*?)\n?```\s*$", re.S)
_KINDS = ("button", "dial")


class PanelScanError(ValueError):
    """이 응답으로는 초안을 만들 수 없다. 메시지는 사용자에게 그대로 보여줄 문장이다."""


@dataclass(frozen=True)
class DetectedControl:
    """모델이 찾은 조작부 하나(검증 통과)."""

    label: str
    kind: str
    #: (x_min, y_min, x_max, y_max), 0~1000
    box: tuple[float, float, float, float]

    @property
    def center(self) -> tuple[float, float]:
        x0, y0, x1, y1 = self.box
        return ((x0 + x1) / 2.0, (y0 + y1) / 2.0)

    @property
    def width(self) -> float:
        return self.box[2] - self.box[0]

    @property
    def height(self) -> float:
        return self.box[3] - self.box[1]


@dataclass(frozen=True)
class DraftButton:
    id: str
    label: str
    #: 편집기 격자 칸(열, 행)
    x: int
    y: int
    kind: str
    box: tuple[float, float, float, float]
    center: tuple[float, float]
    #: False면 모델이 라벨을 읽지 못해 임시 이름을 붙였다 — 사람이 확인해야 한다
    label_from_model: bool


@dataclass(frozen=True)
class PanelDraft:
    rows: int
    cols: int
    buttons: tuple[DraftButton, ...]
    #: 버린 항목과 이유(사람이 읽을 문장)
    dropped: tuple[str, ...]


def extract_json(raw: str) -> object:
    """코드 블록·앞뒤 설명 문장이 붙어 와도 JSON 본문만 꺼낸다. 못 꺼내면 거절."""
    text = str(raw).strip()
    fenced = _FENCE.match(text)
    if fenced:
        text = fenced.group("body").strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if 0 <= start < end:
            try:
                return json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                pass
    raise PanelScanError("인식 결과를 읽을 수 없어요 — 다시 촬영해 주세요")


def parse_controls(raw: str) -> tuple[list[DetectedControl], list[str]]:
    """응답 문자열 → 검증된 조작부 목록과 버린 이유."""
    payload = extract_json(raw)
    items = payload.get("buttons") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        raise PanelScanError("인식 결과에 버튼 목록이 없어요 — 다시 촬영해 주세요")

    controls: list[DetectedControl] = []
    dropped: list[str] = []
    for index, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            dropped.append(f"{index}번 항목: 형식이 올바르지 않아 뺐어요")
            continue
        kind = str(item.get("kind") or "button").strip().lower()
        if kind not in _KINDS:
            # 누르기와 돌리기는 다른 물리 동작이다 -- 모르는 종류를 추측하지 않는다
            dropped.append(f"{index}번 항목: 알 수 없는 종류('{kind}')라 뺐어요")
            continue
        box = _parse_box(item.get("box"))
        if box is None:
            dropped.append(f"{index}번 항목: 위치 좌표가 올바르지 않아 뺐어요")
            continue
        label = _clean_label(item.get("label"))
        twin = next((c for c in controls if _iou(c.box, box) > _OVERLAP_IOU), None)
        if twin is not None:
            dropped.append(
                f"{index}번 항목: '{twin.label or '이름 없는 버튼'}'과 같은 자리라 뺐어요"
            )
            continue
        controls.append(DetectedControl(label=label, kind=kind, box=box))

    if not controls:
        raise PanelScanError("사진에서 버튼을 찾지 못했어요 — 조작부가 화면을 채우게 다시 찍어 주세요")
    if len(controls) > MAX_CONTROLS:
        raise PanelScanError(
            f"버튼이 {len(controls)}개로 인식되었어요(최대 {MAX_CONTROLS}개) "
            "— 조작부만 보이게 다시 찍어 주세요"
        )
    return controls, dropped


def build_draft(
    controls: Sequence[DetectedControl], dropped: Sequence[str] = ()
) -> PanelDraft:
    """조작부 목록 → 격자 칸·고유 라벨·id가 붙은 초안. 등록 API 규칙을 통과하는 모양으로."""
    if not controls:
        raise PanelScanError("사진에서 버튼을 찾지 못했어요 — 조작부가 화면을 채우게 다시 찍어 주세요")
    rows_of = _group([c.center[1] for c in controls], [c.height for c in controls])
    cols_of = _group([c.center[0] for c in controls], [c.width for c in controls])
    n_rows, n_cols = max(rows_of) + 1, max(cols_of) + 1
    if n_rows > MAX_GRID or n_cols > MAX_GRID:
        raise PanelScanError(
            f"버튼 배치가 {n_rows}x{n_cols}칸으로 나와 편집기 격자(최대 {MAX_GRID}x{MAX_GRID})에 "
            "담을 수 없어요 — 편집기에서 직접 배치해 주세요"
        )

    notes = list(dropped)
    order = sorted(
        range(len(controls)),
        key=lambda i: (rows_of[i], cols_of[i], controls[i].center[0]),
    )
    taken: set[tuple[int, int]] = set()
    used_labels: set[str] = set()
    buttons: list[DraftButton] = []
    for i in order:
        control = controls[i]
        cell = (cols_of[i], rows_of[i])
        if cell in taken:
            notes.append(
                f"'{control.label or '이름 없는 버튼'}': 다른 버튼과 같은 칸이라 뺐어요 "
                "— 편집기에서 추가해 주세요"
            )
            continue
        taken.add(cell)
        number = len(buttons) + 1
        from_model = bool(control.label)
        label = _unique_label(control.label or f"버튼 {number}", used_labels)
        used_labels.add(label)
        buttons.append(
            DraftButton(
                id=f"B-{number:02d}",
                label=label,
                x=cell[0],
                y=cell[1],
                kind=control.kind,
                box=control.box,
                center=control.center,
                label_from_model=from_model,
            )
        )

    # 칸을 비운 줄·열이 생겼으면(같은 칸 충돌로 뺀 경우) 격자를 줄이지 않는다 --
    # 사람이 그 칸에 버튼을 다시 넣을 자리다.
    return PanelDraft(rows=n_rows, cols=n_cols, buttons=tuple(buttons), dropped=tuple(notes))


def map_draft_to_mm(
    draft: PanelDraft,
    points: Sequence[PointPair],
    *,
    kind: str = "affine",
    mm_range: tuple[float, float] = (0.0, 600.0),
) -> tuple[CalibrationResult, dict[str, tuple[float, float]]]:
    """기준점(사진 0~1000 좌표 ↔ 갠트리 mm)으로 초안 버튼 중심을 mm로 옮긴다.

    보정 검증(`calibrate`)의 거절은 그대로 올린다. 프레임 밖으로 옮겨진 버튼이
    하나라도 있으면 전부 거절한다 -- 일부만 채우면 빠진 버튼이 옛 좌표로 눌릴 수 있다.
    """
    result = calibrate(points, kind=kind)
    mapped = map_button_centers(result, {b.id: b.center for b in draft.buttons})
    lo, hi = mm_range
    outside = [
        next(b.label for b in draft.buttons if b.id == bid)
        for bid, (x, y) in mapped.items()
        if not (lo <= x <= hi and lo <= y <= hi)
    ]
    if outside:
        raise PanelScanError(
            f"변환된 좌표가 프레임({lo:g}~{hi:g}mm) 밖입니다: {', '.join(outside)} "
            "— 기준점을 다시 확인해 주세요"
        )
    return result, mapped


# 내부 도우미


def _parse_box(value: object) -> tuple[float, float, float, float] | None:
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        return None
    nums: list[float] = []
    for v in value:
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        f = float(v)
        if not math.isfinite(f) or not -_BOX_TOLERANCE <= f <= BOX_SCALE + _BOX_TOLERANCE:
            return None
        nums.append(min(max(f, 0.0), BOX_SCALE))
    x0, y0, x1, y1 = nums
    if x1 - x0 < 1.0 or y1 - y0 < 1.0:
        return None
    return (x0, y0, x1, y1)


def _clean_label(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return " ".join(value.split())[:MAX_LABEL_LEN]


def _iou(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def _group(values: Sequence[float], sizes: Sequence[float]) -> list[int]:
    """1차원 값을 간격으로 묶어 원래 순서대로 그룹 번호(0부터)를 돌려준다."""
    gap = max(statistics.median(sizes) * _GROUP_GAP_RATIO, 1.0)
    order = sorted(range(len(values)), key=lambda i: values[i])
    groups = [0] * len(values)
    current = 0
    for prev, cur in zip(order, order[1:]):
        if values[cur] - values[prev] > gap:
            current += 1
        groups[cur] = current
    return groups


def _unique_label(base: str, used: set[str]) -> str:
    if base not in used:
        return base
    n = 2
    while True:
        suffix = f" ({n})"
        candidate = base[: MAX_LABEL_LEN - len(suffix)] + suffix
        if candidate not in used:
            return candidate
        n += 1
