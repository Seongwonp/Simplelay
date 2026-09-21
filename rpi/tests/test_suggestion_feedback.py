from datetime import timedelta
from concurrent.futures import ThreadPoolExecutor
from time import sleep

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from rpi.api.auth import require_api_key
from rpi.api.deps import get_suggestion_service
from rpi.api.router import router
from rpi.intent.feedback import EVENT_CAPACITY, SuggestionFeedback
from rpi.intent.suggestions import UnknownSuggestionError
from rpi.intent.suppression import InMemorySuppressionStore
from rpi.services.persistence import SimpleLayDb
from rpi.tests.test_completed_actions import setup
from rpi.tests.test_suggestion_context import environment_setup


def actions(service):
    return [(e['action'], e['reason']) for e in reversed(service.feedback_events()['events'])]


def test_repeated_polling_is_not_new_exposure_or_feedback():
    service, _, _, _, _ = setup()
    service.create_suggestions()
    for _ in range(3):
        service.create_suggestions()
        service.pending()
        service.feedback_events()
    assert actions(service) == [('created', 'habit_pattern')]
    event, = service.feedback_events()['events']
    assert event['occurrences'] == 3
    assert '3일' in event['evidence']


@pytest.mark.parametrize('mute,action,reason', [(False, 'dismissed', 'user_skip'), (True, 'muted', 'user_mute')])
def test_user_choices_are_explicit_and_not_duplicated(mute, action, reason):
    service, _, _, _, _ = setup()
    service._suppression_store = InMemorySuppressionStore()
    card, = service.create_suggestions()
    service.reject(card.suggestion_id, mute=mute)
    with pytest.raises(UnknownSuggestionError):
        service.reject(card.suggestion_id, mute=mute)
    assert actions(service)[-1] == (action, reason)
    assert len(actions(service)) == 2


@pytest.mark.parametrize('cause,action,reason', [
    ('absent', 'withdrawn', 'presence_absent'),
    ('completed', 'withdrawn', 'already_completed'),
    ('expiry', 'expired', 'validity_ended'),
    ('deleted', 'withdrawn', 'appliance_removed'),
])
def test_system_changes_are_not_user_rejection(cause, action, reason):
    service, executor, _, clock, _ = setup()
    card, = service.create_suggestions()
    if cause == 'absent':
        service._presence_gate = lambda: False
    elif cause == 'completed':
        executor.execute_purpose('밥 데워줘', 'microwave')
    elif cause == 'expiry':
        clock.set(clock.now().replace(hour=10))
    else:
        service.drop_for_appliance('microwave')
    service.pending()
    service.pending()
    assert actions(service) == [('created', 'habit_pattern'), (action, reason)]


def test_environment_evidence_updates_are_not_new_feedback():
    service, _, _, _, readings = environment_setup()
    service.create_suggestions()
    readings[:] = [31, 75]
    service.pending()
    assert actions(service) == [('created', 'environment_condition')]
    readings[:] = [24, 50]
    service.pending()
    assert actions(service)[-1] == ('withdrawn', 'environment_unavailable')


def test_async_acceptance_has_job_id_but_does_not_claim_success():
    service, executor, _, _, _ = setup()
    card, = service.create_suggestions()
    job = service.approve_submit(card.suggestion_id)
    event = service.feedback_events()['events'][0]
    assert event['action'] == 'submitted'
    assert event['job_id'] == job
    assert event['execution_status'] is None
    assert actions(service)[-2] == ('approval_requested', 'user_approval')
    for _ in range(200):
        if not executor._running:
            break
        sleep(.01)


def test_sync_return_records_controller_result_separately():
    service, _, _, clock, _ = setup()
    card, = service.create_suggestions()
    service.approve(card.suggestion_id)
    event = service.feedback_events()['events'][0]
    assert event['action'] == 'execution_returned'
    assert event['execution_status'] == 'succeeded'
    clock.set(clock.now().replace(hour=10))
    service.pending()
    assert not any(action == 'expired' for action, _ in actions(service))


def test_submission_error_preserves_retry_without_exposing_exception_text():
    service, executor, _, _, _ = setup()
    card, = service.create_suggestions()
    def fail(*args, **kwargs):
        raise RuntimeError('secret-token-do-not-record')
    executor.submit_purpose = fail
    with pytest.raises(RuntimeError):
        service.approve_submit(card.suggestion_id)
    assert actions(service)[-1] == ('approval_failed', 'executor_error')
    assert service.pending() == (card,)
    assert 'secret-token' not in str(service.feedback_events())


def test_failure_at_final_gate_records_specific_retirement_reason():
    from rpi.intent.rules import RuleBasedIntentResolver
    service, executor, controller, _, _ = setup()
    present = [True]
    service._presence_gate = lambda: present[0]
    card, = service.create_suggestions()
    class Resolver(RuleBasedIntentResolver):
        def resolve(self, purpose):
            present[0] = False
            return super().resolve(purpose)
    executor._intent = Resolver()
    with pytest.raises(UnknownSuggestionError):
        service.approve_submit(card.suggestion_id)
    assert actions(service)[-2:] == [('approval_failed', 'presence_absent'), ('withdrawn', 'presence_absent')]
    assert controller.calls == []


