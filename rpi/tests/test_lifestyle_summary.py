"""'알게 된 것'과 밤 생활 습관 정리(2026-10-26).

- 습관마다 평소 시각을 사람 말로('평일 오전 8시쯤' / 흩어지면 '아침 이맘때'), 상태(auto·hidden·paused·asking·learning).
- 숨기기·다시 보이기는 같은 억제 저장소(``/suppressions/mute``·``/suppressions/unmute``).
- 정리 문장: 모델 답은 검사(영문자·근거 밖 숫자·길이·문장 수·습관 이름)를 통과해야만 쓰고, 아니면 정해진 문장.
- 모델은 요청 경로에서 부르지 않는다(전용 스레드). 결과는 설정 저장소에 남아 재시작 뒤에도 보인다.
"""

from __future__ import annotations

import json
import threading
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from rpi.api.auth import require_api_key
from rpi.api.deps import get_clock, get_lifestyle_summary_store, get_suggestion_service
from rpi.api.router import router
from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, ProactiveSuggestionService
from rpi.intent import lifestyle_summary as ls
from rpi.intent.habit_words import day_kind, habit_state, korean_clock, when_text
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.suppression import InMemorySuppressionStore
from rpi.tests.test_learning_evidence import BAND, NOW, record

KST = timezone(timedelta(hours=9))
WEEKDAYS = (3, 4, 5, 6, 7)  # NOW(9/21 월) 기준 9/18 금 … 9/14 월


def _facts(*habits, window=28):
    return ls.Facts(window, tuple({'purpose': p, 'when_text': w, 'distinct_days': d, 'occurrences': o}
                                  for p, w, d, o in habits))


FACTS = _facts(('즉석밥 데워줘', '평일 오후 10시쯤', 5, 6))


# ── 말 ───────────────────────────────────────────────────────────────────
@pytest.mark.parametrize('value, text', [('22:00', '오후 10시'), ('07:05', '오전 7시 5분'),
                                         ('00:30', '밤 12시 30분'), ('12:00', '낮 12시')])
def test_korean_clock(value, text):
    assert korean_clock(value) == text


def test_when_text_says_weekday_only_when_every_day_was_a_weekday():
    days = [(NOW - timedelta(days=d)).date().isoformat() for d in WEEKDAYS]
    assert day_kind(days) == 'weekday'
    assert day_kind(days + [NOW.date().replace(day=20).isoformat()]) is None  # 일요일이 섞임
    assert day_kind(days[:2]) is None  # 근거 적음
    assert when_text('22:00', True, '야간', 'weekday') == '평일 오후 10시쯤'
    assert when_text('22:00', False, '야간', 'weekday') == '밤 이맘때'
    assert when_text('18:00', False, '저녁', None) == '저녁 이맘때'


def test_learning_status_carries_when_text_and_day_kind():
    detector = PatternDetector(InMemoryUsageLog([record(d) for d in WEEKDAYS]), FixedClock(NOW),
                               PatternConfig(3, (BAND,)))
    routine, = detector.learning_status()['routines']
    assert routine['day_kind'] == 'weekday'
    assert routine['when_text'] == '평일 오전 8시쯤'
    assert routine['usual_time'] == '08:00' and routine['confident'] is True


@pytest.mark.parametrize('routine, auto, state', [
    ({'established': True}, False, 'asking'),
    ({'established': False}, False, 'learning'),
    ({'established': True, 'paused_until': '2026-09-22T08:00:00+09:00'}, False, 'paused'),
    ({'established': True, 'muted': True, 'paused_until': 'x'}, False, 'hidden'),
    ({'established': True, 'muted': True}, True, 'auto'),
])
def test_habit_state(routine, auto, state):
    assert habit_state(routine, auto) == state


# ── 검사 ─────────────────────────────────────────────────────────────────
@pytest.mark.parametrize('text', [
    '평일 오후 10시쯤 즉석밥 데워줘를 자주 하셨어요. 최근 28일 중 5일이에요.',
    '  즉석밥 데워줘는 주로 평일 오후 10시쯤 하셨어요.\n최근 5일 사용하셨어요. ',
])
def test_validate_accepts_short_polite_korean_using_fact_numbers(text):
    assert ls.validate(text, FACTS) == ' '.join(text.split())


