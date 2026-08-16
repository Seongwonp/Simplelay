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
from .rules import UnknownIntentError


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
