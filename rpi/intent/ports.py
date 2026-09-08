"""Dependency-injection ports for pattern learning and intent resolution."""

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


class SuppressionStore(ABC):
    """사용자가 "다시 추천 안 함"한 루틴을 담는 억제 목록."""

    @abstractmethod
    def mute(self, purpose: str) -> None:
        """이 루틴을 다시 제안하지 않도록 억제한다."""

    @abstractmethod
    def unmute(self, purpose: str) -> None:
        """억제 해제 -- 다시 제안 대상이 된다."""

    @abstractmethod
    def muted(self) -> frozenset[str]:
        """현재 억제된 purpose 집합."""


class PurposeExecutor(ABC):
    @abstractmethod
    def execute_purpose(
        self, purpose: str, appliance_id: str | None = None
    ) -> object:
        """Execute an approved purpose through the normal intent path."""


class LlmClient(ABC):
    @abstractmethod
    def complete(self, purpose: str, known_buttons: tuple[str, ...]) -> str:
        """Return raw model output (expected to be JSON) for the given purpose."""
