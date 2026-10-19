"""Offline contest rehearsal: synthetic history and test controllers, no hardware."""
from datetime import timedelta
from time import sleep
from types import SimpleNamespace

from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from rpi.api.auth import require_api_key
from rpi.api.router import router
from rpi.api.deps import (
    EnvironmentOverride, get_appliance_registry, get_environment_override,
    get_presence_store, get_service, get_suggestion_service,
)
from rpi.intent.environment import EnvironmentalSuggester
from rpi.intent.models import UsageSource
from rpi.intent.suppression import InMemorySuppressionStore
from rpi.services.presence import PresenceStore
from rpi.tests.test_completed_actions import setup
from rpi.tests.test_learning_evidence import NOW


def wait_job(client, response):
    assert response.status_code == 200
    job_id = response.json()['job_id']
    for _ in range(200):
        status = client.get('/status').json()
        if status['last_job_id'] == job_id:
            assert status['last_status'] == 'succeeded'
            return job_id
        sleep(.005)
    raise AssertionError('test job did not finish')


def test_contest_rehearsal_learning_consent_context_and_trace(monkeypatch):
    forced = EnvironmentOverride()
    environment = EnvironmentalSuggester(lambda: (24, 50), demo_read=forced.current)
    suggestions, executor, controller, clock, usage = setup(environmental=environment)
    presence = PresenceStore(clock)
    suggestions._presence_gate = presence.allows_suggestions
    suggestions._suppression_store = InMemorySuppressionStore()
    app = FastAPI()
    app.include_router(router,
                       dependencies=[Depends(require_api_key)])
    app.dependency_overrides.update({
        get_service: lambda: executor,
        get_suggestion_service: lambda: suggestions,
        get_presence_store: lambda: presence,
        get_environment_override: lambda: forced,
        get_appliance_registry: lambda: SimpleNamespace(get=lambda _: object()),
    })
    monkeypatch.setenv('SIMPLELAY_API_KEY', 'rehearsal-key')
    with TestClient(app) as client:
        client.headers['X-API-Key'] = 'rehearsal-key'
        # Fixture supplies three synthetic real/direct days; this is NOT a
        # measurement of actual household learning or physical success.
        learning = client.get('/learning').json()
        assert learning['routines'][0]['distinct_days'] == 3
        assert learning['routines'][0]['established'] is True
        suggestions.create_suggestions()  # deterministic scheduler tick
        first, = client.get('/suggestions').json()
        assert '3일' in first['reason']
        assert controller.calls == []  # creating/showing never moves anything

        assert client.post(f"/suggestions/{first['id']}/reject", json={'mute': False}).status_code == 200
        suggestions.create_suggestions()
        assert client.get('/suggestions').json() == []
        assert controller.calls == []

        clock.set(NOW+timedelta(days=1))
        suggestions.create_suggestions()
        approved, = client.get('/suggestions').json()
        job = wait_job(client, client.post(f"/suggestions/{approved['id']}/approve"))
        # 다시 보낸 승인은 같은 job_id(승인 영수증, 검토 10/19 A) — 다시 실행하지 않는다.
        retry = client.post(f"/suggestions/{approved['id']}/approve")
        assert retry.status_code == 200 and retry.json()['job_id'] == job
        assert len(controller.calls) == 1
        assert usage.records()[-1].source is UsageSource.SUGGESTION
        assert client.get('/learning').json()['routines'][0]['occurrences'] == 3

        clock.set(NOW+timedelta(days=2))
        suggestions.create_suggestions()
        completed, = client.get('/suggestions').json()
        wait_job(client, client.post('/execute-buttons', json={
            'appliance_id': 'microwave', 'buttons': ['즉석밥', '시작']}))
        assert client.get('/suggestions').json() == []
        assert client.post(f"/suggestions/{completed['id']}/approve").status_code == 404
        assert len(usage.records()) == 4  # raw buttons do not invent a purpose

        clock.set(NOW+timedelta(days=3))
        suggestions.create_suggestions()
        absent, = client.get('/suggestions').json()
        assert client.post('/presence', json={'present': False, 'source': 'rehearsal'}).status_code == 200
        assert client.get('/suggestions').json() == []
        assert client.post(f"/suggestions/{absent['id']}/approve").status_code == 404
        client.post('/presence', json={'present': True, 'source': 'rehearsal'})
        suggestions.create_suggestions()
        muted, = client.get('/suggestions').json()
        client.post(f"/suggestions/{muted['id']}/reject", json={'mute': True})
        suggestions.create_suggestions()
        assert client.get('/suggestions').json() == []

        clock.set(clock.now().replace(hour=15))
        env_response = client.post('/demo/environment', json={'temperature': 31, 'humidity': 75})
        assert env_response.status_code == 200
        env_card, = env_response.json()
        assert '시연 데이터' in env_card['reason']
        client.post('/demo/environment', json={'temperature': 24, 'humidity': 50})
        assert client.get('/suggestions').json() == []
        assert client.post(f"/suggestions/{env_card['id']}/approve").status_code == 404
        assert len(controller.calls) == 2

        # Explicit rehearsal stays available; its acceptance never counts as
        # another natural habit. The controller remains a test double.
        demo = client.post('/demo/suggest', json={
            'purpose': '에어컨 켜줘', 'appliance_id': 'aircon'}).json()
        wait_job(client, client.post(f"/suggestions/{demo['id']}/approve"))
        assert usage.records()[-1].source is UsageSource.DEMO
        history = client.get('/suggestions/events?limit=200').json()
        events = history['events']
        reasons = {e['reason'] for e in events}
        assert {'user_skip', 'user_mute', 'already_completed', 'presence_absent',
                'environment_unavailable', 'job_accepted'} <= reasons
        submitted = next(e for e in events if e['job_id'] == job)
        assert submitted['action'] == 'submitted'
        assert submitted['execution_status'] is None
        assert all(e['origin'] == 'demo' for e in events if e['suggestion_id'] == env_card['id'])
        assert len({e['event_id'] for e in events}) == len(events)
        assert history['persistent'] is False
