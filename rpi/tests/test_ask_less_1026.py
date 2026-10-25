"""허브는 갈수록 덜 묻는다(2026-10-26) — 새 질문 없이 기록에서 알아낸다.

1. '왜 지금' 신호 칩: 카드를 만들 때 실제로 본 신호만 싣는다(습관·온습도·공기질·환경 규칙).
2. '이미 했어요': 오늘은 그 습관을 다시 묻지 않고, 거절로 세지 않는다.
3. 평일·주말: 쓴 날이 모두 평일이면 주말에 묻지 않는다(그 반대도).
4. 하루 상한: 먼저 묻는 카드는 하루 N개(기본 3). 직접 요청·루틴 물어보기·연습 카드는 세지 않는다.
5. 무시 물러서기: 답 없이 지나간 카드가 연달아 두 날이면 다음 물을 수 있는 날 하루를 건너뛴다. 답이 오면 풀린다.

모든 시각은 고정 시계(2026-10, KST). 2026-10-05는 월요일이다.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone

import pytest

from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand, UsageOutcome, UsageRecord
from rpi.intent.environment import EnvironmentalCandidate
from rpi.intent.habit_words import habit_state
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.models import ExecutionMode, UsageSource
from rpi.intent.suggestions import (
    DEFAULT_DAILY_ASK_LIMIT,
    ProactiveSuggestionService,
    daily_ask_limit_from_env,
    is_habit_card,
)

KST = timezone(timedelta(hours=9))
BANDS = (TimeBand('아침', time(6), time(11)), TimeBand('점심', time(11), time(14)),
         TimeBand('오후', time(14), time(17)), TimeBand('저녁', time(17), time(21)),
         TimeBand('야간', time(21), time(6)))
MON, TUE, WED, THU, FRI, SAT, SUN = 5, 6, 7, 8, 9, 10, 11


def at(day, value='20:50'):
    h, m = map(int, value.split(':'))
    return datetime(2026, 10, day, h, m, tzinfo=KST)


def records(days, purpose='켜기', value='20:50', appliance='fan'):
    return [UsageRecord(at(d, value), purpose, UsageOutcome.SUCCEEDED, appliance,
                        ExecutionMode.REAL, UsageSource.DIRECT) for d in days]


def build(recs, now, *, limit=None, presence=None, environmental=None):
    clock = FixedClock(now)
    detector = PatternDetector(InMemoryUsageLog(recs), clock, PatternConfig(3, BANDS, ask_lead_minutes=10))
    service = ProactiveSuggestionService(detector, clock, MockPurposeExecutor(), daily_ask_limit=limit,
                                         presence_gate=presence, environmental=environmental)
    return clock, service


def ask(service, clock, when):
    clock.set(when)
    return service.create_suggestions()


def ignore(service, clock, day, value='20:50'):
    """그날 카드를 띄우고 답 없이 지나가게 한다(유효 시간 뒤 조회 → 'expired')."""
    card, = ask(service, clock, at(day, value))
    clock.set(at(day, '23:00'))
    assert service.pending() == ()
    events = service.feedback_events(200)['events']
    assert any(e['suggestion_id'] == card.suggestion_id and e['action'] == 'expired' for e in events)
    return card


# ── 3. 평일·주말은 묻지 않고 기록에서 ──────────────────────────────────────────


def test_weekday_habit_is_not_asked_on_weekend_and_text_matches():
    clock, service = build(records([MON, TUE, WED]), at(SAT))
    assert ask(service, clock, at(SAT)) == ()
    assert ask(service, clock, at(SUN)) == ()
    routine, = service.learning_status()['routines']
    assert routine['day_kind'] == 'weekday' and routine['when_text'].startswith('평일 ')
    assert len(ask(service, clock, at(12))) == 1  # 다음 월요일


def test_weekend_habit_is_not_asked_on_weekday():
    clock, service = build(records([3, 4, SAT]), at(12))
    assert ask(service, clock, at(12)) == ()  # 월요일
    assert service.learning_status()['routines'][0]['when_text'].startswith('주말 ')
    assert len(ask(service, clock, at(SUN))) == 1


def test_mixed_days_are_asked_any_day():
    clock, service = build(records([THU, FRI, SAT]), at(SUN))
    assert len(ask(service, clock, at(SUN))) == 1


# ── 1. '왜 지금' 신호 ─────────────────────────────────────────────────────────


def test_habit_card_signals_are_the_facts_used():
    clock, service = build(records([MON, TUE, WED]), at(THU), presence=lambda: True)
    card, = ask(service, clock, at(THU))
    assert card.signals == (('사람 있음', True), ('평소 오후 8시쯤', True),
                            ('최근 28일 중 3일', True), ('평일 습관', True))
    assert '최근 28일 중 3일' in card.reason and '오후 8시쯤' in card.reason


def test_habit_card_without_presence_sensor_does_not_claim_presence():
    clock, service = build(records([THU, FRI, SAT]), at(SUN))
    card, = ask(service, clock, at(SUN))
    labels = [label for label, _ in card.signals]
    assert labels == ['평소 오후 8시쯤', '최근 28일 중 3일']  # 감지 없음 · 평일/주말 섞임 → 그 칩 없음


class _Env:
    def __init__(self, candidate):
        self.value = candidate

    def candidate(self):
        return self.value


def test_environment_card_signals_follow_the_reading():
    from rpi.intent.environment import EnvironmentalSuggester

    env = EnvironmentalSuggester(lambda: (30.4, 75.0))
    assert env.candidate().signals == (('실내 30°C', True), ('습도 75%', True))
    env = EnvironmentalSuggester(lambda: (24.0, 75.0))
    assert env.candidate().signals == (('습도 75%', True),)


def test_air_reading_signals_match_the_reason():
    from rpi.services.air_quality import read_air

    state = {"operation": {"airPurifierOperationMode": "POWER_OFF"},
             "airQualitySensor": {"PM2": 40, "PM2Level": "BAD", "totalPollutionLevel": "NORMAL"}}
    reading = read_air(state)
    assert '초미세먼지' in reading.reason()
    assert reading.signals() == (('초미세먼지 나쁨', True), ('공기청정기 꺼짐', True))


def test_air_monitor_passes_signals_only_to_offers_that_take_them():
    from rpi.services.air_quality import AirQualityMonitor

    state = {"operation": {"airPurifierOperationMode": "POWER_ON"}, "airFlow": {"windStrength": "LOW"},
             "airQualitySensor": {"PM2": 40, "PM2Level": "VERY_BAD"}}
    seen = []
    monitor = AirQualityMonitor(lambda: state, lambda reason, *, power_off=False, signals=(): seen.append(signals) or 1)
    assert monitor.check_once() == 'offered'
    assert seen == [(('초미세먼지 매우 나쁨', True), ('공기청정기 켜짐', True))]
    old = AirQualityMonitor(lambda: state, lambda reason, *, power_off=False: 1)  # 옛 모양 — 그대로 동작
    assert old.check_once() == 'offered'


def test_context_rules_pass_the_signals_they_checked():
    from rpi.services.context_suggestions import ContextSignals, ContextSuggestionMonitor

    night = datetime(2026, 10, 26, 22, 30, tzinfo=KST)
    purifier = {"operation": {"airPurifierOperationMode": "POWER_ON"},
                "airPurifierJobMode": {"currentJobMode": "CLEAN"}}
    sleep = ContextSignals(local_now=night, presence='present', lights_off_at=500.0, dark_for_s=180.0,
                           purifier=purifier, wall_now=10_000.0)
    offers = []
    monitor = ContextSuggestionMonitor(lambda: sleep, lambda sid, reason, *, signals=(): offers.append(signals) or 1,
                                       monotonic=lambda: 1000.0)
    assert monitor.check_once().startswith('sleep:offered')
    assert [label for label, _ in offers[0]] == ['사람 있음', '방이 어두움', '밤 시간', '공기청정기 켜짐']
    arrival = ContextSignals(local_now=night, presence='present', arrival_at=9_900.0, wall_now=10_000.0,
                             purifier={"operation": {"airPurifierOperationMode": "POWER_OFF"},
                                       "airQualitySensor": {"PM2Level": "BAD", "totalPollutionLevel": "BAD"}},
                             dust_warning=True)
    offers.clear()
    monitor = ContextSuggestionMonitor(lambda: arrival, lambda sid, reason, *, signals=(): offers.append(signals) or 1,
                                       monotonic=lambda: 1000.0)
    assert 'arrival:offered' in monitor.check_once()
    assert [label for label, _ in offers[0]] == ['외출 뒤 돌아옴', '실내 공기 나쁨', '황사 특보', '공기청정기 꺼짐']


def test_payload_carries_signals_and_mark_done():
    from rpi.api.schemas import RejectSuggestionRequest, SuggestionResponse
    from rpi.api.thinq_router import suggestion_payload

    clock, service = build(records([MON, TUE, WED]), at(THU))
    card, = ask(service, clock, at(THU))
    payload = suggestion_payload(card)
    assert payload['signals'] == [{'label': '평소 오후 8시쯤', 'ok': True},
                                  {'label': '최근 28일 중 3일', 'ok': True},
                                  {'label': '평일 습관', 'ok': True}]
    assert payload['can_mark_done'] is True
    assert SuggestionResponse(id='x', purpose='p', time_band='b', occurrences=0).signals == []
    assert RejectSuggestionRequest().reason is None
    assert RejectSuggestionRequest(reason='already_done').reason == 'already_done'


# ── 2. '이미 했어요' ─────────────────────────────────────────────────────────


def test_already_done_skips_today_and_is_not_a_dismissal():
    # 넓게 흩어진 저녁 습관(평일 3일) — 17:10~19:50 동안 물을 수 있다
    recs = (records([MON], value='17:10') + records([TUE], value='17:50') + records([WED], value='18:30')
            + records([MON], value='19:10') + records([TUE], value='19:50'))
    clock, service = build(recs, at(THU, '17:10'))
    for day in (THU, FRI):
        card, = ask(service, clock, at(day, '17:10'))
        assert is_habit_card(card)
        service.reject(card.suggestion_id, reason='already_done')
        assert ask(service, clock, at(day, '19:40')) == ()  # 오늘은 다시 묻지 않는다
        assert service._cooldowns.blocked(service._key(card), at(day, '23:59'))  # 자정까지
    actions = [e['action'] for e in service.feedback_events(200)['events']]
    assert actions.count('already_done') == 2 and 'dismissed' not in actions
    routine, = service.learning_status()['routines']
    assert routine['paused_until'] is None  # 두 번 연달아 '이미 했어요'는 거절 두 번이 아니다
    assert len(ask(service, clock, at(12, '17:10'))) == 1  # 다음 물을 날(월요일)에는 묻는다


def test_already_done_is_only_for_habit_cards():
    clock, service = build([], at(THU))
    demo = service.create_demo_suggestion('켜기', appliance_id='fan')
    assert not is_habit_card(demo)
    with pytest.raises(ValueError):
        service.reject(demo.suggestion_id, reason='already_done')
    assert service.pending() == (demo,)


def test_plain_no_keeps_counting_as_a_dismissal():
    clock, service = build(records([MON, TUE, WED]), at(THU))
    for day in (THU, FRI):
        card, = ask(service, clock, at(day))
        service.reject(card.suggestion_id)
    assert service.learning_status()['routines'][0]['pause_reason'] == 'consecutive_rejections'


# ── 4. 하루 상한 ─────────────────────────────────────────────────────────────


def _four_habits():
    recs = []
    for purpose in ('가', '나', '다'):
        recs += records([MON, TUE, WED, THU], purpose=purpose)
    recs += records([TUE, WED, THU], purpose='라')  # 근거가 가장 적은 습관
    return recs


def test_daily_limit_defers_the_least_confident_habit():
    clock, service = build(_four_habits(), at(FRI), limit=3)
    cards = ask(service, clock, at(FRI))
    assert sorted(c.purpose for c in cards) == ['가', '나', '다']
    assert service.asked_today() == 3
    for card in cards:
        service.reject(card.suggestion_id)
    assert ask(service, clock, at(FRI, '20:55')) == ()  # 상한 — '라'는 오늘 미룬다(카드 없음)
    assert not any(e['purpose'] == '라' for e in service.feedback_events(200)['events'])


def test_daily_limit_resets_next_day():
    recs = _four_habits() + records([FRI], purpose='라')
    clock, service = build(recs, at(FRI), limit=3)
    assert len(ask(service, clock, at(FRI))) == 3
    clock.set(at(12, '20:50'))  # 다음 월요일
    assert service.asked_today() == 0
    assert len(ask(service, clock, at(12))) == 3


def test_without_limit_every_eligible_card_is_asked():
    clock, service = build(_four_habits(), at(FRI))
    assert len(ask(service, clock, at(FRI))) == 4


def test_live_environment_signal_wins_over_habit_when_one_slot_left():
    env = _Env(EnvironmentalCandidate('에어컨 켜줘', '지금 30°C — 더워요', appliance_id='aircon',
                                      signals=(('실내 30°C', True),)))
    clock, service = build(records([MON, TUE, WED]), at(THU), limit=1, environmental=env)
    cards = ask(service, clock, at(THU))
    assert [c.time_band for c in cards] == ['환경']
    assert cards[0].signals == (('실내 30°C', True),)


@dataclass(frozen=True)
class _Command:
    target_id: str = 'air_purifier'


def _scenario(service, *, scenario_id='air', **kw):
    return service.create_scenario_suggestion(
        scenario_id=scenario_id, purpose=kw.pop('purpose', '공기청정기를 켤까요?'), commands=(_Command(),),
        summaries=('켜기',), reason='공기가 나빠요', is_demo=kw.pop('is_demo', False), **kw)


def test_daily_limit_exempts_own_routine_demo_cards_and_blocks_proactive_ones():
    clock, service = build(_four_habits(), at(FRI), limit=3)
    assert len(ask(service, clock, at(FRI))) == 3
    assert _scenario(service, signals=(('초미세먼지 나쁨', True),)) is None  # 먼저 묻는 상황 카드 — 미룬다
    own = _scenario(service, scenario_id='r1', purpose="'저녁' 루틴을 실행할까요?", time_band='루틴',
                    user_started=True)
    asked_routine = _scenario(service, scenario_id='r2', purpose="'아침' 루틴을 실행할까요?", time_band='루틴')
    practice = _scenario(service, scenario_id='demo', purpose='연습 카드?', is_demo=True)
    demo = service.create_demo_suggestion('켜기', appliance_id='fan')
    assert None not in (own, asked_routine, practice, demo)
    assert service.asked_today() == 3


def test_scenario_card_counts_toward_the_limit_and_keeps_signals():
    clock, service = build([], at(FRI), limit=1)
    card = _scenario(service, signals=(('초미세먼지 나쁨', True), ('공기청정기 꺼짐', True)))
    assert card.signals == (('초미세먼지 나쁨', True), ('공기청정기 꺼짐', True))
    assert not is_habit_card(card)
    assert service.asked_today() == 1
    service.reject(card.suggestion_id)
    assert _scenario(service, scenario_id='other', purpose='다른 질문?') is None


@pytest.mark.parametrize('raw, expected', [(None, DEFAULT_DAILY_ASK_LIMIT), ('', 3), ('5', 5), ('0', None),
                                           ('off', None), ('x', 3), ('-2', 3)])
def test_daily_limit_env(raw, expected):
    env = {} if raw is None else {'SIMPLELAY_DAILY_ASK_LIMIT': raw}
    assert daily_ask_limit_from_env(env) == expected


# ── 5. 무시 물러서기 ─────────────────────────────────────────────────────────


def test_two_ignored_days_skip_one_day_then_ask_every_other_day():
    clock, service = build(records([1, 2, 3]), at(SAT))  # 목·금·토 — 평일/주말 섞임(모든 날 물을 수 있다)
    ignore(service, clock, SAT)
    ignore(service, clock, SUN)
    clock.set(at(12, '20:40'))
    routine, = service.learning_status()['routines']
    assert routine['pause_reason'] == 'consecutive_ignores'
    assert habit_state(routine) == 'paused'  # '알게 된 것'의 '잠시 묻지 않음'
    assert ask(service, clock, at(12)) == ()  # 하루 건너뜀
    ignore(service, clock, 13)  # 다음 날은 다시 묻는다 — 또 무시
    assert ask(service, clock, at(14)) == ()  # 또 하루 건너뜀(하루걸러)
    card, = ask(service, clock, at(15))
    service.reject(card.suggestion_id)  # 답이 오면 풀린다
    assert len(ask(service, clock, at(16))) == 1
    assert service.learning_status()['routines'][0]['paused_until'] is None


def test_ignore_backoff_skips_the_next_eligible_weekday():
    clock, service = build(records([MON, TUE, WED]), at(THU))
    ignore(service, clock, THU)
    ignore(service, clock, FRI)
    assert ask(service, clock, at(12)) == ()  # 주말은 원래 묻지 않으니 다음 평일(월요일)을 건너뛴다
    assert len(ask(service, clock, at(13))) == 1


def test_single_ignore_or_answer_between_does_not_pause():
    clock, service = build(records([1, 2, 3]), at(SAT))
    ignore(service, clock, SAT)
    card, = ask(service, clock, at(SUN))
    service.reject(card.suggestion_id)
    ignore(service, clock, 12)
    assert len(ask(service, clock, at(13))) == 1


def test_ignored_scenario_card_is_skipped_next_day_and_answer_resets():
    clock, service = build([], at(SAT))

    def ignore_scenario(day):
        clock.set(at(day, '12:00'))
        card = _scenario(service)
        assert card is not None
        clock.set(at(day, '13:00'))
        assert service.pending() == ()

    ignore_scenario(SAT)
    ignore_scenario(SUN)
    clock.set(at(12, '12:00'))
    assert _scenario(service) is None  # 하루 건너뜀
    clock.set(at(13, '12:00'))
    card = _scenario(service)
    assert card is not None
    service.reject(card.suggestion_id)
    clock.set(at(14, '12:00'))
    assert _scenario(service) is not None


# ── 서버 응답(모의 ThinQ) ─────────────────────────────────────────────────────

from rpi.tests.test_context_suggestions import _server_monitor, _sleep_signals, api  # noqa: E402,F401


def test_api_context_card_carries_signals_and_no_mark_done(api):  # noqa: F811
    assert _server_monitor(_sleep_signals()).check_once().startswith('sleep:offered')
    card, = [s for s in api.get('/suggestions').json() if s.get('scenario_id') == 'context_sleep_mode']
    assert [s['label'] for s in card['signals']] == ['사람 있음', '방이 어두움', '밤 시간', '공기청정기 켜짐']
    assert all(s['ok'] is True for s in card['signals'])
    assert card['can_mark_done'] is False
    res = api.post(f"/suggestions/{card['id']}/reject", json={'reason': 'already_done'})
    assert res.status_code == 422  # 습관 카드에만
    assert api.post(f"/suggestions/{card['id']}/reject", json={'reason': 'other'}).status_code == 422
    assert api.post(f"/suggestions/{card['id']}/reject", json={'mute': False}).status_code == 200
