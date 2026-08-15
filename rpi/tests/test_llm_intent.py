import pytest

from rpi.intent import LlmIntentResolver, RuleBasedIntentResolver, UnknownIntentError
from rpi.intent.mock import MockLlmClient

KNOWN_BUTTONS = frozenset({"해동", "시작", "취소"})


def test_valid_model_output_returns_sequence():
    client = MockLlmClient({"우유 데워줘": '{"sequence": ["해동", "시작"]}'})
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS)

    assert resolver.resolve("우유 데워줘") == ("해동", "시작")
    assert client.calls == [("우유 데워줘", ("시작", "취소", "해동"))]


def test_malformed_json_falls_back_to_rule_resolver():
    client = MockLlmClient({"우유 데워줘": "this is not json"})
    fallback = RuleBasedIntentResolver()
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS, fallback=fallback)

    assert resolver.resolve("우유 데워줘") == ("해동", "시간 90초", "시작")


def test_unknown_button_falls_back_to_rule_resolver():
    client = MockLlmClient({"우유 데워줘": '{"sequence": ["존재하지않는버튼"]}'})
    fallback = RuleBasedIntentResolver()
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS, fallback=fallback)

    assert resolver.resolve("우유 데워줘") == ("해동", "시간 90초", "시작")


def test_empty_sequence_falls_back_to_rule_resolver():
    client = MockLlmClient({"우유 데워줘": '{"sequence": []}'})
    fallback = RuleBasedIntentResolver()
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS, fallback=fallback)

    assert resolver.resolve("우유 데워줘") == ("해동", "시간 90초", "시작")


def test_client_exception_falls_back_to_rule_resolver():
    client = MockLlmClient(error=TimeoutError("network unreachable"))
    fallback = RuleBasedIntentResolver()
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS, fallback=fallback)

    assert resolver.resolve("우유 데워줘") == ("해동", "시간 90초", "시작")


def test_no_fallback_raises_unknown_intent_error():
    client = MockLlmClient({"우유 데워줘": "not json"})
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS)

    with pytest.raises(UnknownIntentError):
        resolver.resolve("우유 데워줘")


def test_fallback_also_failing_raises_unknown_intent_error():
    client = MockLlmClient({})  # LookupError: no canned response
    fallback = RuleBasedIntentResolver({})  # no rules configured either
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS, fallback=fallback)

    with pytest.raises(UnknownIntentError):
        resolver.resolve("아무도 모르는 명령")


def test_blank_purpose_raises_without_calling_client():
    client = MockLlmClient()
    resolver = LlmIntentResolver(client, known_buttons=KNOWN_BUTTONS)

    with pytest.raises(UnknownIntentError):
        resolver.resolve("   ")

    assert client.calls == []


def test_unrestricted_vocabulary_accepts_any_button_names():
    client = MockLlmClient({"환기해줘": '{"sequence": ["환풍기 켜기"]}'})
    resolver = LlmIntentResolver(client)  # no known_buttons supplied

    assert resolver.resolve("환기해줘") == ("환풍기 켜기",)
