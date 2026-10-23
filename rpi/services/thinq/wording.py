"""ThinQ 결과 문장(2026-10-14 보드 날 발견 3) — 확인한 사실만큼만 말하는 네 경우.

| 경우                                   | confirmation                     | 문장                                             |
|----------------------------------------|----------------------------------|--------------------------------------------------|
| 보내기 전부터 목표값(보내지 않음)        | already_at_target                | 이미 바람 세기 강으로 설정돼 있어요. 그래서 보내지 않았어요. |
| 보내기 전 다른 값 → 보낸 뒤 목표값       | state_confirmed                  | 바람 세기 강으로 바꿨어요.                        |
| 보내기 전 값 모름 → 보낸 뒤 목표값       | state_confirmed_unknown_before   | 바람 세기 강으로 설정된 것을 확인했어요.('바꿨어요' 금지) |
| 보낸 뒤 상태 확인 실패                   | none (status unconfirmed)        | 설정이 바뀌었는지 확인하지 못했어요.                          |

폰·키오스크는 already_at_target을 '이미'·'보내지 않았어요', 확인을 '설정된 것을 확인'·'바꿨어요'로 가른다
(app·키오스크 command_result.dart) — 이 낱말은 바꾸지 않는다(10/17 쉬운 말).

설정 이름은 :meth:`ThinqCapability.setting_phrase` — "바람 세기 강"·"운전 모드 청정"처럼 속성 이름을 붙인다(10/18 쉬운 말 3차:
'풍량'·'강풍' 대신 폰·키오스크 버튼과 같은 '바람 세기'·'약·중·강').
"""

from __future__ import annotations


def _final(word: str) -> int | None:
    last = word.strip()[-1:]
    if "가" <= last <= "힣":
        return (ord(last) - 0xAC00) % 28
    return None


def direction(word: str) -> str:
    """으로/로 — 받침 없음·ㄹ 받침이면 '로'(한글이 아니면 '으로')."""
    f = _final(word)
    return "로" if f in (0, 8) else "으로"


def already_sentence(phrase: str) -> str:
    return f"이미 {phrase}{direction(phrase)} 설정돼 있어요. 그래서 보내지 않았어요."


def changed_sentence(phrase: str) -> str:
    return f"{phrase}{direction(phrase)} 바꿨어요."


def target_seen_sentence(phrase: str) -> str:
    return f"{phrase}{direction(phrase)} 설정된 것을 확인했어요."


UNCONFIRMED_SENTENCE = "설정이 바뀌었는지 확인하지 못했어요."


def dispatch_of(receipt: str | None, confirmation: str | None) -> str:
    """기록 구분 — 명령을 보낸 실행인가, 상태만 확인한 결과인가.

    ``sent``(받았다는 응답) · ``state_only``(이미 목표값, 보내지 않고 상태만 확인) · ``not_sent``(보내지 않음) ·
    ``unknown``(보냈는지 모름·옛 기록)."""
    if confirmation == "already_at_target":
        return "state_only"
    if receipt == "accepted":
        return "sent"
    if receipt == "not_dispatched":
        return "not_sent"
    return "unknown"


__all__ = ["UNCONFIRMED_SENTENCE", "already_sentence", "changed_sentence", "direction", "dispatch_of",
           "target_seen_sentence"]