@pytest.mark.parametrize('text', [
    'You usually heat rice at 10 pm.',  # 영어
    '즉석밥 데워줘를 TV 볼 때 하셨어요.',  # 영문자 섞임
    '즉석밥 데워줘를 7일 중 5일 하셨어요.',  # 근거에 없는 숫자(7)
    '즉석밥 데워줘를 자주 하셨어요!',  # 느낌표
    '즉석밥 데워줘를 하셨나요?',  # 물음표
    '즉석밥 데워줘. 평일 오후 10시쯤. 최근 5일.',  # 세 문장
    '즉석밥 데워줘 ' + '가' * 120,  # 너무 김
    '평일 오후 10시쯤 커피를 내리셨어요.',  # 근거의 습관을 말하지 않음(지어냄)
    '즉석밥 데워줘를 하셨어요 😀',  # 허용 글자 밖
    '',
    None,
])
def test_validate_rejects(text):
    assert ls.validate(text, FACTS) is None


# ── 정해진 문장 ──────────────────────────────────────────────────────────
def test_template_sentences():
    assert ls.template_text(_facts()) == ('아직 습관으로 기억한 사용 기록이 없어요. '
                                          '평소처럼 사용해 주시면 정리해 드릴게요.')
    assert ls.template_text(FACTS) == ("평일 오후 10시쯤 '즉석밥 데워줘'를 가장 꾸준히 하셨어요. "
                                       '최근 28일 중 5일 하셨어요.')
    two = _facts(('공기청정기 켜기', '저녁 이맘때', 4, 4), ('즉석밥 데워줘', '평일 오후 10시쯤', 3, 3))
    assert ls.template_text(two) == ("저녁 이맘때 '공기청정기 켜기'를 가장 꾸준히 하셨어요. "
                                     '그 밖에 1가지 습관을 더 기억하고 있어요.')
    assert ls.template_text(_facts(('밥 짓기 시작', '저녁 이맘때', 3, 3))).startswith(
        "저녁 이맘때 '밥 짓기 시작'을 가장 꾸준히 하셨어요.")
    # 정해진 문장도 같은 글자·길이 검사를 통과한다
    assert ls.validate(ls.template_text(FACTS), FACTS) is not None


def test_facts_skip_hidden_and_unestablished_habits_and_hold_no_appliance_names():
    status = {'window_days': 28, 'routines': [
        {'purpose': '숨긴 것', 'established': True, 'muted': True, 'distinct_days': 9, 'occurrences': 9,
         'when_text': '저녁 이맘때', 'appliance_id': 'mw'},
        {'purpose': '알아 가는 중', 'established': False, 'muted': False, 'distinct_days': 2, 'occurrences': 2},
        {'purpose': '즉석밥 데워줘', 'established': True, 'muted': False, 'distinct_days': 5, 'occurrences': 6,
         'when_text': '평일 오후 10시쯤', 'appliance_id': 'kitchen-mw'},
    ]}
    facts = ls.build_facts(status)
    assert facts.purposes == ('즉석밥 데워줘',)
    assert 'kitchen-mw' not in facts.text and '숨긴 것' not in facts.text


# ── 생성 ─────────────────────────────────────────────────────────────────
STATUS = {'window_days': 28, 'routines': [
    {'purpose': '즉석밥 데워줘', 'established': True, 'muted': False, 'distinct_days': 5, 'occurrences': 6,
     'when_text': '평일 오후 10시쯤'}]}
LLM_TEXT = '평일 오후 10시쯤 즉석밥 데워줘를 자주 하셨어요. 최근 28일 중 5일이에요.'


def _reply(text):
    return {'choices': [{'message': {'content': text}}]}


def test_generate_uses_model_when_valid_with_english_system_prompt():
    sent = {}

    def transport(url, body, timeout):
        sent.update(url=url, body=body, timeout=timeout)
        return _reply(LLM_TEXT)
    value = ls.generate(STATUS, ls.SummaryConfig('http://llm', 90), NOW, transport)
    assert value == {'text': LLM_TEXT, 'generated_at': NOW.isoformat(), 'source': 'llm',
                     'purposes': ['즉석밥 데워줘']}
    assert sent['url'] == 'http://llm/invoke' and sent['timeout'] == 90
    system = sent['body']['messages'][0]['content']
    assert system.startswith('You write') and 'FACTS:' in system and '즉석밥 데워줘' in system


@pytest.mark.parametrize('transport', [
    lambda *a: _reply('You heat rice often.'),
    lambda *a: _reply('즉석밥 데워줘를 7일 중 5일 하셨어요.'),
    lambda *a: (_ for _ in ()).throw(TimeoutError()),
    lambda *a: {'unexpected': True},
])
def test_generate_falls_back_to_template(transport):
    value = ls.generate(STATUS, ls.SummaryConfig('http://llm', 90), NOW, transport)
    assert value['source'] == 'template'
    assert value['text'] == ls.template_text(ls.build_facts(STATUS))


