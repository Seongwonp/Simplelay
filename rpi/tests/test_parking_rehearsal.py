from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.simulator_router import router, require_simulator
from rpi.services.parking_rehearsal import ParkingRehearsal


@pytest.fixture
def client():
    app = FastAPI()
    app.include_router(router)
    controller = SimpleNamespace(parking_rehearsal=ParkingRehearsal())
    app.dependency_overrides[require_simulator] = lambda: controller
    return TestClient(app)


def event(client, kind, **kwargs):
    state = client.get('/simulator/parking/state').json()
    body = dict(session=state['session'], revision=state['revision'], event=kind, **kwargs)
    if kind in ('ack', 'fail'):
        body['action_id'] = state['pending']['id']
    response = client.post('/simulator/parking/event', json=body)
    assert response.status_code == 200, response.text
    return response.json()


def test_browser_event_contract_full_stop_and_park(client):
    assert client.get('/simulator/parking').status_code == 200
    for step in ('locate', 'begin', 'sequence_finished', 'ack', 'ack'):
        state = event(client, step)
    assert state['phase'] == 'waiting_above_stop'
    assert state['position'] == state['mapping']['stop']
    for step in ('stop', 'ack', 'ack'):
        state = event(client, step)
    assert state['stop_press_confirmed'] and not state['operation_ended']
    assert state['pending'] is None
    for step in ('ended', 'ack', 'ack'):
        state = event(client, step)
    assert state['phase'] == 'parked'
    assert state['position'] == state['mapping']['park']


def test_duplicate_or_other_tab_event_cannot_advance(client):
    old = client.get('/simulator/parking/state').json()
    body = dict(session=old['session'], revision=old['revision'], event='locate')
    assert client.post('/simulator/parking/event', json=body).status_code == 200
    assert client.post('/simulator/parking/event', json=body).status_code == 409
    new = event(client, 'new', stop_x=.2, stop_y=.5, park_x=.6, edge='bottom')
    assert new['session'] != old['session']
    assert new['mapping']['park'] == [.6, 1]
    body['revision'] = new['revision']
    assert client.post('/simulator/parking/event', json=body).status_code == 409


def test_failed_z_and_link_loss_lock_without_issuing_more_actions(client):
    for step in ('locate', 'begin', 'sequence_finished', 'fail'):
        state = event(client, step)
    assert state['phase'] == 'locked_manual_recovery_required'
    body = dict(session=state['session'], revision=state['revision'], event='ended')
    assert client.post('/simulator/parking/event', json=body).status_code == 422
    after = client.get('/simulator/parking/state').json()
    assert state == after
    event(client, 'new')
    state = event(client, 'link_lost')
    assert state['phase'] == 'locked_manual_recovery_required'
    assert not state['actions']


@pytest.mark.parametrize('extra', [dict(stop_x=True), dict(stop_y=2), dict(park_x=-1),
                                    dict(edge='left'), dict(unexpected=1)])
def test_invalid_mapping_request_is_rejected_without_reset(client, extra):
    old = client.get('/simulator/parking/state').json()
    body = dict(session=old['session'], revision=old['revision'], event='new', **extra)
    assert client.post('/simulator/parking/event', json=body).status_code == 422
    assert client.get('/simulator/parking/state').json() == old
