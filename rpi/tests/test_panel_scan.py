"""조작부 인식 응답 → 버튼맵 초안. 모델 응답은 믿지 않는 입력이라, 거절·버림 경로가 핵심이다."""

import json

import pytest

from rpi.api.schemas import ApplianceButtonModel, ApplianceRegisterRequest
from rpi.calibration import CalibrationRejected, PointPair
from rpi.vision import (
    MAX_CONTROLS,
    PanelScanError,
    build_draft,
    map_draft_to_mm,
    parse_controls,
)


def _raw(buttons, **extra):
    return json.dumps({"buttons": buttons, **extra}, ensure_ascii=False)


def _btn(label, x0, y0, x1, y1, kind="button"):
    return {"label": label, "kind": kind, "box": [x0, y0, x1, y1]}


# 전자레인지 조작부: 2행 3열, 모델 좌표에 약간의 흔들림.
MICROWAVE = [
    _btn("해동", 100, 100, 250, 180),
    _btn("시간", 400, 105, 550, 185),
    _btn("출력", 700, 98, 850, 178),
    _btn("취소", 102, 400, 252, 480),
    _btn("30초", 398, 395, 548, 475),
    _btn("시작", 703, 402, 853, 482),
]


def _draft(buttons):
    controls, dropped = parse_controls(_raw(buttons))
    return build_draft(controls, dropped)


# ── 응답 읽기 ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "wrap",
    [
        lambda body: body,
        lambda body: f"```json\n{body}\n```",
        lambda body: f"```\n{body}\n```",
        lambda body: f"다음은 결과입니다.\n{body}\n확인해 주세요.",
    ],
)
def test_json_is_found_inside_fences_and_prose(wrap) -> None:
    controls, dropped = parse_controls(wrap(_raw(MICROWAVE)))
    assert [c.label for c in controls] == [b["label"] for b in MICROWAVE]
    assert dropped == []


@pytest.mark.parametrize(
    "raw",
    ["", "버튼이 여섯 개 보입니다", "[1, 2, 3]", '{"controls": []}', '{"buttons": "시작"}'],
)
def test_unreadable_or_shapeless_response_is_rejected(raw) -> None:
    with pytest.raises(PanelScanError):
        parse_controls(raw)


def test_no_valid_control_is_rejected() -> None:
    with pytest.raises(PanelScanError, match="찾지 못했어요"):
        parse_controls(_raw([]))


def test_bad_items_are_dropped_with_reasons_not_repaired() -> None:
    items = MICROWAVE[:2] + [
        "시작",
        {"label": "문열림", "kind": "lever", "box": [0, 600, 100, 700]},
        {"label": "세 숫자", "box": [0, 600, 100]},
        {"label": "문자", "box": ["0", "600", "100", "700"]},
        {"label": "불리언", "box": [True, 600, 100, 700]},
        {"label": "무한", "box": [0, 600, float("inf"), 700]},
        {"label": "뒤집힘", "box": [300, 600, 200, 700]},
        {"label": "범위 밖", "box": [0, 600, 1200, 700]},
        {"label": "납작함", "box": [0, 600, 100, 600.5]},
    ]
    controls, dropped = parse_controls(json.dumps({"buttons": items}, allow_nan=True))

    assert [c.label for c in controls] == ["해동", "시간"]
    assert len(dropped) == 9
    assert any("알 수 없는 종류" in d for d in dropped)


def test_slight_overshoot_is_clamped_to_the_frame() -> None:
    controls, _ = parse_controls(_raw([_btn("시작", -3, 997, 100, 1004)]))
    assert controls[0].box == (0.0, 997.0, 100.0, 1000.0)


def test_same_control_seen_twice_is_dropped() -> None:
    controls, dropped = parse_controls(
        _raw([_btn("시작", 100, 100, 200, 200), _btn("Start", 105, 102, 205, 198)])
    )
    assert [c.label for c in controls] == ["시작"]
    assert "같은 자리" in dropped[0]


def test_too_many_controls_is_rejected() -> None:
    many = [_btn(f"b{i}", i * 19, 0, i * 19 + 10, 10) for i in range(MAX_CONTROLS + 1)]
    with pytest.raises(PanelScanError, match="최대"):
        parse_controls(_raw(many))


