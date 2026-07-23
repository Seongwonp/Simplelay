"""Production clock implementation; tests use the injected fixed clock."""

from datetime import datetime, timezone

from .ports import Clock


class SystemClock(Clock):
    def now(self) -> datetime:
        return datetime.now(timezone.utc).astimezone()
