"""음성 인식 띄어쓰기('공기 청정기 켜 줘')도 등록된 목적 문장과 맞는다 — 10/19 실기기에서 422로 거절됐다."""

from rpi.services.thinq.bindings import _purpose_key


def test_spacing_and_trailing_punctuation_are_ignored():
    assert _purpose_key("공기 청정기 켜 줘") == _purpose_key("공기청정기 켜줘")
    assert _purpose_key("공기청정기 켜줘.") == _purpose_key("공기청정기 켜줘")


def test_other_differences_still_do_not_match():
    assert _purpose_key("공기청정기 꺼줘") != _purpose_key("공기청정기 켜줘")
    assert _purpose_key("공기청정기 켜지 마") != _purpose_key("공기청정기 켜줘")


def test_polite_endings_now_match_too():
    # 10/19 말 다듬기(rpi/intent/normalize.py): '켜줘요'·'켜 주세요'도 같은 키 — 예전에는 다른 키라 거절됐다.
    assert _purpose_key("공기청정기 켜줘요") == _purpose_key("공기청정기 켜줘")
    assert _purpose_key("공기청정기 켜 주세요") == _purpose_key("공기청정기 켜줘")