def test_labels_are_trimmed_and_capped() -> None:
    controls, _ = parse_controls(_raw([_btn("  시간\n  설정  " + "가" * 60, 0, 0, 10, 10)]))
    assert controls[0].label.startswith("시간 설정 ")
    assert len(controls[0].label) == 40


# ── 격자 초안 ────────────────────────────────────────────────────────────────


def test_jittered_panel_becomes_a_row_major_grid() -> None:
    draft = _draft(MICROWAVE)

    assert (draft.rows, draft.cols) == (2, 3)
    assert [(b.id, b.label, b.x, b.y) for b in draft.buttons] == [
        ("B-01", "해동", 0, 0),
        ("B-02", "시간", 1, 0),
        ("B-03", "출력", 2, 0),
        ("B-04", "취소", 0, 1),
        ("B-05", "30초", 1, 1),
        ("B-06", "시작", 2, 1),
    ]


def test_draft_passes_the_registration_rules() -> None:
    draft = _draft(MICROWAVE + [_btn("", 400, 700, 550, 780), _btn("시작", 700, 700, 850, 780)])

    request = ApplianceRegisterRequest(
        name="전자레인지",
        rows=draft.rows,
        cols=draft.cols,
        buttons=[ApplianceButtonModel(id=b.id, label=b.label, x=b.x, y=b.y) for b in draft.buttons],
    )
    request.validate_layout()


def test_blank_and_duplicate_labels_get_unique_names_and_are_flagged() -> None:
    draft = _draft([_btn("", 0, 0, 100, 100), _btn("시작", 300, 0, 400, 100), _btn("시작", 600, 0, 700, 100)])

    assert [b.label for b in draft.buttons] == ["버튼 1", "시작", "시작 (2)"]
    assert [b.label_from_model for b in draft.buttons] == [False, True, True]


def test_two_controls_in_one_cell_keep_the_first_and_explain() -> None:
    # 겹침(IoU)은 기준 미만이지만 행·열 모두 같은 줄로 묶이는 배치
    draft = _draft([_btn("위", 100, 100, 200, 200), _btn("아래", 100, 140, 200, 240)])

    assert [b.label for b in draft.buttons] == ["위"]
    assert any("같은 칸" in note for note in draft.dropped)


def test_more_than_eight_columns_is_rejected() -> None:
    row = [_btn(f"k{i}", i * 110, 0, i * 110 + 60, 60) for i in range(9)]
    with pytest.raises(PanelScanError, match="8x8"):
        _draft(row)


def test_dial_kind_is_kept() -> None:
    draft = _draft([_btn("출력", 100, 100, 300, 300, kind="dial"), _btn("시작", 500, 150, 600, 250)])
    assert [b.kind for b in draft.buttons] == ["dial", "button"]


# ── 기준점이 있으면 mm ───────────────────────────────────────────────────────


def _pair(sx, sy):
    # 알려진 변환: x_mm = 0.2·sx + 30, y_mm = 0.15·sy + 40
    return PointPair((sx, sy), (0.2 * sx + 30, 0.15 * sy + 40))


CORNERS = [_pair(0, 0), _pair(1000, 0), _pair(0, 1000), _pair(1000, 1000)]


def test_reference_points_map_centers_to_mm() -> None:
    draft = _draft(MICROWAVE)

    result, mapped = map_draft_to_mm(draft, CORNERS)

    start = next(b for b in draft.buttons if b.label == "시작")
    x, y = mapped[start.id]
    assert x == pytest.approx(0.2 * start.center[0] + 30)
    assert y == pytest.approx(0.15 * start.center[1] + 40)
    assert result.redundant_points == 1


def test_mm_outside_the_frame_is_rejected() -> None:
    draft = _draft(MICROWAVE)
    far = [PointPair(p.source, (p.target[0] * 20, p.target[1] * 20)) for p in CORNERS]

    with pytest.raises(PanelScanError, match="프레임"):
        map_draft_to_mm(draft, far)


def test_collinear_reference_points_are_rejected_by_calibration() -> None:
    draft = _draft(MICROWAVE)
    with pytest.raises(CalibrationRejected):
        map_draft_to_mm(draft, [_pair(0, 0), _pair(500, 500), _pair(1000, 1000)])