def test_generate_without_model_url_never_calls_transport():
    def transport(*_):
        raise AssertionError('model must not be called when SIMPLELAY_LLM_URL is unset')
    assert ls.generate(STATUS, ls.SummaryConfig('', 90), NOW, transport)['source'] == 'template'


def test_config_from_env(monkeypatch):
    monkeypatch.delenv('SIMPLELAY_LLM_URL', raising=False)
    assert ls.SummaryConfig.from_env().url == ''
    monkeypatch.setenv('SIMPLELAY_LLM_URL', 'http://x/')
    monkeypatch.setenv('SIMPLELAY_LLM_SUMMARY_TIMEOUT_SECONDS', 'nan')
    assert ls.SummaryConfig.from_env() == ls.SummaryConfig('http://x', 90)


# ── 저장·나이 ────────────────────────────────────────────────────────────
def test_store_persists_across_restart_and_ignores_garbage():
    cell = {}
    store = ls.LifestyleSummaryStore(load=lambda: cell.get('v'), save=lambda v: cell.update(v=v))
    value = {'text': LLM_TEXT, 'generated_at': NOW.isoformat(), 'source': 'llm', 'purposes': ['즉석밥 데워줘']}
    store.put(value)
    assert json.loads(cell['v'])['text'] == LLM_TEXT
    again = ls.LifestyleSummaryStore(load=lambda: cell.get('v'))
    assert again.get() == value
    assert ls.LifestyleSummaryStore(load=lambda: '{"text": 3}').get() is None
    assert ls.LifestyleSummaryStore(load=lambda: 'not json').get() is None


def test_current_summary_drops_stored_text_that_mentions_a_now_hidden_habit_or_is_old():
    stored = {'text': LLM_TEXT, 'generated_at': NOW.isoformat(), 'source': 'llm', 'purposes': ['즉석밥 데워줘']}
    assert ls.current_summary(stored, STATUS, NOW + timedelta(hours=5))['source'] == 'llm'
    hidden = {**STATUS, 'routines': [{**STATUS['routines'][0], 'muted': True}]}
    shown = ls.current_summary(stored, hidden, NOW)
    assert shown['source'] == 'template' and '즉석밥' not in shown['text']
    assert ls.current_summary(stored, STATUS, NOW + timedelta(hours=40))['source'] == 'template'


def test_next_run_is_three_am_local():
    assert ls.next_run(datetime(2026, 9, 21, 2, 59, tzinfo=KST)) == datetime(2026, 9, 21, 3, tzinfo=KST)
    assert ls.next_run(datetime(2026, 9, 21, 3, 0, tzinfo=KST)) == datetime(2026, 9, 22, 3, tzinfo=KST)


# ── 전용 스레드 ──────────────────────────────────────────────────────────
class _Sleeper:
    """잠 대신 기다린 시간을 적고, 정한 횟수 뒤 멈춘다."""

    def __init__(self, scheduler_holder, wakeups):
        self.waits = []
        self._holder = scheduler_holder
        self._wakeups = wakeups

    def __call__(self, seconds):
        self.waits.append(seconds)
        if len(self.waits) > self._wakeups:
            self._holder[0].stop()
            return True
        return False


def test_scheduler_runs_on_start_when_missing_then_nightly_in_its_own_thread():
    calls = []

    def transport(*_):
        calls.append(threading.current_thread().name)
        return _reply(LLM_TEXT)
    store = ls.LifestyleSummaryStore()
    holder = []
    sleeper = _Sleeper(holder, wakeups=1)
    scheduler = ls.SummaryScheduler(status=lambda: STATUS, store=store, clock=FixedClock(NOW),
                                    config=ls.SummaryConfig('http://llm', 90), transport=transport,
                                    sleep=sleeper)
    holder.append(scheduler)
    scheduler.start()
    scheduler._thread.join(5)
    assert calls == ['lifestyle-summary', 'lifestyle-summary']  # 기동 1회 + 03:00 1회
    assert sleeper.waits[0] == (ls.next_run(NOW) - NOW).total_seconds()
    assert store.get()['source'] == 'llm'


def test_scheduler_skips_startup_run_when_fresh_and_retries_template_results():
    calls = []
    store = ls.LifestyleSummaryStore()
    store.put({'text': 'x', 'generated_at': (NOW - timedelta(hours=2)).isoformat(), 'source': 'llm'})
    holder = []
    sleeper = _Sleeper(holder, wakeups=0)
    scheduler = ls.SummaryScheduler(status=lambda: STATUS, store=store, clock=FixedClock(NOW),
                                    config=ls.SummaryConfig('http://llm', 90),
                                    transport=lambda *a: calls.append(1) or _reply('bad English'),
                                    sleep=sleeper)
    holder.append(scheduler)
    scheduler._loop()
    assert calls == []  # 신선하면 기동 때 다시 만들지 않는다
    assert scheduler._wants_retry({'source': 'template', 'purposes': ['즉석밥 데워줘']})
    assert not scheduler._wants_retry({'source': 'template', 'purposes': []})


