"""화면 문장의 조사(이/가·을/를·은/는·과/와·으로/로)를 앞 낱말의 받침으로 고른다.

'이(가)'·'을(를)'처럼 둘 다 적으면 처음 쓰는 사람에게 깨진 문장으로 읽힌다(첫 사용 점검 2026-10-19).
낱말 끝의 괄호 표기("(모의)")·따옴표·공백은 건너뛰고, 숫자는 읽는 소리(1=일, 2=이 …)로 본다.
한글·숫자가 아닌 끝(영문 등)은 받침이 있는 쪽을 쓴다(종전 동작).
"""

from __future__ import annotations

#: 숫자를 읽었을 때 받침이 있는가(0 영 1 일 2 이 3 삼 4 사 5 오 6 육 7 칠 8 팔 9 구), ㄹ 받침인가.
_DIGIT_FINAL = {"0": (True, False), "1": (True, True), "2": (False, False), "3": (True, False),
                "4": (False, False), "5": (False, False), "6": (True, False), "7": (True, True),
                "8": (True, True), "9": (False, False)}
#: 한글 음절의 종성 번호 ㄹ.
_RIEUL = 8


def josa_stem(word: str) -> str:
    """조사 고를 낱말 — 끝의 괄호 표기·따옴표·공백은 건너뛴다."""
    stem = word.strip()
    while True:
        before = stem
        stem = stem.rstrip(" '\"’”")
        if stem.endswith(")") and "(" in stem:
            stem = stem[: stem.rindex("(")].rstrip()
        if stem == before:
            return stem


def _final(word: str) -> tuple[bool, bool]:
    """(받침이 있는가, 그 받침이 ㄹ인가)."""
    last = josa_stem(word)[-1:]
    if "가" <= last <= "힣":
        jong = (ord(last) - 0xAC00) % 28
        return jong != 0, jong == _RIEUL
    if last in _DIGIT_FINAL:
        return _DIGIT_FINAL[last]
    return True, False


def josa(word: str, with_final: str, without_final: str) -> str:
    """받침이 있으면 ``with_final``, 없으면 ``without_final``. '으로/로'는 ㄹ 받침에서도 '로'."""
    has_final, rieul = _final(word)
    if with_final == "으로" and rieul:
        return without_final
    return with_final if has_final else without_final


def with_josa(word: str, with_final: str, without_final: str) -> str:
    """낱말 + 고른 조사."""
    return f"{word}{josa(word, with_final, without_final)}"


def quoted_josa(word: str, with_final: str, without_final: str) -> str:
    """'낱말' + 고른 조사(따옴표로 감싼 이름·말)."""
    return f"'{word}'{josa(word, with_final, without_final)}"
