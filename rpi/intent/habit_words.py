"""습관을 사람에게 보여 줄 때 쓰는 말(2026-10-26 — '알게 된 것' 화면과 밤 정리 문장이 같은 표현을 쓴다).

여기의 문장은 학습 기록에서 나온 값만 쓴다(가전 이름처럼 사용자가 적은 글은 넣지 않는다).
"""

from datetime import date, timedelta

from .habit_timing import is_rest_day, parse_time

#: 시간대 이름을 말로 읽을 때(‘야간 이맘때’보다 ‘밤 이맘때’가 자연스럽다).
_BAND_WORDS = {'야간': '밤'}


def korean_clock(value: str) -> str:
    """'22:00' → '오후 10시', '07:05' → '오전 7시 5분', '00:30' → '밤 12시 30분', '12:00' → '낮 12시'."""
    total = parse_time(value) % 1440
    hour, minute = divmod(total, 60)
    if hour == 0:
        text = '밤 12시'
    elif hour < 12:
        text = f'오전 {hour}시'
    elif hour == 12:
        text = '낮 12시'
    else:
        text = f'오후 {hour - 12}시'
    return f'{text} {minute}분' if minute else text


def day_kind(days) -> str | None:
    """쓴 날이 모두 평일이면 'weekday', 모두 주말(토·일·공휴일)이면 'weekend', 섞였거나 근거가 적으면(3일 미만) None.

    첫날~마지막 날 사이에 쓸 수 있었는데 안 쓴 다른 종류의 날이 있어야 그렇게 본다(2026-10-26) — 월·화·수 사흘만
    쓴 매일 습관을 '평일'로 잘못 읽지 않도록, 주말을 한 번도 지나지 않았으면 None(매일)."""
    parsed = []
    for value in days:
        try:
            parsed.append(date.fromisoformat(value))
        except (TypeError, ValueError):
            return None
    if len(parsed) < 3:
        return None
    rest = [is_rest_day(d) for d in parsed]  # 공휴일은 주말처럼(2026-10-26)
    if any(rest) and not all(rest):
        return None
    first = min(parsed)
    span = [is_rest_day(first + timedelta(days=i)) for i in range((max(parsed) - first).days + 1)]
    if not any(rest):
        return 'weekday' if any(span) else None
    return 'weekend' if not all(span) else None


#: 습관 날 종류 → 저장할 루틴 요일(0=월). 공휴일은 루틴 요일로 나타낼 수 없어 토·일만 쉬는 날로 본다.
DAY_KIND_DAYS = {'weekday': (0, 1, 2, 3, 4), 'weekend': (5, 6)}
#: 같은 종류를 말로(맡기기 단추·저장 선택지 — '평일 07:30에 물어보기').
DAY_KIND_WORDS = {'weekday': '평일', 'weekend': '주말'}


def routine_days(kind: str | None) -> list[int]:
    """습관 날 종류에 맞는 루틴 요일 — 평일 월~금, 주말 토·일, 그 밖은 매일."""
    return list(DAY_KIND_DAYS.get(kind or '', range(7)))


def days_word(kind: str | None) -> str:
    return DAY_KIND_WORDS.get(kind or '', '매일')


def when_text(usual_time: str | None, confident: bool, time_band: str, kind: str | None) -> str:
    """'평일 오후 10시쯤' — 시각이 흩어져 있으면 정확한 시각을 말하지 않고 '저녁 이맘때'."""
    if not confident or not usual_time:
        return f'{_BAND_WORDS.get(time_band, time_band)} 이맘때'
    prefix = {'weekday': '평일 ', 'weekend': '주말 '}.get(kind or '', '')
    return f'{prefix}{korean_clock(usual_time)}쯤'


def has_final_consonant(word: str) -> bool:
    """마지막 글자에 받침이 있나(한글이 아니면 받침 없음으로 본다)."""
    last = word.strip()[-1:] if word.strip() else ''
    return bool(last) and '가' <= last <= '힣' and (ord(last) - 0xAC00) % 28 != 0


#: '알게 된 것' 상태 — auto(자동 실행 중) · hidden(숨김) · paused(잠시 묻지 않음 — 연달아 거절) · asking(물어보는 중) · learning(알아 가는 중).
HABIT_STATES = ('auto', 'hidden', 'paused', 'asking', 'learning')


def habit_state(routine: dict, auto_routine: bool = False) -> str:
    """저장한 루틴이 카드 없이 자동 실행되면 숨김보다 앞선다(제안을 숨겨도 루틴은 돈다는 것을 가리지 않는다)."""
    if auto_routine:
        return 'auto'
    if routine.get('muted'):
        return 'hidden'
    if routine.get('paused_until'):
        return 'paused'
    return 'asking' if routine.get('established') else 'learning'
