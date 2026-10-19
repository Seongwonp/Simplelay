"""첫 사용 점검(2026-10-19): 본체가 폰·키오스크에 그대로 보이는 문장에 속말·겹친 조사가 있었다.

예) "보관 위치이(가) 프레임 밖이에요(331, 228mm) — 프레임 안쪽을 짚어 주세요",
    "갠트리 이동 범위(소프트 리밋)가 설정되지 않아 범위는 미확인이에요".
조사는 앞 낱말의 받침으로 고르고(rpi/josa.py), 폰 가전 추가 화면의 말(버튼판 네 귀퉁이·기다리는 자리·누름 장치)과
다음에 할 일을 쓴다. 로그 문장은 그대로 둔다 — 여기서는 화면에 가는 문장만 본다.
"""

from __future__ import annotations

import re
from types import SimpleNamespace

import pytest

from rpi.josa import josa, quoted_josa, with_josa
from rpi.services.panel_mapping import FrameConfig, MappingInput, MappingRejected, compute_mapping
from rpi.services.stop_park import validate_stop_park

#: 화면 문장에 남으면 안 되는 말 — 속말, 겹친 조사, mm 좌표 쌍.
JARGON = re.compile(r"갠트리|소프트 리밋|프레임|이\(가\)|을\(를\)|은\(는\)|과\(와\)|좌표|미확인|\(\s*-?\d+(\.\d+)?,\s*-?\d+(\.\d+)?\s*mm\)")

CORNERS = ((100.0, 100.0), (1100.0, 100.0), (1100.0, 800.0), (100.0, 800.0))


def _px(x_mm: float, y_mm: float) -> tuple[float, float]:
    """300×200 mm 버튼판이 사진 (100,100)~(1100,800)에 곧게 놓였을 때의 사진 점."""
    return (100 + x_mm / 300 * 1000, 100 + y_mm / 200 * 700)


def _mapping(**over) -> MappingInput:
    base = dict(photo_w=1200, photo_h=900, corners_px=CORNERS, frame=FrameConfig(300.0, 200.0, 0.0, 0.0, "request"))
    base.update(over)
    return MappingInput(**base)


# ── 조사 고르기 ────────────────────────────────────────────────────────────


@pytest.mark.parametrize("word, expected", [
    ("기다리는 자리", "가"), ("보관 위치", "가"), ("정지 버튼", "이"), ("버튼 '즉석밥'", "이"),
    ("버튼 '취소'", "가"), ("공기청정기(모의)", "가"), ("전자레인지 2", "가"), ("버튼 1", "이"), ("A-3", "이"),
])
def test_subject_particle_follows_the_last_syllable(word, expected):
    assert josa(word, "이", "가") == expected


def test_object_topic_and_direction_particles():
    assert with_josa("공기청전기 켜 줘", "을", "를") == "공기청전기 켜 줘를"
    assert quoted_josa("즉석밥 데워", "을", "를") == "'즉석밥 데워'를"
    assert with_josa("시각", "은", "는") == "시각은"
    assert with_josa("이름", "은", "는") == "이름은"
    assert with_josa("왼쪽 위", "과", "와") == "왼쪽 위와"
    # ㄹ 받침 뒤에는 '으로'가 아니라 '로'
    assert with_josa("자동 모드 물", "으로", "로") == "자동 모드 물로"
    assert with_josa("강풍", "으로", "로") == "강풍으로"


# ── 가전 추가(사진 매핑) ─────────────────────────────────────────────────────


def test_park_outside_the_button_panel_reads_plainly():
    with pytest.raises(MappingRejected) as info:
        compute_mapping(_mapping(park_px=_px(320, 215)))
    text = str(info.value)
    assert text.startswith("기다리는 자리가 버튼판 네 귀퉁이 밖에 있어요")
    assert "다시 골라 주세요" in text
    assert not JARGON.search(text), text


def test_button_outside_uses_the_button_name_not_its_id():
    with pytest.raises(MappingRejected) as info:
        compute_mapping(_mapping(buttons_px={"BT-05": _px(320, 100)}, button_labels={"BT-05": "즉석밥"}))
    text = str(info.value)
    assert text.startswith("버튼 '즉석밥'이 버튼판 네 귀퉁이 밖에 있어요") and "BT-05" not in text
    assert not JARGON.search(text), text


@pytest.mark.parametrize("over", [
    {"corners_px": CORNERS[:3]},
    {"corners_px": (CORNERS[0], CORNERS[1], CORNERS[3], CORNERS[2])},
    {"corners_px": ((100.0, 100.0), (130.0, 100.0), (130.0, 120.0), (100.0, 120.0))},
    {"corners_px": ((100.0, 100.0), (1100.0, 100.0), (1100.0, 150.0), (100.0, 150.0))},
    {"frame": FrameConfig(None, None)},
    {"frame": FrameConfig(0.0, 0.0)},
])
def test_mapping_rejections_have_no_jargon(over):
    with pytest.raises(MappingRejected) as info:
        compute_mapping(_mapping(**over))
    text = str(info.value)
    assert not JARGON.search(text), text
    assert "SIMPLELAY_" not in text and "frame_w_mm" not in text
    assert "주세요" in text  # 다음에 할 일


