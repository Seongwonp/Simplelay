from datetime import timedelta
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from rpi.api.auth import require_api_key
from rpi.api.deps import get_suggestion_service
from rpi.api.router import router
from rpi.intent.cooldowns import SuggestionCooldowns
from rpi.intent.suggestions import UnknownSuggestionError
from rpi.tests.test_completed_actions import setup


def test_pause_retires_old_approval_and_rechecks_at_deadline_without_execution():
    service, _, controller, clock, usage = setup()
    card, = service.create_suggestions()
    before = usage.records()
    service.snooze(card.suggestion_id)
    assert service.feedback_events()['events'][0]['action'] == 'snoozed'
    with pytest.raises(UnknownSuggestionError):
        service.approve_submit(card.suggestion_id)
    clock.set(clock.now() + timedelta(minutes=29, seconds=59))
    assert service.create_suggestions() == ()
    clock.set(clock.now() + timedelta(seconds=1))
    new, = service.create_suggestions()
    assert new.suggestion_id != card.suggestion_id
    assert controller.calls == []
    assert usage.records() == before


@pytest.mark.parametrize('cause', ['absent', 'ended_band', 'completed'])
def test_deadline_does_not_restore_invalid_context(cause):
    service, executor, controller, clock, _ = setup()
    card, = service.create_suggestions()
    service.snooze(card.suggestion_id)
    clock.set(clock.now() + timedelta(minutes=30))
    if cause == 'absent':
        service._presence_gate = lambda: False
    elif cause == 'ended_band':
        clock.set(clock.now().replace(hour=10))
    else:
        executor.execute_purpose('밥 데워줘', 'microwave')
    calls = list(controller.calls)
    assert service.create_suggestions() == ()
    assert controller.calls == calls


def test_pause_persistence_and_target_isolation():
    saved = []
    service, _, _, clock, _ = setup()
    service._cooldowns = SuggestionCooldowns(save=saved.append)
    card, = service.create_suggestions()
    service.snooze(card.suggestion_id)
    restored, _, _, _, _ = setup(now=clock.now())
    restored._cooldowns = SuggestionCooldowns(load=lambda: saved[-1])
    assert restored.create_suggestions() == ()
    assert not restored._cooldowns.blocked(
        restored._cooldowns.key(card.purpose, card.time_band, 'other'), clock.now())
    assert not restored._cooldowns.blocked(
        restored._cooldowns.key(card.purpose, 'other_band', card.appliance_id), clock.now())


def test_storage_failure_keeps_card_and_does_not_claim_pause():
    def fail(_):
        raise OSError('disk full')
    service, _, _, _, _ = setup()
    service._cooldowns = SuggestionCooldowns(save=fail)
    card, = service.create_suggestions()
    with pytest.raises(OSError):
        service.snooze(card.suggestion_id)
    assert service.pending() == (card,)
    assert service.feedback_events()['events'][0]['action'] == 'created'


def test_two_clients_pause_once():
    service, _, controller, _, _ = setup()
    card, = service.create_suggestions()
    def pause(_):
        try:
            service.snooze(card.suggestion_id)
            return True
        except UnknownSuggestionError:
            return False
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sum(pool.map(pause, range(2))) == 1
    assert controller.calls == []
    assert sum(e['action'] == 'snoozed' for e in service.feedback_events()['events']) == 1


def test_api_auth_and_stale_id(monkeypatch):
    service, _, controller, _, _ = setup()
    card, = service.create_suggestions()
    app = FastAPI()
    app.include_router(router, dependencies=[Depends(require_api_key)])
    app.dependency_overrides[get_suggestion_service] = lambda: service
    monkeypatch.setenv('SIMPLELAY_API_KEY', 'test-key')
    path = f'/suggestions/{card.suggestion_id}/snooze'
    with TestClient(app) as client:
        assert client.post(path).status_code == 401
        assert client.post(path, headers={'X-API-Key': 'test-key'}).status_code == 200
        assert client.post(path, headers={'X-API-Key': 'test-key'}).status_code == 404
    assert controller.calls == []
