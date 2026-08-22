"""실행(job) 이력 — "무엇을·언제·몇 번 재시도해서·어떻게 끝났는지"의 기록.

두 가지 목적:
1. 사용자에게 공감지능의 근거를 보여준다 — 패턴 학습이 어떤 이력에서
   나오는지, 폐루프가 실제로 몇 번 재시도로 회복했는지(앱 타임라인 화면).
2. 발표용 실험 데이터의 축적 기반 — 실기기 검증 기간의 성공률·재시도
   횟수 통계를 여기서 뽑는다.

저장은 UsageLog와 같은 패턴: SIMPLELAY_DB_PATH가 있으면 SQLite
(persistence.SqliteJobHistory), 없으면 인메모리(개발·테스트).
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol


@dataclass(frozen=True)
class ButtonAttempt:
    button: str
    success: bool
    attempts: int


@dataclass(frozen=True)
class JobHistoryEntry:
    job_id: str
    finished_at: datetime
    purpose: str | None  # 버튼 직접 실행(수동 조작)은 목적 문자열이 없다
    status: str  # succeeded | safety_stopped | failed
    buttons: tuple[ButtonAttempt, ...]

    @property
    def retry_count(self) -> int:
        """전체 재시도 횟수 — 폐루프가 회복을 위해 추가로 누른 횟수의 합."""
        return sum(max(0, b.attempts - 1) for b in self.buttons)


class JobHistoryStore(Protocol):
    def append(self, entry: JobHistoryEntry) -> None: ...

    def recent(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]: ...


class InMemoryJobHistory:
    """개발·테스트용 — 프로세스 메모리에 최근 N건만 유지."""

    def __init__(self, max_entries: int = 200) -> None:
        self._lock = threading.Lock()
        self._entries: deque[JobHistoryEntry] = deque(maxlen=max_entries)

    def append(self, entry: JobHistoryEntry) -> None:
        with self._lock:
            self._entries.append(entry)

    def recent(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]:
        with self._lock:
            items = list(self._entries)
        return tuple(reversed(items))[:limit]  # 최신순
