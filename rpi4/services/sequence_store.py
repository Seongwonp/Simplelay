"""In-memory store for sequences awaiting user confirmation.

A sequence is born when RPi4 resolves an intent and sends a ``sequence``
message to ESP32.  It lives here until the user approves or rejects it
(via a ``confirm`` message) or until an ``abort`` wipes everything.

asyncio.Lock keeps access safe across concurrent handlers.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass


@dataclass(frozen=True)
class PendingSequence:
    label: str
    buttons: tuple[str, ...]


class SequenceStore:
    def __init__(self) -> None:
        self._store: dict[str, PendingSequence] = {}
        self._lock = asyncio.Lock()

    async def put(self, seq_id: str, label: str, buttons: tuple[str, ...]) -> None:
        """Insert or overwrite a pending sequence."""
        async with self._lock:
            self._store[seq_id] = PendingSequence(label=label, buttons=buttons)

    async def pop(self, seq_id: str) -> PendingSequence | None:
        """Remove and return a pending sequence, or None if not found."""
        async with self._lock:
            return self._store.pop(seq_id, None)

    async def clear(self) -> None:
        """Remove all pending sequences (called on abort)."""
        async with self._lock:
            self._store.clear()

    async def size(self) -> int:
        async with self._lock:
            return len(self._store)
