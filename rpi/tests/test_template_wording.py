"""추천 루틴 템플릿의 안내 문장 — 화면에 없는 조작을 시키지 않는다(UI 평가 2026-10-17).

'확인을 눌러 주세요'라고 했지만 키오스크 안내 카드에는 누를 확인 버튼이 없었다(돌봄 시나리오의 신뢰를 깎음).
"""
from rpi.routines.templates import TEMPLATES


def _announces():
    for template in TEMPLATES:
        for step in template.get("steps", ()):
            if step.get("kind") == "announce":
                yield step["text"]


def test_announcements_do_not_ask_to_press_a_button_that_does_not_exist():
    texts = list(_announces())
    assert texts, "안내 단계가 있는 템플릿이 있어야 한다"
    for text in texts:
        assert "눌러 주세요" not in text, text
        assert "확인을 눌러" not in text, text
