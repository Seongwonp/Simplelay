from datetime import time
from types import SimpleNamespace
from time import sleep

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from rpi.api.auth import require_api_key
from rpi.api.deps import get_suggestion_service
from rpi.api.router import router
from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, ProactiveSuggestionService, RuleBasedIntentResolver, TimeBand
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.tiered import TieredIntentResolver
from rpi.tests.test_learning_evidence import NOW, BAND, record
from rpi.tests.test_usage_appliance import _service


@pytest.mark.parametrize('asynchronous', [False, True])
def test_aliases_are_recorded_as_one_purpose(asynchronous):
    log = InMemoryUsageLog()
    clock = FixedClock(NOW)
    service = _service(log, clock)
    execute = service.submit_purpose if asynchronous else service.execute_purpose
    for i, text in enumerate(('햇반 데워줘', '즉석밥 데워 줘!', '밥 데워줘')):
        execute(text, 'microwave')
        for _ in range(200):
            if not service._running:
                break
            sleep(.01)
    assert len(log.records()) == 3
    assert {r.purpose for r in log.records()} == {'즉석밥 데워줘'}


def test_normalization_requires_same_executed_sequence():
    rules = RuleBasedIntentResolver()
    assert rules.learning_purpose('햇반 데워줘', ('즉석밥', '시작')) == '즉석밥 데워줘'
    assert rules.learning_purpose('햇반 데워줘', ('전원',)) == '햇반 데워줘'
    custom = RuleBasedIntentResolver({'햇반 데워줘': ('전원',)})
    assert custom.learning_purpose('햇반 데워줘', ('전원',)) == '햇반 데워줘'


def test_tiered_learning_does_not_make_external_request():
    class Fallback:
        def resolve(self, purpose):
            raise AssertionError('learning must not call a model')
    resolver = TieredIntentResolver((RuleBasedIntentResolver(), Fallback()))
    assert resolver.learning_purpose('밥 데워줘', ('즉석밥', '시작')) == '즉석밥 데워줘'
    assert resolver.learning_purpose('다른 목적', ('전원',)) == '다른 목적'


def test_custom_function_names_are_not_reinterpreted():
    service = _service(InMemoryUsageLog(), FixedClock(NOW))
    rules = RuleBasedIntentResolver()
    assert service._learning_purpose('밥 데워줘', ('즉석밥', '시작'), rules,
                                     'mw', ('즉석밥', '시작')) == '밥 데워줘'
    appliance = SimpleNamespace(function_steps=lambda p: ('전원',))
    service._appliance_registry = SimpleNamespace(get=lambda _: appliance)
    assert service._learning_purpose('밥 데워줘', ('즉석밥', '시작'), rules,
                                     'mw', None) == '밥 데워줘'


def test_learning_status_includes_partial_habits_outside_current_band():
    detector = PatternDetector(InMemoryUsageLog([record(1), record(2)]),
                               FixedClock(NOW.replace(hour=15)), PatternConfig(3, (BAND,)))
    assert detector.candidates() == ()
    status = detector.learning_status()
    routine, = status['routines']
    assert routine['distinct_days'] == 2
    assert routine['established'] is False


def test_status_and_candidates_use_identical_evidence():
    detector = PatternDetector(InMemoryUsageLog([record(d) for d in (1, 2, 3)]),
                               FixedClock(NOW), PatternConfig(3, (BAND,)))
    candidate, = detector.candidates()
    routine, = detector.learning_status()['routines']
    assert routine['established'] is True
    assert routine['distinct_days'] == candidate.distinct_days
    assert routine['occurrences'] == candidate.occurrences


def test_learning_api_is_read_only_and_authenticated(monkeypatch):
    clock = FixedClock(NOW)
    detector = PatternDetector(InMemoryUsageLog([record(1)]), clock, PatternConfig(3, (BAND,)))
    executor = MockPurposeExecutor()
    service = ProactiveSuggestionService(detector, clock, executor)
    service.set_dnd_for(30)
    app = FastAPI()
    app.include_router(router, dependencies=[Depends(require_api_key)])
    app.dependency_overrides[get_suggestion_service] = lambda: service
    monkeypatch.setenv('SIMPLELAY_API_KEY', 'test-key')
    with TestClient(app) as client:
        assert client.get('/learning').status_code == 401
        response = client.get('/learning', headers={'X-API-Key': 'test-key'})
    assert response.status_code == 200
    assert response.json()['paused'] is True
    assert response.json()['routines'][0]['muted'] is False
    assert executor.purposes == []
    assert service.pending() == ()


def test_existing_alias_opt_out_still_hides_canonical_habit():
    clock = FixedClock(NOW)
    detector = PatternDetector(InMemoryUsageLog([record(d) for d in (1, 2, 3)]),
                               clock, PatternConfig(3, (BAND,)))
    store = SimpleNamespace(muted=lambda: frozenset({'햇반 데워줘'}))
    service = ProactiveSuggestionService(detector, clock, MockPurposeExecutor(),
                                        suppression_store=store)
    assert service.create_suggestions() == ()
    assert service.learning_status()['routines'][0]['muted'] is True
