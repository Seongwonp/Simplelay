"""Circular clock statistics and response adaptation; no execution decisions."""
from datetime import datetime, timedelta
from statistics import median

DAY = 1440


def minute(at):
    return at.hour * 60 + at.minute


def parse_time(value):
    hour, minute_value = map(int, value.split(':'))
    return hour * 60 + minute_value


def clock_text(value):
    value = int(value) % DAY
    return f'{value // 60:02d}:{value % 60:02d}'


def distance(value, centre):
    return (value - centre + DAY // 2) % DAY - DAY // 2


def clusters(records):
    """Cut at the largest circular gap, then split gaps greater than 45 minutes."""
    ordered = sorted(records, key=lambda r: minute(r.occurred_at))
    if not ordered:
        return []
    values = [minute(r.occurred_at) for r in ordered]
    gaps = [(values[(i + 1) % len(values)] - v) % DAY for i, v in enumerate(values)]
    cut = max(range(len(gaps)), key=gaps.__getitem__) + 1
    ordered = ordered[cut:] + ordered[:cut]
    groups = [[]]
    offset = 0
    previous = minute(ordered[0].occurred_at)
    for record in ordered:
        current = minute(record.occurred_at)
        if current < previous:
            offset += DAY
        if groups[-1] and (current - previous) % DAY > 45:
            groups.append([])
        groups[-1].append((current + offset, record))
        previous = current
    # Each independent cluster owns its midnight wrap, not the ordering cut.
    return [[(value - (group[0][0] // DAY) * DAY, record) for value, record in group]
            for group in groups]


def adaptation(candidate, peers, events, records, now, lead):
    """Associate old journal entries by nearest centre, never by display band alone.

    A sample is one day's approval or direct use after an actual card was shown.
    Offsets are relative to the unshifted ask time, so polling cannot compound them.
    """
    centre = parse_time(candidate.usual_time)
    cutoff = now - timedelta(days=candidate.window_days)
    relevant = []
    for event in events:
        if (event.origin != 'pattern' or event.occurrences == 0 or event.purpose != candidate.purpose
                or event.appliance_id != candidate.appliance_id):
            continue
        at = datetime.fromisoformat(event.occurred_at).astimezone(now.tzinfo)
        if not cutoff <= at <= now:
            continue
        anchor = parse_time(event.habit_time) if event.habit_time else minute(at)
        nearest = min(peers, key=lambda c: abs(distance(anchor, parse_time(c.usual_time))))
        if nearest.usual_time != candidate.usual_time:
            continue
        if abs(distance(anchor, centre)) > 45 and not event.habit_time:
            continue
        relevant.append((at, event))
    relevant.sort(key=lambda item: item[0])
    responses = {}
    samples = {}
    created = {}
    for at, event in relevant:
        if event.action == 'created' and event.reason == 'habit_pattern':
            created[event.suggestion_id] = at
        if event.action in ('dismissed', 'snoozed', 'approval_requested', 'muted', 'already_done'):
            responses[at.date()] = (at, event.action)
        elif event.action == 'expired':
            # 답 없이 지나간 카드(무시) — 카드가 뜬 날로 센다(자정 넘어 내려가도 그날의 무시다).
            shown = created.get(event.suggestion_id, at)
            responses[shown.date()] = (shown, 'ignored')
        if event.action == 'approval_requested':
            samples[at.date()] = distance(minute(at), centre - lead)
    # Direct usage can answer a shown card without pressing its approval button.
    for shown in created.values():
        for record in records:
            at = record.occurred_at
            if shown <= at <= shown + timedelta(hours=2) and at <= now:
                samples.setdefault(at.date(), distance(minute(at), centre - lead))
                break
    pause = None
    previous = None
    for day, (at, action) in sorted(responses.items()):
        if (action == 'dismissed' and previous is not None
                and previous[1] == 'dismissed' and day - previous[0] == timedelta(days=1)):
            pause = at + timedelta(days=3)
        previous = day, action
    reason = 'consecutive_rejections' if pause is not None and now < pause else None
    ignore = ignore_pause(candidate, responses, now)
    if ignore is not None and reason is None:
        pause, reason = ignore, 'consecutive_ignores'
    shift = 0
    offsets = list(samples.values())
    if len(offsets) >= 3 and (all(v > 0 for v in offsets) or all(v < 0 for v in offsets)):
        shift = max(-30, min(30, int(median(offsets))))
    return (pause if reason is not None else None), shift, reason


def ignore_pause(candidate, responses, now):
    """답 없이 지나간 카드가 연달아 두 날이면(마지막 두 응답이 모두 무시) 다음 **물을 수 있는 날** 하루를 건너뛴다.

    그 다음 날은 다시 묻는다 — 또 무시하면 마지막 두 응답이 다시 무시라 또 하루 건너뛴다(하루걸러 묻기). 예·아니요·
    이미 했어요 같은 답이 한 번이라도 오면 마지막 응답이 무시가 아니라 바로 풀린다. 평일 습관이면 평일만, 주말
    습관이면 주말만 '물을 수 있는 날'로 센다(``day_kind``). 끝 시각(건너뛴 날의 다음 자정) 또는 None."""
    from .habit_words import day_kind  # noqa: PLC0415 -- habit_words가 이 모듈을 가져온다

    ordered = sorted(responses.items())
    if len(ordered) < 2 or ordered[-1][1][1] != 'ignored' or ordered[-2][1][1] != 'ignored':
        return None
    kind = day_kind(candidate.recent_days)
    skip = ordered[-1][0] + timedelta(days=1)
    while not day_matches(kind, skip):
        skip += timedelta(days=1)
    until = datetime.combine(skip + timedelta(days=1), datetime.min.time(), now.tzinfo)
    return until if now < until else None


def day_matches(kind, day) -> bool:
    """평일 습관은 월~금, 주말 습관은 토·일만. 모르면(섞임·근거 적음) 모든 날."""
    if kind == 'weekday':
        return day.weekday() < 5
    if kind == 'weekend':
        return day.weekday() >= 5
    return True


def reason_time(candidate):
    if not candidate.confident or candidate.usual_time is None:
        return f'{candidate.time_band} 이맘때'
    hour = parse_time(candidate.usual_time) // 60
    label = ('밤 12시' if hour == 0 else '낮 12시' if hour == 12
             else f'오전 {hour}시' if hour < 12 else f'오후 {hour - 12}시')
    return f'{label}쯤'
