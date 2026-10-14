"""Recent real, direct completions; separate from habit-learning records."""
import json
import threading
from collections.abc import Callable
from datetime import datetime, timedelta
from types import MappingProxyType


class CompletedActions:
    """제안 승인 게이트(서비스 잠금 안)가 ``contains``를 읽는다 — 읽기는 잠금 없이 불변 사본을, 기록은 메모리에 먼저 넣고
    DB 쓰기는 따로(2026-10-14 HIGH 재확인: 다른 실행의 완료 기록이 DB에서 멈춘 동안 정지가 서비스 잠금에서 막히지 않게)."""

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None) -> None:
        self._lock = threading.Lock()
        self._persist_lock = threading.Lock()
        self._save = save
        self._version = 0
        self._persisted_version = 0
        raw = load() if load else None
        entries = {
            key: datetime.fromisoformat(value)
            for key, value in (json.loads(raw) if raw else {}).items()
        }
        if any(t.tzinfo is None for t in entries.values()):
            raise ValueError("completion timestamps must be timezone-aware")
        self._entries = MappingProxyType(entries)

    def remember(self, appliance_id: str | None, purpose: str | None,
                 buttons: tuple[str, ...], now: datetime) -> None:
        if appliance_id is None:
            return
        key = json.dumps([appliance_id, purpose, list(buttons)], ensure_ascii=False)
        with self._lock:
            entries = {k: t for k, t in self._entries.items()
                       if t >= now - timedelta(days=2)}
            entries[key] = now
            self._entries = MappingProxyType(entries)
            self._version += 1
        # A persistence failure must not undo knowledge of physical success.
        if self._save:
            with self._persist_lock:
                with self._lock:
                    entries, version = self._entries, self._version
                if version > self._persisted_version:
                    self._save(json.dumps({k: t.isoformat() for k, t in entries.items()}))
                    self._persisted_version = version

    def contains(self, appliance_id: str | None, purpose: str,
                 buttons: tuple[str, ...], since: datetime, now: datetime,
                 *, include_since: bool = True) -> bool:
        if appliance_id is None:
            return False
        for key, completed_at in self._entries.items():  # 불변 사본 — 잠금 없음
            if (not since <= completed_at <= now
                    or (not include_since and completed_at == since)):
                continue
            target, completed_purpose, completed_buttons = json.loads(key)
            if target != appliance_id:
                continue
            if completed_purpose == purpose:
                return True
            # Only a whole unnamed manual sequence can match by buttons.
            # Do not pool partial button runs or infer a habit from them.
            if (completed_purpose is None and buttons
                    and tuple(completed_buttons) == tuple(buttons)):
                return True
        return False