def test_database_reopen_preserves_demo_label_and_evidence(tmp_path):
    path = str(tmp_path / 'feedback.db')
    db = SimpleLayDb(path)
    service, _, _, _, _ = setup()
    service._feedback = SuggestionFeedback(db.suggestion_events, db.append_suggestion_event)
    demo = service.create_demo_suggestion('밥 데워줘', appliance_id='microwave')
    service.reject(demo.suggestion_id)
    expected = service.feedback_events()
    db.close()
    db = SimpleLayDb(path)
    restored = SuggestionFeedback(db.suggestion_events, db.append_suggestion_event).recent()
    assert restored == expected
    assert all(e['origin'] == 'demo' for e in restored['events'])
    db.close()


def test_storage_failure_does_not_undo_dismissal_or_hide_missing_persistence():
    def fail(_):
        raise OSError('disk full')
    service, _, _, _, _ = setup()
    service._feedback = SuggestionFeedback(save=fail)
    card, = service.create_suggestions()
    service.reject(card.suggestion_id)
    assert service.pending() == ()
    history = service.feedback_events()
    assert history['persistent'] is True and history['persistence_ok'] is False
    assert history['events'][0]['action'] == 'dismissed'


def test_journal_is_bounded_in_memory_and_sqlite(tmp_path):
    db = SimpleLayDb(str(tmp_path / 'bounded.db'))
    service, _, _, clock, _ = setup()
    card, = service.create_suggestions()
    journal = SuggestionFeedback(db.suggestion_events, db.append_suggestion_event)
    for _ in range(EVENT_CAPACITY+3):
        journal.record(card, clock.now(), 'created', 'habit_pattern')
    assert len(db.suggestion_events()) == EVENT_CAPACITY
    assert len(journal._events) == EVENT_CAPACITY
    assert journal.recent(1)['events'][0] == db.suggestion_events()[-1]
    db.close()


def test_concurrent_dismissal_produces_one_user_feedback():
    service, _, _, _, _ = setup()
    card, = service.create_suggestions()
    def dismiss(_):
        try:
            service.reject(card.suggestion_id)
        except UnknownSuggestionError:
            pass
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(dismiss, range(4)))
    assert actions(service).count(('dismissed', 'user_skip')) == 1


def test_events_api_is_authenticated_bounded_and_read_only(monkeypatch):
    service, _, controller, clock, _ = setup()
    service.create_suggestions()
    clock.set(clock.now().replace(hour=10))
    app = FastAPI()
    app.include_router(router, dependencies=[Depends(require_api_key)])
    app.dependency_overrides[get_suggestion_service] = lambda: service
    monkeypatch.setenv('SIMPLELAY_API_KEY', 'test-key')
    with TestClient(app) as client:
        assert client.get('/suggestions/events').status_code == 401
        headers = {'X-API-Key': 'test-key'}
        response = client.get('/suggestions/events?limit=1', headers=headers)
        assert response.status_code == 200
        assert response.json()['events'][0]['action'] == 'created'
        assert client.get('/suggestions/events?limit=0', headers=headers).status_code == 422
        assert client.get('/suggestions/events?limit=201', headers=headers).status_code == 422
    assert len(actions(service)) == 1  # reading the journal did not expire it
    assert controller.calls == []


def test_simulated_environment_is_labeled_and_not_learning_feedback():
    from rpi.intent.environment import EnvironmentalSuggester
    from rpi.intent.models import UsageSource
    environment = EnvironmentalSuggester(lambda: (24, 50), demo_read=lambda: (31, 75))
    service, _, _, _, usage = setup(environmental=environment)
    card = next(s for s in service.create_suggestions() if s.time_band == '환경')
    assert '시연 데이터' in card.reason
    service.approve(card.suggestion_id)
    assert usage.records()[-1].source is UsageSource.DEMO
    events = [e for e in service.feedback_events()['events'] if e['suggestion_id'] == card.suggestion_id]
    assert all(e['origin'] == 'demo' for e in events)


def test_switching_from_demo_to_sensor_retires_old_environment_card():
    from rpi.intent.environment import EnvironmentalSuggester
    forced = [(31, 75)]
    environment = EnvironmentalSuggester(lambda: (31, 75), demo_read=lambda: forced[0])
    service, _, _, _, _ = setup(environmental=environment)
    old = next(s for s in service.create_suggestions() if s.time_band == '환경')
    forced[0] = None
    assert all(s.suggestion_id != old.suggestion_id for s in service.pending())
    assert actions(service)[-1] == ('withdrawn', 'environment_changed')
    new = next(s for s in service.create_suggestions() if s.time_band == '환경')
    assert new.suggestion_id != old.suggestion_id
    assert new.is_demo is False


def test_demo_environment_skip_does_not_suppress_real_environment():
    from rpi.intent.environment import EnvironmentalSuggester
    forced = [(31, 75)]
    environment = EnvironmentalSuggester(lambda: (31, 75), demo_read=lambda: forced[0])
    service, _, _, _, _ = setup(environmental=environment)
    demo = next(s for s in service.create_suggestions() if s.time_band == '환경')
    service.reject(demo.suggestion_id)
    forced[0] = None
    real = next(s for s in service.create_suggestions() if s.time_band == '환경')
    assert real.is_demo is False
    assert real.suggestion_id != demo.suggestion_id
