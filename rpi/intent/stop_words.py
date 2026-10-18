"""정지어 판정 — 텍스트·홈 음성 명령의 **해석 맨 앞**(2026-10-16 안전 보고 G7).

예전에는 서버 규칙이 "멈춰"·"그만"·"정지해줘"를 전자레인지 '취소' 버튼 누름의 별칭으로 받았다 — 쉬는 중이면 누름 장치가 실제로
움직여 '취소'를 눌렀다. 이제 정지어는 **버튼 누름으로 해석하지 않고** ``POST /stop``과 같은 뜻으로 보낸다(라우터).

규칙(보수적, 전체 일치):

- 공백·문장부호를 빼고 소문자로 바꾼 뒤 **발화 전체가 아래 정지어만으로** 이루어져야 한다("멈춰 멈춰"는 된다).
  긴 문장 속 낱말은 받지 않는다("전자레인지 멈춰 있어"·"그만 데워줘"는 정지어가 아니다) — 규칙 계층의 '전체 일치' 원칙과
  같고, 정지는 화면의 정지 버튼이 본 수단이다.
- 정지어 목록·판정은 폰 실행 중 음성 정지(``app/lib/providers/voice_stop_provider.dart``의 ``isStopPhrase``)와 **같다** —
  같은 말이 실행 중에는 정지, 쉬는 중에는 버튼 누름이 되지 않게(시험이 두 목록을 대조한다).
- **'취소'는 정지어가 아니다.** "취소"·"취소해줘"·"취소 버튼 눌러"는 전자레인지 '취소' 버튼을 누르라는 말로 남는다(가전의
  버튼 이름을 부른 것이라 버튼 누름이 사용자가 바란 동작이다). 정지어로 넓히려면 폰 목록과 함께 바꾼다.
- 가전에 '정지' 같은 이름의 버튼·기능이 등록돼 있어도 정지어가 이긴다(정지 쪽이 덜 위험하다).
"""

from __future__ import annotations

import re

from .rules import UnknownIntentError

#: 정지로 받는 짧은 말. 판정은 앞에서부터 **이 순서대로** 처음 맞는 말을 떼어 낸다(같은 뿌리는 긴 말을 먼저 적었다).
STOP_WORDS: tuple[str, ...] = (
    "멈춰주세요", "멈춰줘요", "멈춰줘", "멈춰요", "멈춰라", "멈추어", "멈춰", "멈춤",
    "정지해주세요", "정지해줘", "정지해요", "정지해", "정지",
    "그만해주세요", "그만해줘", "그만해요", "그만해", "그만",
    "스톱", "스탑", "stop",
)

#: 판정 전에 지우는 글자(폰과 같다).
_IGNORED = re.compile(r"[\s.,!?~·…\"]")
#: 이보다 긴 발화는 정지어로 보지 않는다(폰과 같다 — 긴 문장은 다른 뜻일 수 있다).
MAX_STOP_PHRASE_CHARS = 16


#: 정지어를 실행 목적으로 받은 호출자(라우터를 거치지 않은 경로)에게 주는 문장.
STOP_PHRASE_REFUSAL = "'멈춰' 같은 정지 말은 버튼 누름으로 실행하지 않아요 — 정지 버튼을 눌러 주세요"


class StopPhraseError(UnknownIntentError):
    """정지어를 실행 목적(버튼 시퀀스로 풀 말)으로 받았다 — 해석하지 않고 거절한다(두 번째 방어, G7)."""


def refuse_stop_phrase(purpose: str | None) -> None:
    """목적 실행 진입점의 두 번째 방어 — 정지어면 `StopPhraseError`(422). 라우터는 그 전에 정지로 보낸다."""
    if is_stop_phrase(purpose):
        raise StopPhraseError(STOP_PHRASE_REFUSAL)


def is_stop_phrase(text: str | None) -> bool:
    """발화 전체가 정지어(하나 이상 반복)인가. 위 모듈 설명의 규칙."""
    if not text:
        return False
    rest = _IGNORED.sub("", text.lower())
    if not rest or len(rest) > MAX_STOP_PHRASE_CHARS:
        return False
    while rest:
        hit = next((w for w in STOP_WORDS if rest.startswith(w)), None)
        if hit is None:
            return False
        rest = rest[len(hit):]
    return True
