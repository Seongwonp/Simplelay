"""Dependency-injection ports for M4 pattern learning."""

from abc import ABC, abstractmethod
from datetime import datetime

from .models import UsageRecord


class Clock(ABC):
    @abstractmethod
    def now(self) -> datetime:
        """Return the current timezone-aware instant."""


class UsageLog(ABC):
    @abstractmethod
    def append(self, record: UsageRecord) -> None:
        """Persist one completed usage record."""

    @abstractmethod
    def records(self) -> tuple[UsageRecord, ...]:
        """Return usage records available to the pattern detector."""


class PurposeExecutor(ABC):
    @abstractmethod
    def execute_purpose(self, purpose: str) -> object:
        """Execute an approved purpose through the normal intent path."""
