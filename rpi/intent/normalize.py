"""음성 명령 말 다듬기 + '혹시 이것인가요?' 후보 — 본체 안, 결정론적(2026-10-19, 조사 문서 §5-1 ①②).

새 AI가 아니라 **규칙 계층 보강**이다. 해석 결과는 언제나 닫힌 목록(그 가전에 등록된 동작) 중 하나 또는 '모름'.

1. :func:`normalize_utterance` — 공백·문장부호·군말을 빼고 끝 어미를 표준형으로, 가전 이름·끝 동작 별칭을 표준 낱말로
   (표는 `voice_lexicon.py` 한 곳). 규칙 계층·LG 가전 목적 비교·사용자 등록 기능 이름 비교가 모두 이 함수를 쓴다.
2. :func:`suggest` — 1로도 못 찾았을 때만 한글 자모로 풀어 편집 거리로 가장 가까운 등록 동작 **하나**를 고른다.
   점수 하한 미만·1·2위 차이 작음·반대 뜻·부정·정지어면 없음. 후보는 **실행하지 않는다** — 응답에 후보로만 싣는다.

정지어 판정(`stop_words.is_stop_phrase`)은 이 다듬기보다 **먼저**, 원래 문장으로 한다(G7). 여기서는 다듬은 문장이
정지어가 되면 일치·후보를 모두 내지 않는다(두 번째 방어).
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from functools import lru_cache

from . import voice_lexicon as lex

_PUNCT = re.compile(r"[\s.,!?~·…\"'“”‘’]+")
_APPLIANCE_ALIASES = tuple((re.compile(p), r) for p, r in lex.APPLIANCE_ALIASES)
_NEGATION = re.compile("|".join(lex.NEGATION_PATTERNS))
_PARTICLE = re.compile(r"(을|를)(?=(" + "|".join(lex.OBJECT_PARTICLE_BEFORE) + r")$)")
_ENDINGS = tuple(sorted(lex.ENDINGS, key=lambda e: -len(e[0])))
_VERB_ALIASES = tuple(sorted(lex.VERB_ALIASES, key=lambda e: -len(e[0])))

_HANGUL_BASE = 0xAC00
_HANGUL_LAST = 0xD7A3
# 받침 없는 '아/애/어/여/워' 꼴 모음(중성 번호 ㅏ0 ㅐ1 ㅓ4 ㅕ6 ㅝ14) — "켜요"·"꺼라"·"바꿔요"의 앞 글자.
_SOFT_VOWELS = frozenset({0, 1, 4, 6, 14})


def _drop_filler_tokens(text: str) -> str:
    tokens = text.split()
    out: list[str] = []
    i = 0
    while i < len(tokens):
        if tokens[i] == "한" and i + 1 < len(tokens) and tokens[i + 1] == "번":
            i += 2
            continue
        if tokens[i] not in lex.FILLER_TOKENS:
            out.append(tokens[i])
        i += 1
    return " ".join(out)


def _strip_endings(text: str) -> str:
    for suffix, repl in _ENDINGS:
        if text.endswith(suffix) and len(text) > len(suffix):
            text = text[: -len(suffix)] + repl
            break
    if len(text) >= 2 and text[-1] in lex.SOFT_ENDINGS:
        prev = ord(text[-2])
        if _HANGUL_BASE <= prev <= _HANGUL_LAST:
            offset = prev - _HANGUL_BASE
            if offset % 28 == 0 and (offset // 28) % 21 in _SOFT_VOWELS:
                text = text[:-1]
    # 끝의 '해'(하다 동사)는 뗀다 — "세탁 시작해줘"·"세탁 시작"·"해동해줘"·"해동"이 같은 키.
    if len(text) >= 3 and text.endswith("해"):
        text = text[:-1]
    return text


def _apply_verb_aliases(text: str) -> str:
    for suffix, repl in _VERB_ALIASES:
        if text.endswith(suffix) and text != suffix:
            return text[: -len(suffix)] + repl
        if text == suffix:
            return repl
    return text


def normalize_utterance(text: str | None) -> str:
    """비교 키 — 위 1의 규칙. 빈 문장은 빈 문자열."""
    if not text:
        return ""
    s = unicodedata.normalize("NFC", text).strip().lower()
    s = _drop_filler_tokens(s)
    s = _PUNCT.sub("", s)
    for filler in lex.FILLER_SUBSTRINGS:
        s = s.replace(filler, "")
    for pattern, repl in _APPLIANCE_ALIASES:
        s = pattern.sub(repl, s)
    s = _strip_endings(s)
    s = _PARTICLE.sub("", s)
    s = _apply_verb_aliases(s)
    return s


def is_negated(text: str | None) -> bool:
    """부정 꼴('켜지 마'·'안 켜'·'켜지 말고')이 있는가 — 원래 문장·다듬은 문장 어느 쪽을 줘도 된다."""
    if not text:
        return False
    return _NEGATION.search(_PUNCT.sub("", text)) is not None


def refuses_matching(text: str | None) -> bool:
    """일치·후보를 아예 하지 않을 문장 — 부정, 또는 다듬은 결과가 정지어(G7 두 번째 방어)."""
    from .stop_words import is_stop_phrase  # noqa: PLC0415 — stop_words가 rules를 읽고 rules가 이 모듈을 읽는다

    return is_negated(text) or is_stop_phrase(normalize_utterance(text))


# ── 한글 자모 편집 거리 ──────────────────────────────────────────────────


@lru_cache(maxsize=4096)
def jamo(text: str) -> tuple[str, ...]:
    """완성형 한글을 초성·중성·종성 번호로 푼다(그 밖의 글자는 그대로 한 칸)."""
    out: list[str] = []
    for ch in text:
        code = ord(ch)
        if _HANGUL_BASE <= code <= _HANGUL_LAST:
            offset = code - _HANGUL_BASE
            out.append(f"L{offset // 588}")
            out.append(f"V{(offset % 588) // 28}")
            if offset % 28:
                out.append(f"T{offset % 28}")
        else:
            out.append(ch)
    return tuple(out)


def _edit_distance(a: Sequence[str], b: Sequence[str]) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def jamo_score(a: str, b: str, floor: float = 0.0) -> float:
    """1 − 자모 편집 거리 / 긴 쪽 자모 수. 같으면 1.0. 길이 차이만으로 ``floor``에 못 미치면 거리 계산 없이 0.0."""
    ja, jb = jamo(a), jamo(b)
    longest = max(len(ja), len(jb))
    if longest == 0:
        return 0.0
    if 1.0 - abs(len(ja) - len(jb)) / longest < floor:
        return 0.0  # 편집 거리 ≥ 길이 차이 — 하한에 닿을 수 없다
    return 1.0 - _edit_distance(ja, jb) / longest


def _sides(text: str) -> dict[int, set[str]]:
    found: dict[int, set[str]] = {}
    for index, group in enumerate(lex.POLARITY_GROUPS):
        for side, words in group.items():
            if any(w in text for w in words):
                found.setdefault(index, set()).add(side)
    return found


@lru_cache(maxsize=4096)
def _sides_cached(text: str) -> dict[int, set[str]]:
    return _sides(text)


def polarity_compatible(utterance_key: str, candidate_key: str) -> bool:
    """후보 쪽 낱말이 말에 있고 다른 쪽 낱말은 없는가(반대 뜻 묶음마다). 후보에 묶음 낱말이 없으면 통과."""
    said = _sides(utterance_key)
    for index, sides in _sides_cached(candidate_key).items():
        if said.get(index) != sides:
            return False
    return True


@dataclass(frozen=True)
class Candidate:
    """비교 대상 하나 — ``keys``는 이미 다듬은 비교 키들(별칭·이름 붙인 꼴 포함), ``purpose``·``label``은 응답에 싣는 값."""

    purpose: str
    label: str
    keys: tuple[str, ...]


def suggest(text: str, candidates: Iterable[Candidate], *, utterance_key: str | None = None,
            min_score: float = lex.FUZZY_MIN_SCORE, min_gap: float = lex.FUZZY_MIN_GAP) -> Candidate | None:
    """위 2 — 기준을 넘는 후보 하나, 아니면 None. 실행하지 않는다."""
    if refuses_matching(text):
        return None
    key = utterance_key if utterance_key is not None else normalize_utterance(text)
    if not key:
        return None
    scored: list[tuple[float, Candidate]] = []
    for cand in candidates:
        best = max((jamo_score(key, k, min_score) for k in cand.keys if polarity_compatible(key, k)), default=None)
        if best is not None:
            scored.append((best, cand))
    if not scored:
        return None
    scored.sort(key=lambda item: -item[0])
    top_score, top = scored[0]
    if top_score < min_score:
        return None
    if len(scored) > 1 and top_score - scored[1][0] < min_gap:
        return None
    return top
