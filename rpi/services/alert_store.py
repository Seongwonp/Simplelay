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

    def __init__(self, clock: Clock, care_events=None) -> None:
        self._clock = clock
        self._care_events = care_events
        self._lock = threading.Lock()
        self._state = DangerAlertState(active=False)

    #: 위험 소리가 아닌 alert 종류 — 콘센트 모듈 비상정지는 ``/status.estop_latched``로 따로 보인다.
    #: 여기서 받으면 '위험할 수 있는 신호음' 경보·보호자 알림으로 잘못 보였다(2026-10-06).
    NOT_DANGER_KINDS = frozenset({"outlet_estop"})

    def record(self, event: AlertEvent) -> None:
        if event.kind in self.NOT_DANGER_KINDS:
            return
        with self._lock:
            # rising edge 판정과 상태 갱신만 락 안에서 — care append는
            # SQLite commit(블로킹 I/O)이라 락 안에서 하면 current()와
            # 경보 SSE 반영은 디스크 쓰기가 끝날 때까지 기다린다.
            rising = event.raised and not self._state.active
            self._state = DangerAlertState(
                active=event.raised,
                kind=event.kind,
                band_energy_ratio=event.band_energy_ratio,
                mean_period_seconds=event.mean_period_seconds,
                updated_at=self._clock.now(),
            )
        if rising and self._care_events is not None:
            try:
                self._care_events.append(
                    "danger_sound",
                    "위험할 수 있는 신호음이 감지되었어요. 안부를 확인해 주세요.",
                )
            except Exception:  # 알림 실패가 경보 기록을 막으면 안 된다
                pass

    def current(self) -> DangerAlertState:
        with self._lock:
            return self._state
