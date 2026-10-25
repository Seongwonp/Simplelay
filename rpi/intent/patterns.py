"""Repeated real usage grouped by proximity on a circular daily clock."""

from dataclasses import asdict, replace
from datetime import datetime, time, timedelta
from statistics import median

from .habit_timing import adaptation, clock_text, clusters, distance, minute, parse_time
from .models import ExecutionMode, PatternCandidate, PatternConfig, UsageOutcome, UsageSource
from .ports import Clock, UsageLog


class PatternDetector:
    def __init__(self, usage_log: UsageLog, clock: Clock, config: PatternConfig) -> None:
        self._usage_log = usage_log
        self._clock = clock
        self._config = config
        self._feedback = None

    def set_feedback(self, feedback) -> None:
        self._feedback = feedback

    def band_end(self, name: str, now: datetime) -> datetime | None:
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

    def _is_established(self, candidate):
        return (candidate.occurrences >= self._config.minimum_occurrences
                and candidate.distinct_days >= self._config.minimum_days)

    def candidates(self) -> tuple[PatternCandidate, ...]:
        now = self._clock.now()
        if sum(b.contains(now.timetz()) for b in self._config.time_bands) > 1:
            raise ValueError('configured time bands overlap at the current time')
        result = []
        for candidate in self._evidence(now):
            if not self._is_established(candidate) or candidate.paused_until:
                continue
            bounds = self.ask_window(candidate, now)
            if bounds is not None and bounds[0] <= now < bounds[1]:
                result.append(replace(candidate, available_from=bounds[0], available_until=bounds[1]))
        return tuple(result)

    def ask_window(self, candidate, now):
        # Explicit legacy configuration keeps full-band availability for confident habits.
        if self._config.ask_lead_minutes is None and candidate.confident:
            start = self.band_start(candidate.time_band, now)
            end = self.band_end(candidate.time_band, now)
            return (start, end) if start is not None and end is not None else None
        centre = parse_time(candidate.usual_time)
        anchor = now.replace(second=0, microsecond=0) - timedelta(minutes=distance(minute(now), centre))
        start = anchor + timedelta(minutes=distance(parse_time(candidate.ask_time), centre))
        first = -((centre - parse_time(candidate.window_start)) % 1440)
        last = first + (parse_time(candidate.window_end) - parse_time(candidate.window_start)) % 1440
        if not candidate.confident:
            start = anchor + timedelta(minutes=first + max(0, candidate.ask_shift_minutes))
        # A confident card retains a short response opportunity, including across midnight.
        end = anchor + timedelta(minutes=max(last, 30) + 1 if candidate.confident else last + 1)
        return start, end

    def learning_status(self) -> dict:
        routines = []
        for candidate in self._evidence(self._clock.now()):
            entry = asdict(candidate)
            entry.pop('available_until')
            entry.pop('available_from')
            entry['recent_days'] = list(candidate.recent_days[-5:])
            entry['paused_until'] = candidate.paused_until.isoformat() if candidate.paused_until else None
            entry['established'] = self._is_established(candidate)
            routines.append(entry)
        return dict(window_days=self._config.window_days, minimum_days=self._config.minimum_days,
                    minimum_occurrences=self._config.minimum_occurrences, routines=routines)

    def established(self) -> tuple[tuple[PatternCandidate, str], ...]:
        # Routine drafts retain their existing five-minute rounding convention.
        return tuple((c, clock_text(parse_time(c.usual_time) // 5 * 5))
                     for c in self._evidence(self._clock.now()) if self._is_established(c))

    def _evidence(self, now: datetime) -> tuple[PatternCandidate, ...]:
        cutoff = now - timedelta(days=self._config.window_days)
        grouped = {}
        for record in self._usage_log.records():
            if (record.outcome is not UsageOutcome.SUCCEEDED
                    or record.execution_mode is not ExecutionMode.REAL
                    or record.source is not UsageSource.DIRECT
                    or not cutoff <= record.occurred_at <= now):
                continue
            local = replace(record, occurred_at=record.occurred_at.astimezone(now.tzinfo))
            grouped.setdefault((record.purpose.strip(), record.appliance_id), []).append(local)
        result = []
        events = self._feedback.snapshot() if self._feedback else ()
        for (purpose, appliance), records in sorted(grouped.items(), key=lambda item: (item[0][0], item[0][1] or '')):
            peers = []
            cluster_records = {}
            for group in clusters(records):
                values = [value for value, _ in group]
                # Minimize circular absolute deviation; lower unwrapped value breaks ties.
                centre = min(sorted(set(values)), key=lambda c: sum(abs(distance(v, c)) for v in values))
                spread = float(median(abs(distance(value, centre)) for value in values))
                cluster_records[clock_text(centre)] = sorted(
                    (r for _, r in group), key=lambda r: r.occurred_at)
                bands = [b for b in self._config.time_bands if b.contains(time((centre % 1440) // 60, centre % 60))]
                if len(bands) != 1:
                    continue
                # Records after midnight in a wrapping cluster belong to the preceding habit day.
                days = sorted({(r.occurred_at.date() - timedelta(days=v // 1440))
                               for v, r in group})
                confident = spread <= 30
                ask = centre - (self._config.ask_lead_minutes or 0) if confident else values[0]
                peers.append(PatternCandidate(
                    purpose, bands[0].name, len(group), appliance, len(days), self._config.window_days,
                    usual_time=clock_text(centre), spread_minutes=spread,
                    window_start=clock_text(values[0]), window_end=clock_text(values[-1]),
                    confident=confident, ask_time=clock_text(ask),
                    recent_days=tuple(d.isoformat() for d in days)))
            for candidate in peers:
                pause, shift = adaptation(candidate, peers, events, cluster_records[candidate.usual_time],
                                          now, self._config.ask_lead_minutes or 0)
                ask = parse_time(candidate.ask_time)
                # Uncertain habits never move outside their observed window.
                if candidate.confident:
                    ask += shift
                else:
                    width = (parse_time(candidate.window_end) - ask) % 1440
                    ask += max(0, min(width, shift))
                result.append(replace(candidate, paused_until=pause,
                                      pause_reason='consecutive_rejections' if pause else None,
                                      ask_shift_minutes=shift, ask_time=clock_text(ask)))
        return tuple(result)
