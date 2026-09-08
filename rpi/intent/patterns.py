"""Configurable repeated-usage pattern detection."""

from datetime import datetime

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
        # 목적별 '가장 최근' 실행의 가전. 같은 루틴을 다른 가전으로 옮겨
        # 쓰기 시작했다면 사용자가 뜻하는 대상은 최신 쪽이다. 최빈값이
        # 아니라 최신을 쓰는 이유이며, 가전 없이 쌓인 옛 기록은 건너뛴다.
        latest: dict[str, tuple[datetime, str]] = {}
        for record in self._usage_log.records():
            if record.outcome is not UsageOutcome.SUCCEEDED:
                continue
            local_record = record.occurred_at.astimezone(now.tzinfo)
            if active_band.contains(local_record.timetz()):
                purpose = record.purpose.strip()
                counts[purpose] = counts.get(purpose, 0) + 1
                if record.appliance_id is not None:
                    seen = latest.get(purpose)
                    if seen is None or record.occurred_at >= seen[0]:
                        latest[purpose] = (
                            record.occurred_at,
                            record.appliance_id,
                        )

        return tuple(
            PatternCandidate(
                purpose,
                active_band.name,
                occurrences,
                appliance_id=(
                    latest[purpose][1] if purpose in latest else None
                ),
            )
            for purpose, occurrences in sorted(counts.items())
            if occurrences >= self._config.minimum_occurrences
        )
