"""Deterministic M4 test doubles."""

from datetime import datetime

from .ports import Clock, PurposeExecutor


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
