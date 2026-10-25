"""Bounded lifecycle journal. System withdrawal is not user rejection."""
import logging
import threading
from collections import deque
from collections.abc import Callable
from dataclasses import asdict, dataclass
from datetime import datetime
from uuid import uuid4

from .models import ProactiveSuggestion

log = logging.getLogger(__name__)
EVENT_CAPACITY = 2000


@dataclass(frozen=True)
class SuggestionEvent:
    event_id: str
    occurred_at: str
    suggestion_id: str
    origin: str
    purpose: str
    time_band: str
    evidence: str
    occurrences: int
    appliance_id: str | None
    action: str
    reason: str
    job_id: str | None = None
    execution_status: str | None = None
    habit_time: str | None = None


class SuggestionFeedback:
    def __init__(self, load: Callable[[], list[dict]] | None = None,
                 save: Callable[[dict], None] | None = None):
        self._lock = threading.Lock()
        self._save = save
        self._persistence_ok = True
        self._events = deque(
            (SuggestionEvent(**entry) for entry in (load() if load else [])),
            maxlen=EVENT_CAPACITY,
        )

    def record(self, suggestion: ProactiveSuggestion, now: datetime,
               action: str, reason: str, *, job_id: str | None = None,
               execution_status: str | None = None) -> None:
        event = SuggestionEvent(
            uuid4().hex, now.isoformat(), suggestion.suggestion_id,
            "demo" if suggestion.time_band == "데모" or suggestion.is_demo else (
                "environment" if suggestion.time_band == "환경" else
                "advice" if getattr(suggestion, "kind", "action") == "advice" else "pattern"),
            suggestion.purpose, suggestion.time_band, suggestion.reason,
            suggestion.occurrences, suggestion.appliance_id, action, reason,
            job_id, execution_status, suggestion.habit_time,
        )
        with self._lock:
            self._events.append(event)
            if self._save:
                try:
                    self._save(asdict(event))
                except Exception:
                    # Feedback storage must not turn accepted motion into a
                    # failed response or undo a user's successful dismissal.
                    self._persistence_ok = False
                    log.exception("suggestion feedback persistence failed")

    def snapshot(self) -> tuple[SuggestionEvent, ...]:
        with self._lock:
            return tuple(self._events)

    def recent(self, limit: int = 100) -> dict:
        if not 1 <= limit <= 200:
            raise ValueError("limit must be between 1 and 200")
        with self._lock:
            return {
                "persistent": self._save is not None,
                "persistence_ok": self._persistence_ok,
                "capacity": EVENT_CAPACITY,
                "events": [asdict(event) for event in list(self._events)[-limit:][::-1]],
            }