def test_startup_does_not_start_thread_without_model(monkeypatch):
    from rpi.api import deps

    monkeypatch.delenv('SIMPLELAY_LLM_URL', raising=False)
    assert deps.start_lifestyle_summary_scheduler() is None


# ── API ──────────────────────────────────────────────────────────────────
def _api(monkeypatch, *, store=None, records=WEEKDAYS, suppression=None):
    clock = FixedClock(NOW)
    detector = PatternDetector(InMemoryUsageLog([record(d) for d in records]), clock, PatternConfig(3, (BAND,)))
    service = ProactiveSuggestionService(detector, clock, MockPurposeExecutor(),
                                         suppression_store=suppression or InMemorySuppressionStore())
    app = FastAPI()
    app.include_router(router, dependencies=[Depends(require_api_key)])
    app.dependency_overrides[get_suggestion_service] = lambda: service
    app.dependency_overrides[get_lifestyle_summary_store] = lambda: store
    app.dependency_overrides[get_clock] = lambda: clock
    monkeypatch.setenv('SIMPLELAY_API_KEY', 'test-key')
    monkeypatch.setattr('rpi.api.router._habit_auto_routines', lambda routines: {})
    return TestClient(app), service


H = {'X-API-Key': 'test-key'}


def test_learning_endpoints_need_the_api_key(monkeypatch):
    client, _ = _api(monkeypatch)
    with client:
        assert client.get('/learning/summary').status_code == 401
        assert client.post('/suppressions/mute', json={'purpose': '즉석밥 데워줘'}).status_code == 401
        assert client.get('/learning/summary', headers=H).status_code == 200


def test_learning_response_has_state_when_text_and_template_summary(monkeypatch):
    client, _ = _api(monkeypatch)
    with client:
        body = client.get('/learning', headers=H).json()
    routine, = body['routines']
    assert routine['state'] == 'asking'
    assert routine['when_text'] == '평일 오전 8시쯤'
    assert body['summary']['source'] == 'template'
    assert body['summary']['text'].startswith("평일 오전 8시쯤 '즉석밥 데워줘'를")


def test_learning_summary_reads_stored_model_text_without_calling_the_model(monkeypatch):
    store = ls.LifestyleSummaryStore()
    store.put({'text': '평일 오전 8시쯤 즉석밥 데워줘를 하셨어요.', 'generated_at': NOW.isoformat(),
               'source': 'llm', 'purposes': ['즉석밥 데워줘']})
    monkeypatch.setattr(ls, 'generate', lambda *a, **k: pytest.fail('model call in request path'))
    monkeypatch.setattr(ls, '_http_transport', lambda *a, **k: pytest.fail('model call in request path'))
    client, _ = _api(monkeypatch, store=store)
    with client:
        summary = client.get('/learning/summary', headers=H).json()
    assert summary == {'text': '평일 오전 8시쯤 즉석밥 데워줘를 하셨어요.', 'generated_at': NOW.isoformat(),
                       'source': 'llm'}


def test_hide_and_unhide_a_habit_from_the_learning_view(monkeypatch):
    client, service = _api(monkeypatch)
    with client:
        assert client.post('/suppressions/mute', json={'purpose': '즉석밥 데워줘'}, headers=H).status_code == 200
        routine, = client.get('/learning', headers=H).json()['routines']
        assert (routine['muted'], routine['state']) == (True, 'hidden')
        assert service.create_suggestions() == ()
        assert client.post('/suppressions/mute', json={'purpose': '  '}, headers=H).status_code == 422
        assert client.post('/suppressions/unmute', json={'purpose': '즉석밥 데워줘'}, headers=H).status_code == 200
        routine, = client.get('/learning', headers=H).json()['routines']
        assert (routine['muted'], routine['state']) == (False, 'asking')


def test_auto_routine_state_wins_and_names_the_routine(monkeypatch):
    client, _ = _api(monkeypatch)
    monkeypatch.setattr('rpi.api.router._habit_auto_routines',
                        lambda routines: {('즉석밥 데워줘', 'microwave'): '아침 즉석밥'})
    with client:
        routine, = client.get('/learning', headers=H).json()['routines']
    assert (routine['state'], routine['routine_name']) == ('auto', '아침 즉석밥')
