"""Tries multiple resolvers in priority order; the first success wins.

This is how the on-device-first / external-last-resort boundary from
docs/inference-boundary.md gets built: compose the cheap, reliable,
network-free resolver(s) first and put anything that needs an external
call last, e.g.::

    TieredIntentResolver((
        RuleBasedIntentResolver(),          # 1. on-device, deterministic
        LlmIntentResolver(client, ...),      # 2. on-device or external model
    ))

Each tier only advances to the next on ``UnknownIntentError`` -- any other
exception is a real bug in that tier and propagates immediately rather than
being silently swallowed.
"""

from collections.abc import Sequence

from .base import IntentResolver
from .rules import RuleBasedIntentResolver, UnknownIntentError


class TieredIntentResolver(IntentResolver):
    def __init__(self, resolvers: Sequence[IntentResolver]) -> None:
        if not resolvers:
            raise ValueError("resolvers must not be empty")
        self._resolvers = tuple(resolvers)

    def resolve(self, purpose: str) -> tuple[str, ...]:
        last_error: UnknownIntentError | None = None
        for resolver in self._resolvers:
            try:
                return resolver.resolve(purpose)
            except UnknownIntentError as exc:
                last_error = exc
                continue
        raise UnknownIntentError(
            f"unsupported purpose: {purpose.strip()}"
        ) from last_error

    def learning_purpose(self, purpose: str, buttons: tuple[str, ...]) -> str:
        # Only a deterministic first tier can certify the name without another
        # LLM request or assumptions about which fallback produced the sequence.
        first = self._resolvers[0]
        if isinstance(first, RuleBasedIntentResolver):
            return first.learning_purpose(purpose, buttons)
        return purpose.strip()
