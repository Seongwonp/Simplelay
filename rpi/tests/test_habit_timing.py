"""Fixed-clock regressions for circular habits and bounded response adaptation."""
from datetime import datetime, time, timedelta, timezone

import pytest

from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand, UsageRecord, UsageOutcome
from rpi.intent.feedback import SuggestionFeedback
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.models import ExecutionMode, ProactiveSuggestion, UsageSource
from rpi.intent.suggestions import ProactiveSuggestionService
from rpi.services.persistence import SimpleLayDb

KST = timezone(timedelta(hours=9))
BANDS = (TimeBand('아침', time(6), time(11)), TimeBand('점심', time(11), time(14)),
         TimeBand('오후', time(14), time(17)), TimeBand('저녁', time(17), time(21)),
         TimeBand('야간', time(21), time(6)))


def at(day, value):
    h, m = map(int, value.split(':'))
    return datetime(2026, 10, day, h, m, tzinfo=KST)


def build(times, now='20:50', feedback=None, records=None):
    usage = InMemoryUsageLog(records if records is not None else [
        UsageRecord(at(i + 1, value), '켜기', UsageOutcome.SUCCEEDED, 'fan',
                    ExecutionMode.REAL, UsageSource.DIRECT)
        for i, value in enumerate(times)])
    clock = FixedClock(at(10, now))
    detector = PatternDetector(usage, clock, PatternConfig(3, BANDS, ask_lead_minutes=10))
    executor = MockPurposeExecutor()
    service = ProactiveSuggestionService(detector, clock, executor, feedback=feedback)
    return detector, clock, service, executor, usage


@pytest.mark.parametrize('times,now,usual,start,end', [
    (['20:50', '21:10', '20:55'], '20:45', '20:55', '20:50', '21:10'),
    (['23:50', '00:10', '23:55'], '23:45', '23:55', '23:50', '00:10'),
    (['20:55', '21:05', '21:10'], '20:55', '21:05', '20:55', '21:10'),
])
def test_boundary_cluster_and_lead_cross_display_band(times, now, usual, start, end):
    records = None
    if start == '23:50':
        records = [UsageRecord(at(day, value), '켜기', UsageOutcome.SUCCEEDED,
                               'fan', ExecutionMode.REAL, UsageSource.DIRECT)
                   # 4일(일요일)을 넣어 평일/주말이 섞이게 한다 — 평일만 쓴 습관은 토요일(10일)에 묻지 않는다(2026-10-26).
                   for day, value in zip((1, 3, 4), times)]
    detector, clock, service, executor, _ = build(times, now, records=records)
    candidate, = detector.candidates()
    assert candidate.occurrences == 3
    assert candidate.usual_time == usual
    assert (candidate.window_start, candidate.window_end) == (start, end)
    assert candidate.confident and candidate.spread_minutes == 5
    status, = service.learning_status()['routines']
    assert status['usual_time'] == usual
    card, = service.create_suggestions()
    assert '쯤 하셨어요' in card.reason and '이맘때' not in card.reason
    assert executor.purposes == []
    clock.set(clock.now() - timedelta(minutes=1))
    assert detector.candidates() == ()


def test_scattered_band_times_do_not_establish_a_habit():
    detector, _, _, _, _ = build(['17:10', '18:00', '20:30'], '18:00')
    assert detector.established() == ()
    assert len(detector.learning_status()['routines']) == 3


@pytest.mark.parametrize('gap,established', [(45, True), (46, False)])
def test_cluster_gap_is_inclusive(gap, established):
    times = ['18:00', f'18:{gap:02d}', '18:00']
    detector, _, _, _, _ = build(times, '18:00')
    assert len(detector.learning_status()['routines']) == (1 if established else 2)
    assert bool(detector.established()) is established
    assert detector.learning_status()['routines'][0]['usual_time'] == '18:00'


def test_wide_connected_cluster_asks_only_inside_window_and_uses_uncertain_text():
    detector, clock, service, _, _ = build(['17:10', '17:50', '18:30', '19:10', '19:50'], '17:10')
    candidate, = detector.candidates()
    assert not candidate.confident and candidate.spread_minutes == 40
    assert candidate.ask_time == '17:10'
    assert candidate.window_end == '19:50'
    card, = service.create_suggestions()
    assert card.reason == '최근 28일 중 5일, 저녁 이맘때 하셨어요'
    clock.set(at(10, '17:09'))
    assert detector.candidates() == ()
    clock.set(at(10, '19:51'))
    assert detector.candidates() == ()
    assert service.pending() == ()


def test_rejections_pause_seven_days_and_survive_database_reopen(tmp_path):
    # 2026-10-26: 연달아 두 번 거절 → 7일 쉼(예전 3일).
    path = str(tmp_path / 'feedback.db')
    db = SimpleLayDb(path)
    feedback = SuggestionFeedback(load=db.suggestion_events, save=db.append_suggestion_event)
    detector, clock, service, executor, _ = build(['20:50'] * 3, feedback=feedback)
    for day in (10, 11):
        clock.set(at(day, '20:50'))
        card, = service.create_suggestions()
        service.reject(card.suggestion_id)
    routine, = service.learning_status()['routines']
    assert routine['paused_until'] == at(18, '20:50').isoformat()
    assert routine['pause_reason'] == 'consecutive_rejections'
    db.close()
    db = SimpleLayDb(path)
    detector, clock, service, _, _ = build(['20:50'] * 3,
        feedback=SuggestionFeedback(load=db.suggestion_events, save=db.append_suggestion_event))
    clock.set(at(18, '20:49'))
    assert service.create_suggestions() == ()
    clock.set(at(18, '20:50'))
    assert len(service.create_suggestions()) == 1
    assert service.learning_status()['routines'][0]['paused_until'] is None
    assert executor.purposes == []
    db.close()