# ── 정지 버튼·기다리는 자리 검증(폰에 notes·거절 문장이 그대로 보인다) ──────────────


def _appliance(**over):
    button = SimpleNamespace(id="A", label="시작", kind=None, calibrated=True, x_mm=50.0, y_mm=50.0)
    from rpi.services.appliance_registry import ButtonKind

    button.kind = ButtonKind.BUTTON
    base = dict(stop_presses=1, stop_button="A", park_xy=(200.0, 150.0), buttons=(button,))
    base.update(over)
    return SimpleNamespace(**base)


def test_unset_motion_range_note_is_plain():
    check = validate_stop_park(_appliance(), env={})
    assert check.status == "unverified"
    assert check.notes, check
    for note in check.notes:
        assert not JARGON.search(note), note
    assert any("누름 장치" in n and "자리 확인" in n for n in check.notes)


def test_missing_park_note_names_the_next_step():
    check = validate_stop_park(_appliance(park_xy=None), env={})
    assert any(n.startswith("기다리는 자리를 고르지 않아") and "골라 주세요" in n for n in check.notes), check.notes
    for note in check.notes:
        assert not JARGON.search(note), note


@pytest.mark.parametrize("over, env", [
    ({"park_xy": (51.0, 51.0)}, {}),
    ({"park_xy": (700.0, 5.0)}, {}),
    ({"park_xy": (50.0, 50.0)}, {}),
    ({}, {"SIMPLELAY_MOTION_X_MIN_MM": "0", "SIMPLELAY_MOTION_X_MAX_MM": "100",
          "SIMPLELAY_MOTION_Y_MIN_MM": "0", "SIMPLELAY_MOTION_Y_MAX_MM": "100"}),
    ({"stop_button": "Z"}, {}),
])
def test_stop_park_rejections_have_no_jargon(over, env):
    with pytest.raises(ValueError) as info:
        validate_stop_park(_appliance(**over), env=env)
    text = str(info.value)
    assert not JARGON.search(text), text
    assert not re.search(r"\d+(\.\d+)?mm", text), text
    assert "주세요" in text


def test_park_out_of_range_message_reads_correctly():
    env = {"SIMPLELAY_MOTION_X_MIN_MM": "0", "SIMPLELAY_MOTION_X_MAX_MM": "100",
           "SIMPLELAY_MOTION_Y_MIN_MM": "0", "SIMPLELAY_MOTION_Y_MAX_MM": "100"}
    with pytest.raises(ValueError) as info:
        validate_stop_park(_appliance(), env=env)
    assert str(info.value).startswith("기다리는 자리가 누름 장치의 이동 범위 밖이에요")


# ── 그 밖에 화면에 가는 문장 ──────────────────────────────────────────────────


def test_not_understood_and_routine_validation_choose_particles():
    from rpi.intent.rules import not_understood_message
    from rpi.routines.model import RoutineValidationError, _text, parse_hhmm

    assert not_understood_message(" 공기청전기 켜 줘 ") == "'공기청전기 켜 줘'를 알아듣지 못했어요"
    assert not_understood_message("즉석밥 데워 줄래요 지금") == "'즉석밥 데워 줄래요 지금'을 알아듣지 못했어요"
    with pytest.raises(RoutineValidationError, match="^이름을 적어 주세요$"):
        _text("", "이름", 10)
    with pytest.raises(RoutineValidationError, match="^루틴 이름은 3자 이내로"):
        _text("아침 루틴", "루틴 이름", 3)
    with pytest.raises(RoutineValidationError, match="^시각은 07:30처럼"):
        parse_hhmm("7시")
    with pytest.raises(RoutineValidationError, match="^메모는 글자여야"):
        _text(3, "메모", 10)


def test_verify_pass_and_panel_scan_sentences_have_no_jargon():
    from rpi.api.mapping_router import VERIFY_NOT_LOCAL_DETAIL
    from rpi.api.router import PANEL_SCAN_NO_POSITION_NOTE
    from rpi.services.panel_mapping import verify_targets
    from rpi.services.stop_park import UNCHECKED_RANGE_NOTE

    for text in (VERIFY_NOT_LOCAL_DETAIL, PANEL_SCAN_NO_POSITION_NOTE, UNCHECKED_RANGE_NOTE):
        assert not JARGON.search(text), text
        assert "(mm)" not in text
    assert "누름 장치" in VERIFY_NOT_LOCAL_DETAIL
    steps = verify_targets(_appliance())
    assert [s["button"] for s in steps] == ["시작", "기다리는 자리"]
