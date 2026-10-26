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
    pause, reason = rest_pause(responses, now)
    shift = 0
    offsets = list(samples.values())
    if len(offsets) >= 3 and (all(v > 0 for v in offsets) or all(v < 0 for v in offsets)):
        shift = max(-30, min(30, int(median(offsets))))
    return (pause if reason is not None else None), shift, reason


#: 연달아 두 번 거절하거나 답이 없으면 그 습관을 쉬는 날 수(2026-10-26, 맡기기 신뢰 강화 — 예전 '거절 두 번 3일 쉼'·
#: '무시 두 번 하루 건너뜀'을 하나로). '이미 했어요'·예·나중에는 거절이 아니라 이어짐을 끊는다.
REST_DAYS = 7
#: 거절(아니요)과 무반응(답 없이 지나간 카드) — 이 둘만 이어 센다.
_NO_ANSWERS = ('dismissed', 'ignored')


def rest_pause(responses, now):
    """물은 날의 응답(날짜 → (시각, 응답))을 차례로 보고, 거절·무반응이 **연달아 두 번**이면 두 번째 응답 시각부터
    ``REST_DAYS``일 쉰다. 쉬기를 한 번 만든 두 응답은 다시 세지 않는다(쉬고 난 뒤 첫 거절 한 번으로 바로 또 쉬지 않는다).
    물을 수 있는 날만 묻기 때문에(평일 습관은 평일만) '연달아'는 달력 날짜가 아니라 물은 차례다.
    돌려주는 것: (쉬는 끝 시각, 이유) — 지금 쉬는 중이 아니면 (None, None)."""
    pause = None
    reason = None
    streak = []
    for _day, (at, action) in sorted(responses.items()):
        if action not in _NO_ANSWERS:
            streak = []
            continue
        streak.append(action)
        if len(streak) == 2:
            pause = at + timedelta(days=REST_DAYS)
            reason = 'consecutive_rejections' if streak == ['dismissed', 'dismissed'] else (
                'consecutive_ignores' if streak == ['ignored', 'ignored'] else 'consecutive_no_answers')
            streak = []
    if pause is None or now >= pause:
        return None, None
    return pause, reason


#: 공휴일 표(2026-10-26, 천문연 특일 정보) — ``(date) -> True | False | None``. None(모름)·없음이면 평일 규칙만.
_holiday_lookup = None


def set_holiday_lookup(lookup) -> None:
    """서버 기동이 공휴일 표를 붙인다(캐시만 읽는 함수여야 한다 — 판정 중 네트워크를 기다리지 않는다). None이면 뗀다."""
    global _holiday_lookup
    _holiday_lookup = lookup


def is_rest_day(day) -> bool:
    """토·일 또는 공휴일. 공휴일 표를 못 읽으면(인터넷 없음·모름) 토·일만."""
    if day.weekday() >= 5:
        return True
    lookup = _holiday_lookup
    if lookup is None:
        return False
    try:
        return lookup(day) is True
    except Exception:  # noqa: BLE001 -- 공휴일 표 실패는 평일 규칙으로
        return False


def day_matches(kind, day) -> bool:
    """평일 습관은 쉬는 날이 아닌 날(월~금, 공휴일 제외), 주말 습관은 쉬는 날(토·일·공휴일)만. 모르면(섞임·근거 적음) 모든 날."""
    if kind == 'weekday':
        return not is_rest_day(day)
    if kind == 'weekend':
        return is_rest_day(day)
    return True


def reason_time(candidate):
    if not candidate.confident or candidate.usual_time is None:
        return f'{candidate.time_band} 이맘때'
    hour = parse_time(candidate.usual_time) // 60
    label = ('밤 12시' if hour == 0 else '낮 12시' if hour == 12
             else f'오전 {hour}시' if hour < 12 else f'오후 {hour - 12}시')
    return f'{label}쯤'
