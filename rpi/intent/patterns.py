"""Configurable repeated-usage pattern detection."""

from datetime import date, datetime, timedelta

from .models import ExecutionMode, PatternCandidate, PatternConfig, UsageOutcome, UsageSource
from .ports import Clock, UsageLog


class PatternDetector:
    def __init__(self, usage_log: UsageLog, clock: Clock, config: PatternConfig) -> None:
        self._usage_log = usage_log
        self._clock = clock
        self._config = config

    def band_end(self, name: str, now: datetime) -> datetime | None:
        """현재 시간대의 끝. 자정을 넘는 시간대와 24시간 시간대도 지원."""
        band = next((b for b in self._config.time_bands if b.name == name), None)
        if band is None or not band.contains(now.timetz()):
            return None
        end = datetime.combine(now.date(), band.end.replace(tzinfo=None), now.tzinfo)
        if end <= now:
            end += timedelta(days=1)
        return end

    def band_start(self, name: str, now: datetime) -> datetime | None:
        band = next((b for b in self._config.time_bands if b.name == name), None)
        if band is None or not band.contains(now.timetz()):
            return None
        start = datetime.combine(now.date(), band.start.replace(tzinfo=None), now.tzinfo)
        if start > now:
            start -= timedelta(days=1)
        return start

    def candidates(self) -> tuple[PatternCandidate, ...]:
        now = self._clock.now()
        matching_bands = [
            band for band in self._config.time_bands if band.contains(now.timetz())
        ]
        if len(matching_bands) > 1:
            raise ValueError("configured time bands overlap at the current time")
        if not matching_bands:
            return ()

        return tuple(
            c for c in self._evidence(now)
            if c.time_band == matching_bands[0].name
            and c.occurrences >= self._config.minimum_occurrences
            and c.distinct_days >= self._config.minimum_days
        )

    def learning_status(self) -> dict:
        return {
            "window_days": self._config.window_days,
            "minimum_days": self._config.minimum_days,
            "minimum_occurrences": self._config.minimum_occurrences,
            "routines": [
                {
                    "purpose": c.purpose,
                    "appliance_id": c.appliance_id,
                    "time_band": c.time_band,
                    "occurrences": c.occurrences,
                    "distinct_days": c.distinct_days,
                    "established": (
                        c.distinct_days >= self._config.minimum_days
                        and c.occurrences >= self._config.minimum_occurrences
                    ),
                }
                for c in self._evidence(self._clock.now())
            ],
        }

    def _evidence(self, now: datetime) -> tuple[PatternCandidate, ...]:
        counts: dict[tuple[str, str | None, str], int] = {}
        days: dict[tuple[str, str | None, str], set[date]] = {}
        cutoff = now - timedelta(days=self._config.window_days)
        for record in self._usage_log.records():
            if (record.outcome is not UsageOutcome.SUCCEEDED
                    or record.execution_mode is not ExecutionMode.REAL
                    or record.source is not UsageSource.DIRECT):
                continue
            if not cutoff <= record.occurred_at <= now:
                continue
            local_record = record.occurred_at.astimezone(now.tzinfo)
            bands = [b for b in self._config.time_bands if b.contains(local_record.timetz())]
            # Ambiguous historical time bands cannot establish a habit.
            if len(bands) != 1:
                continue
            band = bands[0]
            key = (record.purpose.strip(), record.appliance_id, band.name)
            counts[key] = counts.get(key, 0) + 1
            day = local_record.date()
            start, end = band.start.replace(tzinfo=None), band.end.replace(tzinfo=None)
            if start > end and local_record.time() < end:
                day -= timedelta(days=1)
            days.setdefault(key, set()).add(day)

        return tuple(
            PatternCandidate(
                purpose, band, occurrences,
                appliance_id=appliance_id,
                distinct_days=len(days[(purpose, appliance_id, band)]),
                window_days=self._config.window_days,
            )
            for (purpose, appliance_id, band), occurrences in sorted(
                counts.items(), key=lambda item: (item[0][0], item[0][1] or "", item[0][2])
            )
        )
