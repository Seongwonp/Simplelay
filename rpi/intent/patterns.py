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

        band = matching_bands[0]
        counts, days, minutes = self._tally(now)
        lead = self._config.ask_lead_minutes
        now_minute = now.hour * 60 + now.minute
        start, end = band.start.replace(tzinfo=None), band.end.replace(tzinfo=None)
        if start > end and now.time().replace(tzinfo=None) < end:
            now_minute += 24 * 60  # 자정을 넘는 시간대 — 기록과 같은 축(_tally)으로 잰다

        def due(c) -> bool:
            if lead is None:
                return True
            values = sorted(minutes[(c.purpose, c.appliance_id, c.time_band)])
            usual = values[(len(values) - 1) // 2]
            return now_minute >= usual - lead

        return tuple(
            c for c in self._candidates_from(counts, days)
            if c.time_band == band.name
            and c.occurrences >= self._config.minimum_occurrences
            and c.distinct_days >= self._config.minimum_days
            and due(c)
        )

    def learning_status(self) -> dict:
        now = self._clock.now()
        counts, days, _ = self._tally(now)
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
                    # 왜 습관인지 보이는 근거 — 실제로 쓴 날(최근 5일, 오래된 날부터)(2026-10-25, 가이드라인 '이유 설명').
                    "recent_days": [
                        d.isoformat()
                        for d in sorted(days[(c.purpose, c.appliance_id, c.time_band)])[-5:]
                    ],
                }
                for c in self._candidates_from(counts, days)
            ],
        }

    def established(self) -> tuple[tuple[PatternCandidate, str], ...]:
        """모든 시간대에서 성립한 후보와 대표 시각("HH:MM") — 루틴 초안용(2026-10-14).

        근거는 ``candidates``와 같다(성공·실제 실행·직접 사용만). 대표 시각은 그 기록들의
        시각 중앙값을 5분 단위로 내린 값이다. 자정을 넘는 시간대는 넘긴 쪽 시각을 뒤로 이어 센다.
        """
        now = self._clock.now()
        counts, days, minutes = self._tally(now)
        result = []
        for candidate in self._candidates_from(counts, days):
            if (candidate.occurrences < self._config.minimum_occurrences
                    or candidate.distinct_days < self._config.minimum_days):
                continue
            values = sorted(minutes[(candidate.purpose, candidate.appliance_id, candidate.time_band)])
            middle = values[(len(values) - 1) // 2] % (24 * 60)
            middle -= middle % 5
            result.append((candidate, f"{middle // 60:02d}:{middle % 60:02d}"))
        return tuple(result)

    def _evidence(self, now: datetime) -> tuple[PatternCandidate, ...]:
        counts, days, _ = self._tally(now)
        return self._candidates_from(counts, days)

    def _tally(self, now: datetime):
        counts: dict[tuple[str, str | None, str], int] = {}
        days: dict[tuple[str, str | None, str], set[date]] = {}
        minutes: dict[tuple[str, str | None, str], list[int]] = {}
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
            minute = local_record.hour * 60 + local_record.minute
            start, end = band.start.replace(tzinfo=None), band.end.replace(tzinfo=None)
            if start > end and local_record.time() < end:
                day -= timedelta(days=1)
                minute += 24 * 60
            days.setdefault(key, set()).add(day)
            minutes.setdefault(key, []).append(minute)
        return counts, days, minutes

    def _candidates_from(self, counts, days) -> tuple[PatternCandidate, ...]:
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
