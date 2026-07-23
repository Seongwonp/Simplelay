"""Usage log implementations."""

from .models import UsageRecord
from .ports import UsageLog


class InMemoryUsageLog(UsageLog):
    """Process-local software implementation; it does not write to a database."""

    def __init__(self, initial: tuple[UsageRecord, ...] = ()) -> None:
        self._records = list(initial)

    def append(self, record: UsageRecord) -> None:
        self._records.append(record)

    def records(self) -> tuple[UsageRecord, ...]:
        return tuple(self._records)
