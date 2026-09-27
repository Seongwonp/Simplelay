"""명령 인자의 검증·정규화와 명령 fingerprint.

U1-a 계약(docs/ThinQ-U1a-명령-결과-승인-계약-2026-09-22.md §2)과 9/27 보완
(docs/하드웨어-수령전-SW-실행계획-2026-09-27.md "S1에서 먼저 바로잡을 계약"):

- frozen 자료형 안에 변경 가능한 dict를 넣지 않는다. 인자는 **이름순으로
  정렬한 (이름, 값) 튜플**로만 저장한다.
- 값은 str·int·float·bool만. 타입·개수·길이·바이트 상한이 있고, NaN·무한대는
  거절한다(정규 JSON으로 만들 수 없고 같은 명령인지 비교할 수 없다).
- fingerprint는 **같은 내용인지 확인하는 용도**다. 사용자 인증이나 일회성
  승인 토큰을 대신하지 않는다 -- 같은 명령을 두 번 승인하면 fingerprint도
  같다. 그래서 승인 1건의 식별은 approval_id가 맡는다(다음 단계의 승인 원장).

정규화는 값의 **표현**만 손본다(유니코드 NFC). 이름을 소문자로 바꾸거나
공백을 잘라 주지 않는다 -- 그런 관용은 "풍량"과 "풍량 "을 같은 명령으로
만들어 승인 대조를 흐린다. 어긋나면 그대로 거절한다.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
from collections.abc import Iterable, Mapping

#: 인자 값으로 허용하는 파이썬 타입. bool은 int의 하위 타입이지만 **따로**
#: 취급한다 -- ``True``와 ``1``은 다른 값이고 fingerprint도 다르다.
ArgValue = str | int | float | bool

#: 정규화된 인자: 이름순 정렬, 중복 없음, 값은 ArgValue.
NormalizedArgs = tuple[tuple[str, ArgValue], ...]

# ── 상한 ────────────────────────────────────────────────────────────────────
# 실사용 클라우드 동작은 인자 한둘(풍량·온도)이다. 프로필 검사(U1-b)가 허용
# 이름·범위를 보기 전에, 여기서는 "말이 되는 크기"만 거른다.
MAX_ARGS = 16
MAX_ARG_NAME_LEN = 40
MAX_ARG_STRING_LEN = 100
#: 정규 JSON으로 만든 인자 전체의 UTF-8 바이트 상한.
MAX_ARGS_BYTES = 1024
#: 정수 절대값 상한 -- JSON 숫자로 왕복해도 값이 보존되는 범위(2^53).
MAX_INT_MAGNITUDE = 2**53

#: 인자 이름: 소문자 영문으로 시작, 영문·숫자·밑줄. 프로필 동작 이름과 같은 규칙.
NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,39}$")


class ArgumentError(ValueError):
    """인자가 계약 밖이다. 메시지는 어떤 인자가 왜 거절됐는지를 담는다."""


def normalize_value(name: str, value: object) -> ArgValue:
    """값 하나를 검증하고 정규화한다. 타입은 바꾸지 않는다."""
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        if abs(value) > MAX_INT_MAGNITUDE:
            raise ArgumentError(f"인자 '{name}'의 정수가 너무 큽니다 (상한 ±{MAX_INT_MAGNITUDE})")
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ArgumentError(f"인자 '{name}'에 NaN·무한대는 쓸 수 없습니다")
        return value
    if isinstance(value, str):
        text = unicodedata.normalize("NFC", value)
        if not text:
            raise ArgumentError(f"인자 '{name}'의 문자열이 비어 있습니다")
        if len(text) > MAX_ARG_STRING_LEN:
            raise ArgumentError(
                f"인자 '{name}'의 문자열이 {len(text)}자입니다 (상한 {MAX_ARG_STRING_LEN})"
            )
        if any(unicodedata.category(ch).startswith("C") for ch in text):
            raise ArgumentError(f"인자 '{name}'에 제어 문자가 들어 있습니다")
        return text
    raise ArgumentError(
        f"인자 '{name}'의 타입 {type(value).__name__}은 허용되지 않습니다 "
        "(str·int·float·bool만)"
    )


def normalize_args(
    args: Mapping[str, object] | Iterable[tuple[str, object]] | None,
) -> NormalizedArgs:
    """인자 묶음을 검증해 이름순 정렬 튜플로 만든다.

    Mapping이든 (이름, 값) 반복이든 받지만, 결과는 항상 같은 형태다 --
    같은 내용이면 입력 순서와 무관하게 같은 튜플이 나오고, 따라서
    fingerprint도 같다.
    """
    if args is None:
        return ()
    items = list(args.items()) if isinstance(args, Mapping) else list(args)
    if len(items) > MAX_ARGS:
        raise ArgumentError(f"인자가 {len(items)}개입니다 (상한 {MAX_ARGS})")
    normalized: dict[str, ArgValue] = {}
    for item in items:
        # 문자열 'ab'는 언패킹하면 ('a', 'b')가 된다 -- 형태를 먼저 본다.
        if isinstance(item, (str, bytes)) or not isinstance(item, (tuple, list)) or len(item) != 2:
            raise ArgumentError(f"인자는 (이름, 값) 쌍이어야 합니다: {item!r}")
        name, value = item
        if not isinstance(name, str):
            raise ArgumentError(f"인자 이름 {name!r}은 문자열이어야 합니다")
        if len(name) > MAX_ARG_NAME_LEN or not NAME_PATTERN.fullmatch(name):
            raise ArgumentError(
                f"인자 이름 '{name}'이 규칙에 맞지 않습니다 "
                "(소문자 영문으로 시작, 영문·숫자·밑줄, 40자 이내)"
            )
        if name in normalized:
            raise ArgumentError(f"인자 이름 '{name}'이 중복됩니다")
        normalized[name] = normalize_value(name, value)
    result = tuple(sorted(normalized.items()))
    size = len(canonical_json(dict(result)).encode("utf-8"))
    if size > MAX_ARGS_BYTES:
        raise ArgumentError(f"인자가 {size}바이트입니다 (상한 {MAX_ARGS_BYTES})")
    return result


def canonical_json(value: object) -> str:
    """같은 내용이면 같은 문자열이 되는 JSON.

    키 정렬, 공백 제거, 비ASCII 보존, NaN·무한대 거절. 파이썬 json은
    ``True``를 ``true``, ``1``을 ``1``, ``1.0``을 ``1.0``으로 적으므로 타입이
    다르면 문자열도 다르다 -- 의도한 동작이다.
    """
    return json.dumps(
        value,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    )


def fingerprint_of(
    route: str,
    target_id: str,
    action: str,
    args: NormalizedArgs,
    buttons: tuple[str, ...],
) -> str:
    """route·target_id·action·정렬한 args·buttons의 정규 JSON을 sha256으로.

    계약 §2 그대로다. 여기 들어가지 않는 것: 목적 문자열, 사용자가 본 요약,
    승인 ID, 시각. 그것들이 달라도 **기계가 할 일**이 같으면 같은 명령이다.
    """
    payload = {
        "route": route,
        "target_id": target_id,
        "action": action,
        "args": dict(args),
        "buttons": list(buttons),
    }
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()
