"""습관 묻기 신뢰 강화(2026-10-26, 맡기기 신뢰 강화 2·3).

2. 사람 없으면 미루기: 묻는 때(평소 시각 10분 전)에 아무도 없으면 버리지 않고 기다렸다가, 평소 시각 +30분 안에 사람이
   오면 한 번 묻는다. 그 뒤로는 오늘 건너뛴다 — 카드가 없으니 거절·무반응으로 세지 않는다.
3. 연속 거절·무반응 쉬기: 거절 또는 답 없이 지나간 카드가 연달아 두 번이면 그 습관을 7일 쉰다. '이미 했어요'는 거절이
   아니다.

모든 시각은 고정 시계(2026-10, KST). 습관은 매일 20:50(묻기 20:40).
"""

from __future__ import annotations

from rpi.intent.habit_words import habit_state
from rpi.tests.test_ask_less_1026 import at, build, ignore, records

DAYS = [1, 2, 3]  # 목·금·토 — 평일/주말 섞임(모든 날 물을 수 있다)


class _Presence:
    def __init__(self, present=True):
        self.present = present

    def __call__(self):
        return self.present


def _ask(service, clock, day, value):
    clock.set(at(day, value))
    return service.create_suggestions()


def _events(service):
    return service.feedback_events(200)['events']


# ── 2. 사람 없으면 미루기 ───────────────────────────────────────────────────────


def test_absent_at_ask_time_then_present_asks_once_before_usual_plus_30():
    presence = _Presence(False)
    clock, service = build(records(DAYS), at(5, '20:40'), presence=presence)
    assert _ask(service, clock, 5, '20:40') == ()
    assert _ask(service, clock, 5, '21:00') == ()
    presence.present = True
    card, = _ask(service, clock, 5, '21:15')  # 평소 시각 +25분 — 한 번 묻는다
    assert card.purpose == '켜기'
    # 다시 자리를 비우면 카드는 거두고(무반응으로 세지 않는다), 돌아와도 오늘은 다시 묻지 않는다.
    presence.present = False
    assert _ask(service, clock, 5, '21:17') == ()
    presence.present = True
    assert _ask(service, clock, 5, '21:19') == ()
    actions = [e['action'] for e in _events(service)]
    assert actions.count('created') == 1 and 'expired' not in actions


def test_absent_past_usual_plus_30_skips_today_without_penalty():
    presence = _Presence(False)
    # 한 날은 21:30에 써서 묻는 시간대가 21:31까지 열려 있다 — 그래도 사람이 없어 미룬 날은 +30분(21:20)까지만.
    recs = records(DAYS[:2]) + records(DAYS[2:], value='21:30')
    clock, service = build(recs, at(5, '20:40'), presence=presence)
    for day in (5, 6):
        presence.present = False
        assert _ask(service, clock, day, '20:40') == ()
        presence.present = True
        assert _ask(service, clock, day, '21:25') == ()  # +35분 — 오늘은 건너뛴다(묻는 시간대는 아직 열려 있어도)
    assert _events(service) == []  # 카드도, 거절·무반응 기록도 없다
    routine, = service.learning_status()['routines']
    assert routine['paused_until'] is None  # 이틀 건너뛴 것은 쉬기 근거가 아니다
    assert len(_ask(service, clock, 7, '21:25')) == 1  # 다음 날 사람이 있으면 평소처럼(시간대 안이면 묻는다)


def test_present_at_ask_time_is_unchanged():
    clock, service = build(records(DAYS), at(5, '20:40'), presence=_Presence(True))
    assert len(_ask(service, clock, 5, '20:40')) == 1


# ── 3. 연속 거절·무반응 → 7일 쉬기 ─────────────────────────────────────────────────


def test_refusal_then_no_answer_rests_seven_days():
    clock, service = build(records(DAYS), at(5))
    card, = _ask(service, clock, 5, '20:50')
    service.reject(card.suggestion_id)
    ignore(service, clock, 6)
    routine, = service.learning_status()['routines']
    assert routine['paused_until'] == at(13).isoformat()  # 두 번째(6일 20:50)부터 7일
    assert habit_state(routine) == 'paused'
    for day in range(7, 13):
        assert _ask(service, clock, day, '20:50') == ()
    assert len(_ask(service, clock, 13, '20:50')) == 1


def test_two_refusals_on_consecutive_asks_rest_seven_days():
    clock, service = build(records(DAYS), at(5))
    for day in (5, 6):
        card, = _ask(service, clock, day, '20:50')
        service.reject(card.suggestion_id)
    routine, = service.learning_status()['routines']
    assert routine['pause_reason'] == 'consecutive_rejections'
    assert routine['paused_until'] == at(13).isoformat()


def test_already_done_breaks_the_streak():
    clock, service = build(records(DAYS), at(5))
    card, = _ask(service, clock, 5, '20:50')
    service.reject(card.suggestion_id)
    card, = _ask(service, clock, 6, '20:50')
    service.reject(card.suggestion_id, reason='already_done')
    card, = _ask(service, clock, 7, '20:50')
    service.reject(card.suggestion_id)
    assert service.learning_status()['routines'][0]['paused_until'] is None
    assert len(_ask(service, clock, 8, '20:50')) == 1
