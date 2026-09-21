"""Recent real, direct completions; separate from habit-learning records."""
import json
import threading
from collections.abc import Callable
from datetime import datetime, timedelta


class CompletedActions:
    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None) -> None:
        self._lock = threading.Lock()
        self._save = save
        raw = load() if load else None
        self._entries = {
            key: datetime.fromisoformat(value)
            for key, value in (json.loads(raw) if raw else {}).items()
        }
        if any(t.tzinfo is None for t in self._entries.values()):
            raise ValueError("completion timestamps must be timezone-aware")

    def remember(self, appliance_id: str | None, purpose: str | None,
                 buttons: tuple[str, ...], now: datetime) -> None:
        if appliance_id is None:
            return
        key = json.dumps([appliance_id, purpose, list(buttons)], ensure_ascii=False)
        with self._lock:
            self._entries = {k: t for k, t in self._entries.items()
                             if t >= now - timedelta(days=2)}
            self._entries[key] = now
            # A persistence failure must not undo knowledge of physical success.
            if self._save:
                self._save(json.dumps({k: t.isoformat() for k, t in self._entries.items()}))

    def contains(self, appliance_id: str | None, purpose: str,
                 buttons: tuple[str, ...], since: datetime, now: datetime,
                 *, include_since: bool = True) -> bool:
        if appliance_id is None:
            return False
        with self._lock:
            for key, completed_at in self._entries.items():
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
