"""휴대폰에서 알아들은 말의 확인 질문을 키오스크와 나눈다(2026-10-26).

POST /intent/understand가 알아들으면(understood=true) 그 제안을 60초 동안 메모리에 둔다.
키오스크·폰 어느 쪽이든 먼저 '네'·'아니요'를 고른 쪽이 이긴다(원자적 소비, 두 번째는 409).
**여기서는 아무것도 실행하지 않는다** — 이긴 클라이언트가 돌려받은 동작을 기존 실행 경로로 보낸다.
"""

from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

PENDING = "pending"
YES = "yes"
NO = "no"

TTL_S = 60.0
MAX_PENDING = 20


@dataclass
class IntentProposal:
    id: str
    question: str
    label: str
    action: dict[str, Any]
    created_at: float  # epoch 초(표시용)
    expires_mono: float
    state: str = PENDING
    resolved_at: float | None = field(default=None)


class ProposalConflict(Exception):
    """이미 정해졌거나 시간이 지났다."""


class IntentProposalStore:
    def __init__(self, ttl_s: float = TTL_S, now: Callable[[], float] = time.monotonic,
                 wall: Callable[[], float] = time.time) -> None:
        self.ttl_s = ttl_s
        self._now = now
        self._wall = wall
        self._lock = threading.Lock()
        self._items: dict[str, IntentProposal] = {}

    def _expired(self, p: IntentProposal, t: float) -> bool:
        return t >= p.expires_mono

    def _prune(self, t: float) -> None:
        # 정해진 것도 TTL 동안은 남겨 둔다 — 폰이 '키오스크에서 이미 정했어요'를 알 수 있게.
        for pid in [pid for pid, p in self._items.items() if t >= p.expires_mono + self.ttl_s]:
            del self._items[pid]

    def add(self, question: str, label: str, action: dict[str, Any]) -> IntentProposal:
        t = self._now()
        p = IntentProposal(id=uuid.uuid4().hex, question=question, label=label, action=dict(action),
                           created_at=self._wall(), expires_mono=t + self.ttl_s)
        with self._lock:
            self._prune(t)
            # 새로 알아들은 말이 앞의 미결 질문을 대신한다 — 화면에 질문은 하나만.
            for old in self._items.values():
                if old.state == PENDING and not self._expired(old, t):
                    old.state = "replaced"
            while len(self._items) >= MAX_PENDING:
                del self._items[next(iter(self._items))]
            self._items[p.id] = p
        return p

    def pending(self) -> list[IntentProposal]:
        t = self._now()
        with self._lock:
            self._prune(t)
            return [p for p in self._items.values() if p.state == PENDING and not self._expired(p, t)]

    def get(self, pid: str) -> IntentProposal | None:
        t = self._now()
        with self._lock:
            self._prune(t)
            p = self._items.get(pid)
            if p is not None and p.state == PENDING and self._expired(p, t):
                p.state = "expired"
            return p

    def resolve(self, pid: str, result: str) -> IntentProposal:
        """pending → yes/no 한 번만. 없으면 KeyError, 이미 정해졌거나 만료면 ProposalConflict."""
        if result not in (YES, NO):
            raise ValueError(result)
        t = self._now()
        with self._lock:
            p = self._items.get(pid)
            if p is None:
                raise KeyError(pid)
            if p.state == PENDING and self._expired(p, t):
                p.state = "expired"
            if p.state != PENDING:
                raise ProposalConflict(p.state)
            p.state = result
            p.resolved_at = self._wall()
            return p


_store = IntentProposalStore()


def get_proposal_store() -> IntentProposalStore:
    return _store
