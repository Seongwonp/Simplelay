"""Deterministic test doubles for intent resolution and M4 pattern learning."""

from collections.abc import Mapping, Sequence
from datetime import datetime

from .dbus_vectordb import SearchResult
from .ports import Clock, LlmClient, PurposeExecutor


class FixedClock(Clock):
    """Injected clock whose value changes only when the test sets it."""

    def __init__(self, current: datetime) -> None:
        self.set(current)

    def set(self, current: datetime) -> None:
        if current.tzinfo is None:
            raise ValueError("FixedClock requires a timezone-aware datetime")
        self._current = current

    def now(self) -> datetime:
        return self._current


class MockPurposeExecutor(PurposeExecutor):
    """Records approvals without invoking the real closed-loop controller."""

    def __init__(self, result: object = None) -> None:
        self.result = result
        self.purposes: list[str] = []

    def execute_purpose(self, purpose: str) -> object:
        self.purposes.append(purpose)
        return self.result


class MockLlmClient(LlmClient):
    """Deterministic LLM double: canned raw responses keyed by purpose."""

    def __init__(
        self,
        responses: Mapping[str, str] | None = None,
        error: Exception | None = None,
    ) -> None:
        self._responses = dict(responses or {})
        self._error = error
        self.calls: list[tuple[str, tuple[str, ...]]] = []

    def complete(self, purpose: str, known_buttons: tuple[str, ...]) -> str:
        self.calls.append((purpose, known_buttons))
        if self._error is not None:
            raise self._error
        try:
            return self._responses[purpose]
        except KeyError as exc:
            raise LookupError(f"no mock LLM response configured for {purpose!r}") from exc


class FakeVectordbClient:
    """Deterministic VectordbSearcher double: canned search results keyed
    by purpose text -- no subprocess/D-Bus involved."""

    def __init__(self, results: Mapping[str, Sequence[SearchResult]] | None = None) -> None:
        self._results = dict(results or {})
        self.calls: list[tuple[str, int]] = []

    def search_text(self, input_text: str, top_k: int = 1) -> list[SearchResult]:
        self.calls.append((input_text, top_k))
        return list(self._results.get(input_text, []))
