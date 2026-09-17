"""규칙 기반 리졸버 — 정규화·별칭·주입 규칙 계약 검증."""

import pytest

from rpi.intent.rules import RuleBasedIntentResolver, UnknownIntentError


@pytest.fixture()
def resolver() -> RuleBasedIntentResolver:
    return RuleBasedIntentResolver()


def test_canonical_purpose_resolves(resolver):
    assert resolver.resolve("즉석밥 데워줘") == ("즉석밥", "시작")


@pytest.mark.parametrize(
    "utterance",
    [
        "즉석밥데워줘",       # 공백 없음
        "즉석밥 데워 줘",     # 공백 위치 다름
        "즉석밥 데워줘!",     # 문장부호
        "  즉석밥 데워줘.  ",  # 앞뒤 공백 + 마침표
    ],
)
def test_whitespace_and_punctuation_variants_resolve(resolver, utterance):
    # STT는 같은 말도 공백·부호를 다르게 뱉는다 — 전부 같은 규칙에 매칭돼야 한다
    assert resolver.resolve(utterance) == ("즉석밥", "시작")


@pytest.mark.parametrize(
    ("alias", "expected"),
    [
        ("즉석밥 좀 데워줘", ("즉석밥", "시작")),
        ("밥 데워줘", ("즉석밥", "시작")),
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
        custom.resolve("즉석밥 데워줘")


def test_injected_rules_also_normalized():
    custom = RuleBasedIntentResolver({"불 켜줘": ("전원",)})
    assert custom.resolve("불켜줘!") == ("전원",)


def test_microwave_rules_press_only_buttons_the_builtin_microwave_has():
    # 규칙이 내는 버튼 이름은 실제 버튼판에 있어야 한다. 없는 이름("시간 90초")은
    # 서버가 좌표를 찾지 못하고, 화면의 버튼판도 가리킬 자리가 없다.
    # 에어컨 규칙은 서버 내장 가전이 아니라(폰에서 등록) 여기서 보지 않는다.
    from rpi.services.appliance_registry import BUILTIN_MICROWAVE

    labels = {b.label for b in BUILTIN_MICROWAVE.buttons}
    missing = {
        purpose: [name for name in steps if name not in labels]
        for purpose, steps in RuleBasedIntentResolver.DEFAULT_RULES.items()
        if not purpose.startswith("에어컨")
    }
    assert {p: m for p, m in missing.items() if m} == {}
