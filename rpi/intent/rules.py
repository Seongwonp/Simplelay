from collections.abc import Mapping, Sequence

from rpi.josa import quoted_josa

from .base import IntentResolver
from .normalize import is_negated, normalize_utterance


class UnknownIntentError(ValueError):
    pass


def not_understood_message(text: str) -> str:
    """못 알아들었을 때 사람에게 보일 쉬운 말. 조사는 말의 끝 글자로 고른다('을(를)'은 깨진 문장으로 읽힌다)."""
    return f"{quoted_josa(text.strip(), '을', '를')} 알아듣지 못했어요"


class UnrecognizedPurposeError(UnknownIntentError):
    """말을 등록된 동작 어느 것과도 맞추지 못했다(2026-10-19).

    ``suggestion``은 '혹시 이것인가요?' 후보 하나(등록 목적 문장, 이름) — **실행하지 않는다**. ``choices``는 그 가전이 할 수
    있는 동작 목록(등록 목적 문장, 이름). 라우터가 422 본문 ``detail`` 옆에 그대로 싣는다."""

    def __init__(self, text: str, *, suggestion: tuple[str, str] | None = None,
                 choices: Sequence[tuple[str, str]] = ()) -> None:
        super().__init__(not_understood_message(text))
        self.suggestion = suggestion
        self.choices = tuple(choices)

    def body(self) -> dict:
        return {
            "detail": str(self),
            "suggestion": (None if self.suggestion is None
                           else {"purpose": self.suggestion[0], "label": self.suggestion[1]}),
            "choices": [{"purpose": p, "label": label} for p, label in self.choices],
        }


def _normalize(text: str) -> str:
    """STT 출력 편차를 매칭 키에서 없앤다 — 본체 공통 말 다듬기(`rpi/intent/normalize.py`, 2026-10-19).

    "즉석밥 데워 줘", "즉석밥데워줘!", "즉석밥 좀 데워 주세요"가 전부 같은 키가 된다. 같은 뜻 사전에 없는 말은
    바꾸지 않는다(짐작 금지).
    """
    return normalize_utterance(text)


class RuleBasedIntentResolver(IntentResolver):
    # 대표 발화 → 버튼 시퀀스 (전자레인지 데모 기준).
    # 버튼 이름은 내장 전자레인지 버튼판에 실제로 있는 것만 쓴다 -- 없는 이름은
    # 서버가 좌표를 찾지 못한다(test_rules가 고정한다). 대표 시연 문장은
    # '즉석밥 데워줘'다(9/17, 실제 버튼 두 개로 끝나는 일상 명령).
    # 자유발화 전체를 여기서 감당하려는 게 아니다 — 시연·일상 핵심 명령의
    # 결정론적 1차 계층이고, 매칭 실패는 TieredIntentResolver가 벡터DB/LLM
    # 계층으로 넘긴다 (docs/inference-boundary.md).
    DEFAULT_RULES = {
        "해동해줘": ("해동", "시작"),
        "30초 돌려줘": ("30초", "시작"),
        "1분 돌려줘": ("1분", "시작"),
        "즉석밥 데워줘": ("즉석밥", "시작"),
        "냉동식품 데워줘": ("냉동식품", "시작"),
        "라면 끓여줘": ("라면", "시작"),
        "5분 돌려줘": ("5분", "시작"),
        "에어컨 켜줘": ("전원", "냉방"),
        "에어컨 꺼줘": ("전원",),
        "취소해줘": ("취소",),
    }

    # 같은 뜻의 다른 발화 → 대표 발화. 기본 규칙을 쓸 때만 적용된다
    # (규칙을 직접 주입하는 호출자는 자기 어휘를 완전히 통제한다).
    DEFAULT_ALIASES = {
        "즉석밥 데워": "즉석밥 데워줘",
        "밥 데워줘": "즉석밥 데워줘",
        "햇반 데워줘": "즉석밥 데워줘",
        "즉석밥 좀 데워줘": "즉석밥 데워줘",
        "냉동식품 데워": "냉동식품 데워줘",
        "냉동 데워줘": "냉동식품 데워줘",
        "냉동치킨 데워줘": "냉동식품 데워줘",
        "만두 데워줘": "냉동식품 데워줘",
        "라면 끓여": "라면 끓여줘",
        "라면 해줘": "라면 끓여줘",
        "라면 좀 끓여줘": "라면 끓여줘",
        "에어컨 켜": "에어컨 켜줘",
        "에어컨 틀어줘": "에어컨 켜줘",
        "에어컨 틀어": "에어컨 켜줘",
        "냉방 켜줘": "에어컨 켜줘",
        "시원하게 해줘": "에어컨 켜줘",
        "에어컨 꺼": "에어컨 꺼줘",
        "에어컨 종료": "에어컨 꺼줘",
        "해동 좀 해줘": "해동해줘",
        "해동 부탁해": "해동해줘",
        "삼십초 돌려줘": "30초 돌려줘",
        "삼십 초 돌려줘": "30초 돌려줘",
        "일분 돌려줘": "1분 돌려줘",
        "일 분 돌려줘": "1분 돌려줘",
        "1분만 돌려줘": "1분 돌려줘",
        "오분 돌려줘": "5분 돌려줘",
        "오 분 돌려줘": "5분 돌려줘",
        # '멈춰'·'그만'·'정지해줘'는 여기 두지 않는다(2026-10-16 안전 보고 G7). 예전에는 '취소' 버튼 누름의 별칭이라
        # 쉬는 중이면 누름 장치가 실제로 '취소'를 눌렀다 — 정지어는 해석 맨 앞(``stop_words.is_stop_phrase``)에서
        # ``POST /stop``의 뜻으로 간다. 이 표는 벡터 검색 예시(`vectordb_seed`)로도 들어가므로 다시 넣지 않는다.
        # '취소'는 버튼 이름을 부른 말이라 그대로 '취소' 버튼이다.
        "취소": "취소해줘",
    }

    def __init__(self, rules: Mapping[str, Sequence[str]] | None = None) -> None:
        selected = rules if rules is not None else self.DEFAULT_RULES
        self._canonical: dict[str, str] = {}
        self._rules: dict[str, tuple[str, ...]] = {}
        #: 다듬은 키가 같은데 버튼이 다른 규칙 — 그 키로는 고르지 않는다(짐작 금지).
        self._ambiguous: set[str] = set()
        for key, value in selected.items():
            self._add(_normalize(key), tuple(value), key.strip())
        if rules is None:
            for alias, canonical in self.DEFAULT_ALIASES.items():
                self._add(_normalize(alias), self._rules[_normalize(canonical)], canonical)

    def _add(self, key: str, buttons: tuple[str, ...], canonical: str) -> None:
        if key in self._rules and self._rules[key] != buttons:
            self._ambiguous.add(key)
        self._rules.setdefault(key, buttons)
        self._canonical.setdefault(key, canonical)

    def resolve(self, purpose: str) -> tuple[str, ...]:
        key = _normalize(purpose)
        # 부정('데워 주지 마')·사전 충돌 키는 일치시키지 않는다.
        if is_negated(purpose) or key in self._ambiguous or key not in self._rules:
            raise UnknownIntentError(not_understood_message(purpose))
        return self._rules[key]

    def learning_purpose(self, purpose: str, buttons: tuple[str, ...]) -> str:
        key = _normalize(purpose)
        if self._rules.get(key) == buttons:
            return self._canonical[key]
        return purpose.strip()
