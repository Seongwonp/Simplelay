"""Explicitly fake verifier used without sensor hardware."""

from collections import deque
from collections.abc import Iterable

from .base import VerificationResult, Verifier


class MockVerifier(Verifier):
    """Return injected outcomes in order; this class never reads real sensors."""

    def __init__(self, outcomes: Iterable[VerificationResult | bool]) -> None:
        self._outcomes = deque(
            item
            if isinstance(item, VerificationResult)
            else VerificationResult(item, 1.0, "injected mock outcome")
            for item in outcomes
        )
        self.calls: list[str] = []

    def verify(self, button: str) -> VerificationResult:
        self.calls.append(button)
        if not self._outcomes:
            raise RuntimeError("MockVerifier scenario has no outcome left")
        return self._outcomes.popleft()
