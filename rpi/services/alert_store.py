"""Holds the most recent danger-sound alert state so an HTTP endpoint can
expose what ActClient's on_alert callback receives -- alerts are edge-
triggered pushes from RPi4 (see rpi4/services/act_executor.py), not
something a poller can ask for on demand, so something has to remember the
last one between polls.

Only tracks the single latest state, not a history -- there is realistically
only ever one "current" danger condition at a time (an edge-triggered
raise/clear pair), unlike ProactiveSuggestionService's multiple pending
suggestions.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from datetime import datetime

from rpi.intent.ports import Clock

from .act_client import AlertEvent


@dataclass(frozen=True)
class DangerAlertState:
    active: bool
    kind: str | None = None
    band_energy_ratio: float | None = None
    mean_period_seconds: float | None = None
    updated_at: datetime | None = None


class DangerAlertStore:
    """Thread-safe -- record() is called from the ActClient background read
    loop's thread (see ActClientController), current() from FastAPI request
    handlers on a different thread."""

    def __init__(self, clock: Clock) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._state = DangerAlertState(active=False)

    def record(self, event: AlertEvent) -> None:
        with self._lock:
            self._state = DangerAlertState(
                active=event.raised,
                kind=event.kind,
                band_energy_ratio=event.band_energy_ratio,
                mean_period_seconds=event.mean_period_seconds,
                updated_at=self._clock.now(),
            )

    def current(self) -> DangerAlertState:
        with self._lock:
            return self._state
