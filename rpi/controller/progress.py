"""Shares live execution progress between a controller and a status reader.

``ClosedLoopController.execute()`` runs synchronously and returns only once
the whole sequence finishes. To let something else (e.g. an HTTP /status
endpoint polled from a different thread while /execute runs via
``asyncio.to_thread``) observe progress *during* that run, the controller
writes into an ``ExecutionProgressTracker`` via its ``on_progress`` callback,
and the reader polls ``current()`` concurrently.
"""

import threading
from collections.abc import Callable

from .models import ExecutionProgress

ProgressCallback = Callable[[ExecutionProgress], None]


class ExecutionProgressTracker:
    """Thread-safe holder for the most recent in-flight execution progress."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._current: ExecutionProgress | None = None

    def update(self, progress: ExecutionProgress) -> None:
        with self._lock:
            self._current = progress

    def clear(self) -> None:
        with self._lock:
            self._current = None

    def current(self) -> ExecutionProgress | None:
        with self._lock:
            return self._current
