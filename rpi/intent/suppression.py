"""사용자가 "다시 추천 안 함"으로 내린 루틴을 담는 억제 목록.

패턴 감지가 후보를 만들 때 여기 든 purpose는 건너뛴다 -- "제안하는 것"만큼
"싫다는 걸 기억하고 존중하는 것"도 공감지능의 일부다. 오프라인 우선:
DB 경로가 없으면 인메모리, 있으면 SQLite 구현으로 교체된다(persistence.py).
"""

from __future__ import annotations

import threading

from .ports import SuppressionStore


class InMemorySuppressionStore(SuppressionStore):
    """SuppressionStore 포트의 인메모리 구현(개발 PC·테스트 기본)."""

    def __init__(self) -> None:
        self._muted: set[str] = set()
        self._lock = threading.Lock()

    def mute(self, purpose: str) -> None:
        with self._lock:
            self._muted.add(purpose.strip())

    def unmute(self, purpose: str) -> None:
        with self._lock:
            self._muted.discard(purpose.strip())

    def muted(self) -> frozenset[str]:
        with self._lock:
            return frozenset(self._muted)
