"""규칙 기반 리졸버 — 정규화·별칭·주입 규칙 계약 검증."""

import pytest

from rpi.intent.rules import RuleBasedIntentResolver, UnknownIntentError


@pytest.fixture()
def resolver() -> RuleBasedIntentResolver:
    return RuleBasedIntentResolver()


def test_canonical_purpose_resolves(resolver):
    assert resolver.resolve("우유 데워줘") == ("해동", "시간 90초", "시작")


@pytest.mark.parametrize(
    "utterance",
    [
        "우유데워줘",       # 공백 없음
        "우유 데워 줘",     # 공백 위치 다름
        "우유 데워줘!",     # 문장부호
        "  우유 데워줘.  ",  # 앞뒤 공백 + 마침표
    ],
)
def test_whitespace_and_punctuation_variants_resolve(resolver, utterance):
    # STT는 같은 말도 공백·부호를 다르게 뱉는다 — 전부 같은 규칙에 매칭돼야 한다
    assert resolver.resolve(utterance) == ("해동", "시간 90초", "시작")


@pytest.mark.parametrize(
    ("alias", "expected"),
    [
        ("우유 좀 데워줘", ("해동", "시간 90초", "시작")),
        ("우유를 데워줘", ("해동", "시간 90초", "시작")),
        ("일분 돌려줘", ("1분", "시작")),
        ("멈춰줘", ("취소",)),
        ("정지해줘", ("취소",)),
    ],
)
def test_default_aliases_resolve_to_canonical_sequence(resolver, alias, expected):
    assert resolver.resolve(alias) == expected


def test_unknown_purpose_raises(resolver):
    with pytest.raises(UnknownIntentError):
        resolver.resolve("냉장고 정리해줘")


def test_injected_rules_do_not_get_default_aliases():
    # 규칙을 직접 주입하면 호출자의 어휘만 존재해야 한다 — 기본 별칭이
    # 몰래 섞이면 사용자 정의 가전에서 예상 밖 시퀀스가 실행될 수 있다
    custom = RuleBasedIntentResolver({"켜줘": ("전원",)})
    assert custom.resolve("켜줘") == ("전원",)
    with pytest.raises(UnknownIntentError):
        custom.resolve("우유 데워줘")


def test_injected_rules_also_normalized():
    custom = RuleBasedIntentResolver({"불 켜줘": ("전원",)})
    assert custom.resolve("불켜줘!") == ("전원",)
