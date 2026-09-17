import pytest

from rpi.intent import IntentResolver, RuleBasedIntentResolver, TieredIntentResolver, UnknownIntentError


class _StubResolver(IntentResolver):
    """Records whether it was asked to resolve, and either returns or fails."""

    def __init__(self, sequence: tuple[str, ...] | None = None):
        self.sequence = sequence
        self.calls: list[str] = []

    def resolve(self, purpose: str) -> tuple[str, ...]:
        self.calls.append(purpose)
        if self.sequence is None:
            raise UnknownIntentError(f"unsupported purpose: {purpose}")
        return self.sequence


class _BrokenResolver(IntentResolver):
    """Raises a non-UnknownIntentError bug -- must never be swallowed."""

    def resolve(self, purpose: str) -> tuple[str, ...]:
        raise RuntimeError("sensor bus wedged")


def test_first_resolver_success_short_circuits_the_rest():
    first = _StubResolver(("해동", "시작"))
    second = _StubResolver(("이 값은 절대 안 나와야 함",))

    resolver = TieredIntentResolver((first, second))

    assert resolver.resolve("즉석밥 데워줘") == ("해동", "시작")
    assert first.calls == ["즉석밥 데워줘"]
    assert second.calls == []  # 두 번째 티어는 아예 호출도 안 됨


def test_falls_through_to_second_tier_when_first_fails():
    first = _StubResolver(None)
    second = _StubResolver(("해동", "시작"))

    resolver = TieredIntentResolver((first, second))

    assert resolver.resolve("즉석밥 데워줘") == ("해동", "시작")
    assert first.calls == ["즉석밥 데워줘"]
    assert second.calls == ["즉석밥 데워줘"]


def test_all_tiers_failing_raises_unknown_intent_error():
    resolver = TieredIntentResolver((_StubResolver(None), _StubResolver(None)))

    with pytest.raises(UnknownIntentError):
        resolver.resolve("아무도 모르는 명령")


def test_non_unknown_intent_errors_are_not_swallowed():
    resolver = TieredIntentResolver((_BrokenResolver(), _StubResolver(("시작",))))

    with pytest.raises(RuntimeError, match="sensor bus wedged"):
        resolver.resolve("즉석밥 데워줘")


def test_empty_resolver_list_rejected_at_construction():
    with pytest.raises(ValueError):
        TieredIntentResolver(())


def test_rule_based_resolver_composes_as_the_first_tier():
    # docs/inference-boundary.md가 요구하는 실제 조립 형태: 온디바이스 규칙이 먼저,
    # 그다음 온디바이스/외부 리졸버가 이어진다.
    rules = RuleBasedIntentResolver()
    second_tier = _StubResolver(("이건 규칙에 없을 때만 나옴",))

    resolver = TieredIntentResolver((rules, second_tier))

    assert resolver.resolve("즉석밥 데워줘") == ("즉석밥", "시작")
    assert second_tier.calls == []  # 규칙이 이미 처리해서 다음 티어까지 안 감

    assert resolver.resolve("규칙에 없는 명령") == ("이건 규칙에 없을 때만 나옴",)
    assert second_tier.calls == ["규칙에 없는 명령"]
