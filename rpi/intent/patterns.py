"""Configurable repeated-usage pattern detection."""

from .models import PatternCandidate, PatternConfig, UsageOutcome
from .ports import Clock, UsageLog


class PatternDetector:
    def __init__(self, usage_log: UsageLog, clock: Clock, config: PatternConfig) -> None:
        self._usage_log = usage_log
        self._clock = clock
        self._config = config

    def candidates(self) -> tuple[PatternCandidate, ...]:
        now = self._clock.now()
        matching_bands = [
            band for band in self._config.time_bands if band.contains(now.timetz())
        ]
        if len(matching_bands) > 1:
            raise ValueError("configured time bands overlap at the current time")
        if not matching_bands:
            return ()

        active_band = matching_bands[0]
        counts: dict[str, int] = {}
        for record in self._usage_log.records():
            if record.outcome is not UsageOutcome.SUCCEEDED:
                continue
            local_record = record.occurred_at.astimezone(now.tzinfo)
            if active_band.contains(local_record.timetz()):
                purpose = record.purpose.strip()
                counts[purpose] = counts.get(purpose, 0) + 1

        return tuple(
            PatternCandidate(purpose, active_band.name, occurrences)
            for purpose, occurrences in sorted(counts.items())
            if occurrences >= self._config.minimum_occurrences
        )
