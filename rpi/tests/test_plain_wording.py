"""쉬운 말 회귀 시험(2026-10-17, docs/UI-개편안-2026-10-17.md §2·§3).

폰·키오스크에 그대로 나가는 서버 문장에 내부 이름('허브'·'모의'·'시연'·'ThinQ'·'CT'·'L3'·'작은 팔 장치')과
문장 잇기 기호('—'·'·'·괄호)가 다시 들어오지 않게 지킨다. 클라이언트가 글자 일치로 쓰는 낱말
('조리 완료가 아닐 수 있어요'·'다시 켜져'·'이미'+'보내지 않았어요')은 남아 있는지도 본다.
"""

from __future__ import annotations

import re

import pytest

from rpi.routines import auto_rules
from rpi.scenarios.catalog import COOK_DONE_AIR, DEFAULT_SCENARIOS
from rpi.services import connections
from rpi.services.air_quality import AirReading
from rpi.services.thinq import controller as thinq_controller
from rpi.services.thinq import wording
from rpi.verifier.outlet import POWER_LOST_DETAIL
from rpi4.services import act_executor

#: 사용자 문장에 나오면 안 되는 말(쉬운 말 사전 §3). '본체'·'작은 팔'·'콘센트'·'LG 가전'·'연습'으로 바꾼다.
BANNED_WORDS = ("허브", "모의", "시연", "ThinQ", "CT", "L3", "작은 팔 장치", "가전 콘센트 장치", "SimpleLay 본체",
                "상태 재조회", "변경 명령", "콘센트 전력")
#: 문장을 잇는 기호(말투 규칙 4).
BANNED_JOINERS = ("—", "--", " · ", "(", ")")


def _connection_sentences() -> list[str]:
    items = [connections.network_item(i, n) for i in ("up", "down", "unknown") for n in ("ok", "failed", "unknown")]
    items += [connections.press_item("mock")]
    items += [connections.press_item("uart", link) for link in ("ok", "down", "no_reply", "error", "never")]
    items += [connections.plug_item(mode) for mode in ("off", "mock", "real")]
    items += [connections.plug_item("real", link) for link in ("weak", "lost")]
    out: list[str] = []
    for item in items:
        out += [item.title, item.message, *item.fixes]
    return out


def _auto_rule_constants() -> list[str]:
    names = [n for n in dir(auto_rules) if re.fullmatch(r"[A-Z_]+_(REASON|NOTICE|CAVEAT|REFUSED)", n)]
    return [getattr(auto_rules, n) for n in names if isinstance(getattr(auto_rules, n), str)]


def _air_reasons() -> list[str]:
    return [AirReading(bad=((name, 42, level),), known=1, wind=None).reason()
            for name in ("초미세먼지", "미세먼지", "종합 공기질") for level in ("BAD", "VERY_BAD")]


SENTENCES = {
    "connections": _connection_sentences,
    "auto_rules": _auto_rule_constants,
    "scenario_reasons": lambda: [d.event_reason for d in DEFAULT_SCENARIOS if d.event_reason],
    "air_quality": _air_reasons,
    "thinq_wording": lambda: [wording.already_sentence("강풍"), wording.changed_sentence("강풍"),
                              wording.target_seen_sentence("강풍"), wording.UNCONFIRMED_SENTENCE,
                              thinq_controller.REMOTE_OFF_REASON, thinq_controller.REMOTE_UNKNOWN_REASON],
    "estop": lambda: [act_executor.ESTOP_LATCHED_DETAIL, act_executor.POWER_LOST_LATCH_DETAIL, POWER_LOST_DETAIL,
                      *act_executor.ESTOP_REASON_DETAIL.values()],
}


@pytest.mark.parametrize("group", sorted(SENTENCES))
def test_user_sentences_use_plain_words(group):
    for text in SENTENCES[group]():
        for word in BANNED_WORDS:
            assert word not in text, f"{group}: '{word}' in {text!r}"
        for joiner in BANNED_JOINERS:
            assert joiner not in text, f"{group}: '{joiner}' in {text!r}"
        assert not re.search(r"\d+\s*(ms|mA|dB)|\d+초 (전|늦게)", text), f"{group}: 숫자·단위 in {text!r}"


def test_client_matched_words_stay():
    # 키오스크 kAlwaysShownCaveats — 가열 종료를 '조리 완료'로 단정하지 않는 줄을 늘 보인다.
    assert "조리 완료가 아닐 수 있어요" in COOK_DONE_AIR.event_reason
    # 키오스크 estop.dart·서버 estop_block_reason이 '다시 켜져'로 전원 꺼짐 걸림을 가른다.
    assert "다시 켜져" in act_executor.POWER_LOST_LATCH_DETAIL
    assert "다시 켜져" in POWER_LOST_DETAIL
    # 폰·키오스크 command_result.dart가 ThinQ 결과를 이 낱말로 가른다.
    already = wording.already_sentence("강풍")
    assert "이미" in already and "보내지 않았어요" in already
    assert "설정된 것을 확인" in wording.target_seen_sentence("강풍")
    assert "바꿨어요" in wording.changed_sentence("강풍")
