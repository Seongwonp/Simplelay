"""인자 정규화·상한·fingerprint 계약 (U1-a, 9/27 보완)."""

import json
import math

import pytest

from rpi.commands import (
    MAX_ARG_STRING_LEN,
    MAX_ARGS,
    MAX_ARGS_BYTES,
    ArgumentError,
    canonical_json,
    fingerprint_of,
    normalize_args,
)


# ── 정규화 ──────────────────────────────────────────────────────────────────

def test_args_are_sorted_by_name_regardless_of_input_order():
    assert normalize_args({"b": 1, "a": 2}) == (("a", 2), ("b", 1))
    assert normalize_args([("b", 1), ("a", 2)]) == (("a", 2), ("b", 1))


def test_none_and_empty_normalize_to_empty_tuple():
    assert normalize_args(None) == ()
    assert normalize_args({}) == ()


def test_string_values_are_nfc_normalized_but_not_trimmed():
    # 'é'를 분해형(e + 결합 악센트)으로 넣어도 조합형 한 글자로 저장된다 --
    # 같은 글자를 다르게 적은 두 입력이 다른 fingerprint가 되지 않게.
    decomposed = "é"
    assert normalize_args({"mode": decomposed}) == (("mode", "é"),)
    assert normalize_args({"mode": "é"}) == normalize_args({"mode": decomposed})
    # 공백은 값의 일부다 -- 잘라서 같은 명령으로 만들지 않는다.
    assert normalize_args({"mode": " strong "}) == (("mode", " strong "),)


def test_bool_is_kept_distinct_from_int():
    # 파이썬은 True == 1이라 튜플 비교로는 같아 보인다. 타입이 보존되고
    # fingerprint가 달라지는 것이 계약이다.
    (_, as_bool), = normalize_args({"on": True})
    (_, as_int), = normalize_args({"on": 1})
    assert type(as_bool) is bool and type(as_int) is int
    assert canonical_json({"on": as_bool}) == '{"on":true}'
    assert canonical_json({"on": as_int}) == '{"on":1}'
    assert (fingerprint_of("thinq", "p", "a", (("on", True),), ())
            != fingerprint_of("thinq", "p", "a", (("on", 1),), ()))


# ── 거절 ─────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("value", [float("nan"), float("inf"), -float("inf")])
def test_non_finite_numbers_are_rejected(value):
    with pytest.raises(ArgumentError, match="NaN"):
        normalize_args({"level": value})


@pytest.mark.parametrize("value", [None, [1], {"a": 1}, (1,), b"x", object()])
def test_only_scalar_types_are_accepted(value):
    with pytest.raises(ArgumentError, match="타입"):
        normalize_args({"level": value})


@pytest.mark.parametrize("name", ["", "Fan", "fan speed", "1st", "fan-speed", "a" * 41, "풍량"])
def test_invalid_names_are_rejected(name):
    with pytest.raises(ArgumentError, match="이름"):
        normalize_args({name: 1})


def test_non_string_name_is_rejected():
    with pytest.raises(ArgumentError, match="문자열"):
        normalize_args([(1, "x")])


def test_duplicate_names_from_iterable_are_rejected():
    with pytest.raises(ArgumentError, match="중복"):
        normalize_args([("a", 1), ("a", 2)])


def test_too_many_args_rejected():
    args = {f"k{i}": i for i in range(MAX_ARGS + 1)}
    with pytest.raises(ArgumentError, match="개"):
        normalize_args(args)


def test_empty_string_and_control_chars_rejected():
    with pytest.raises(ArgumentError, match="비어"):
        normalize_args({"mode": ""})
    with pytest.raises(ArgumentError, match="제어"):
        normalize_args({"mode": "a\x00b"})


def test_string_length_limit():
    normalize_args({"mode": "x" * MAX_ARG_STRING_LEN})
    with pytest.raises(ArgumentError, match="자"):
        normalize_args({"mode": "x" * (MAX_ARG_STRING_LEN + 1)})


def test_total_bytes_limit_counts_utf8():
    # 한글은 UTF-8에서 3바이트 -- 글자 수 상한 안에서도 바이트 상한을 넘을 수 있다.
    args = {f"k{i:02d}": "가" * MAX_ARG_STRING_LEN for i in range(MAX_ARGS)}
    assert len(canonical_json(args).encode("utf-8")) > MAX_ARGS_BYTES
    with pytest.raises(ArgumentError, match="바이트"):
        normalize_args(args)


def test_huge_int_rejected():
    with pytest.raises(ArgumentError, match="정수"):
        normalize_args({"n": 2**60})


# ── 정규 JSON ────────────────────────────────────────────────────────────────

def test_canonical_json_is_key_sorted_compact_and_keeps_unicode():
    assert canonical_json({"b": 1, "a": "가"}) == '{"a":"가","b":1}'


def test_canonical_json_refuses_nan():
    with pytest.raises(ValueError):
        canonical_json({"a": math.nan})


# ── fingerprint ──────────────────────────────────────────────────────────────

def _fp(**overrides):
    base = dict(route="thinq", target_id="purifier", action="fan_speed",
                args=(("level", 3),), buttons=())
    base.update(overrides)
    return fingerprint_of(**base)


def test_fingerprint_is_sha256_hex_and_deterministic():
    fp = _fp()
    assert len(fp) == 64 and int(fp, 16) >= 0
    assert fp == _fp()


def test_fingerprint_ignores_arg_input_order():
    a = fingerprint_of("thinq", "p", "set", normalize_args({"x": 1, "y": 2}), ())
    b = fingerprint_of("thinq", "p", "set", normalize_args({"y": 2, "x": 1}), ())
    assert a == b


@pytest.mark.parametrize("change", [
    dict(args=(("level", 4),)),
    dict(args=(("level", "3"),)),
    dict(args=(("level", 3.0),)),
    dict(action="power"),
    dict(target_id="purifier2"),
    dict(route="physical", action="press_buttons", args=(), buttons=("시작",)),
])
def test_one_difference_changes_fingerprint(change):
    assert _fp(**change) != _fp()


def test_button_order_matters_for_physical_fingerprint():
    a = fingerprint_of("physical", "mw", "press_buttons", (), ("즉석밥", "시작"))
    b = fingerprint_of("physical", "mw", "press_buttons", (), ("시작", "즉석밥"))
    assert a != b


def test_fingerprint_payload_does_not_depend_on_json_module_defaults():
    # 정규 JSON을 우회해 기본 json.dumps로 만들면 공백·정렬이 달라 다른 해시가
    # 나온다 -- fingerprint_of가 canonical_json을 쓰고 있다는 회귀 방지.
    import hashlib
    payload = {"route": "thinq", "target_id": "p", "action": "a", "args": {"k": 1}, "buttons": []}
    loose = hashlib.sha256(json.dumps(payload).encode()).hexdigest()
    assert fingerprint_of("thinq", "p", "a", (("k", 1),), ()) != loose


# ── 입력 형태 (Codex 검토 #4) ────────────────────────────────────────────────

@pytest.mark.parametrize("bad", [
    ["ab"],            # 문자열이 ('a', 'b')로 언패킹되던 회귀
    [b"ab"],
    ["a"],
    [("a", 1, 2)],
    [("a",)],
    [{"a": 1}],
    [12],
])
def test_non_pair_items_are_rejected(bad):
    with pytest.raises(ArgumentError, match="쌍"):
        normalize_args(bad)


def test_list_pairs_are_accepted_like_tuples():
    assert normalize_args([["a", 1]]) == (("a", 1),)
