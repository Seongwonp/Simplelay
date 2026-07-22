from collections.abc import Mapping, Sequence

from .base import IntentResolver


class UnknownIntentError(ValueError):
    pass


class RuleBasedIntentResolver(IntentResolver):
    DEFAULT_RULES = {"우유 데워줘": ("해동", "시간 90초", "시작")}

    def __init__(self, rules: Mapping[str, Sequence[str]] | None = None) -> None:
        selected = rules if rules is not None else self.DEFAULT_RULES
        self._rules = {key.strip(): tuple(value) for key, value in selected.items()}

    def resolve(self, purpose: str) -> tuple[str, ...]:
        normalized = purpose.strip()
        try:
            return self._rules[normalized]
        except KeyError as exc:
            raise UnknownIntentError(f"unsupported purpose: {normalized}") from exc