def journal(action_times, action='approval_requested', band='저녁'):
    feedback = SuggestionFeedback()
    for i, value in enumerate(action_times, 5):
        shown = min(at(i, '20:40'), at(i, value) - timedelta(minutes=10))
        card = ProactiveSuggestion(str(i), '켜기', band, 3, shown, appliance_id='fan')
        feedback.record(card, shown, 'created', 'habit_pattern')
        feedback.record(card, at(i, value), action, 'user_approval')
    return feedback


@pytest.mark.parametrize('actual,shift,ask', [('20:55', 15, '20:55'), ('21:20', 30, '21:10'),
                                             ('20:05', -30, '20:10')])
def test_approval_shift_is_absolute_bounded_and_requires_fresh_approval(actual, shift, ask):
    detector, clock, service, executor, _ = build(['20:50'] * 3, ask, journal([actual] * 3))
    candidate, = detector.candidates()
    assert candidate.ask_shift_minutes == shift and candidate.ask_time == ask
    assert detector.candidates()[0].ask_time == ask  # polling never compounds the shift
    card, = service.create_suggestions()
    assert executor.purposes == []
    service.approve(card.suggestion_id)
    assert executor.purposes == ['켜기']
    clock.set(at(10, ask) - timedelta(minutes=1))
    assert detector.candidates() == ()


@pytest.mark.parametrize('actions', [
    [(5, 'dismissed'), (5, 'dismissed')],
    [(5, 'dismissed'), (6, 'snoozed'), (7, 'dismissed')],
    [(5, 'dismissed'), (6, 'approval_requested'), (7, 'dismissed')],
])
def test_only_consecutive_rejection_days_pause(actions):
    # 같은 날 두 번은 한 번, 사이에 '나중에'·'예'가 있으면 이어지지 않는다. 물은 차례로 이어진 두 번(5일·7일)은
    # 2026-10-26부터 쉰다(test_habit_trust_1026).
    feedback = SuggestionFeedback()
    for index, (day, action) in enumerate(actions):
        card = ProactiveSuggestion(str(index), '켜기', '저녁', 3, at(day, '20:50'), appliance_id='fan')
        feedback.record(card, at(day, '20:50'), action, 'user_response')
    _, clock, service, _, _ = build(['20:50'] * 3, feedback=feedback)
    clock.set(at(8, '20:50'))
    assert service.learning_status()['routines'][0]['paused_until'] is None
    assert len(service.create_suggestions()) == 1


def test_two_samples_do_not_shift_and_demo_feedback_does_not_count():
    feedback = journal(['20:55'] * 2)
    card = ProactiveSuggestion('demo', '켜기', '데모', 3, at(7, '20:40'), appliance_id='fan')
    feedback.record(card, at(7, '20:55'), 'approval_requested', 'user_approval')
    detector, _, _, _, _ = build(['20:50'] * 3, feedback=feedback)
    assert detector.learning_status()['routines'][0]['ask_shift_minutes'] == 0


def test_real_direct_usage_after_shown_card_adjusts_ask_time():
    feedback = journal(['20:40'] * 3, action='snoozed')
    detector, _, _, _, usage = build(['20:50'] * 3, '20:55', feedback)
    for day in (5, 6, 7):
        usage.append(UsageRecord(at(day, '20:55'), '켜기', UsageOutcome.SUCCEEDED,
                                'fan', ExecutionMode.REAL, UsageSource.DIRECT))
    assert detector.candidates()[0].ask_time == '20:55'


def test_same_band_clusters_keep_separate_feedback():
    feedback = journal(['18:00'] * 2, action='dismissed')
    detector, clock, service, _, _ = build(['18:00'] * 3 + ['20:50'] * 3, feedback=feedback)
    clock.set(at(7, '20:50'))
    routines = {r['usual_time']: r for r in service.learning_status()['routines']}
    assert routines['18:00']['paused_until'] == at(13, '18:00').isoformat()
    assert routines['20:50']['paused_until'] is None
    assert [c.usual_time for c in detector.candidates()] == ['20:50']


def test_completion_across_label_boundary_retires_card_before_approval():
    from rpi.intent.completed_actions import CompletedActions
    from rpi.intent.suggestions import UnknownSuggestionError

    detector, clock, _, executor, _ = build(['21:05'] * 3, '20:55')
    completions = CompletedActions()
    service = ProactiveSuggestionService(detector, clock, executor, completed_actions=completions)
    card, = service.create_suggestions()
    completions.remember('fan', '켜기', (), clock.now())
    assert service.pending() == ()
    with pytest.raises(UnknownSuggestionError):
        service.approve(card.suggestion_id)
    assert executor.purposes == []
    assert service.create_suggestions() == ()


def test_separate_clusters_do_not_shift_each_others_calendar_days():
    detector, _, _, _, _ = build(['08:00'] * 3 + ['20:00'] * 3, '20:00')
    routines = {r['usual_time']: r for r in detector.learning_status()['routines']}
    assert routines['08:00']['recent_days'] == ['2026-10-01', '2026-10-02', '2026-10-03']
    assert routines['20:00']['recent_days'] == ['2026-10-04', '2026-10-05', '2026-10-06']
