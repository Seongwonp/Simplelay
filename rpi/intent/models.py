"""Data models for usage learning and proactive suggestions."""

from dataclasses import dataclass
from datetime import datetime, time
from enum import Enum


class UsageOutcome(str, Enum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"


@dataclass(frozen=True)
class UsageRecord:
    occurred_at: datetime
    purpose: str
    outcome: UsageOutcome

    def __post_init__(self) -> None:
        if not self.purpose.strip():
            raise ValueError("purpose must not be blank")
        if self.occurred_at.tzinfo is None:
            raise ValueError("occurred_at must be timezone-aware")


@dataclass(frozen=True)
class TimeBand:
    """Configured local-time band; equal bounds represent the full day."""

    name: str
    start: time
    end: time

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise ValueError("time band name must not be blank")

    def contains(self, value: time) -> bool:
        local_time = value.replace(tzinfo=None)
        start = self.start.replace(tzinfo=None)
        end = self.end.replace(tzinfo=None)
        if start == end:
            return True
        if start < end:
            return start <= local_time < end
        return local_time >= start or local_time < end


@dataclass(frozen=True)
class PatternConfig:
    minimum_occurrences: int
    time_bands: tuple[TimeBand, ...]

    def __post_init__(self) -> None:
        if self.minimum_occurrences < 1:
            raise ValueError("minimum_occurrences must be at least 1")
        if not self.time_bands:
            raise ValueError("at least one time band is required")
        names = [band.name for band in self.time_bands]
        if len(names) != len(set(names)):
            raise ValueError("time band names must be unique")


@dataclass(frozen=True)
class PatternCandidate:
    purpose: str
    time_band: str
    occurrences: int


class SuggestionStatus(str, Enum):
    PENDING = "pending"
    APPROVED = "approved"


@dataclass(frozen=True)
class ProactiveSuggestion:
    suggestion_id: str
    purpose: str
    time_band: str
    occurrences: int
    created_at: datetime
    status: SuggestionStatus = SuggestionStatus.PENDING
    # 미리보기용. 승인 전 의도 해석이 실패했거나 리졸버가 주입되지 않았으면 빈 튜플 —
    # 실제 실행 시퀀스는 approve() 시점에 다시 해석되며 이 값과 다를 수 있다.
    steps: tuple[str, ...] = ()
    # 환경 기반(온습도) 제안 등에서 "왜 지금" 근거. 패턴 제안은 빈 문자열.
    reason: str = ""
