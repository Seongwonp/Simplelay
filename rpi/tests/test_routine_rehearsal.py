from types import SimpleNamespace
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.simulator_router import router, require_simulator
from rpi.api.deps import get_service
from rpi.services.routine_rehearsal import RoutineRehearsal
from rpi.services.parking_rehearsal import StaleRehearsal


def send(model, event, selected=None):
    s = model.snapshot()
    return model.event(s['session'], s['revision'], event, selected)


def started():
    m = RoutineRehearsal()
    send(m, 'review', ['purifier', 'fan'])
    send(m, 'approve')
    return m


def test_exclusion_requires_new_review_and_old_approval_is_invalid():
    m = RoutineRehearsal()
    with pytest.raises(ValueError):
        send(m, 'approve')
    old = send(m, 'review', ['purifier', 'fan'])
    new = send(m, 'review', ['purifier'])
    assert [i['status'] for i in new['items']] == ['not_started', 'excluded']
    with pytest.raises(StaleRehearsal):
        m.event(old['session'], old['revision'], 'approve')
    send(m, 'approve')
    s = send(m, 'success')
    assert s['phase'] == 'completed'
    assert s['items'][1]['receipt'] == 'not_dispatched'


def test_two_successes_are_independent_and_reads_do_not_advance():
    m = started()
    first = m.snapshot()
    assert m.snapshot() == first
    s = send(m, 'success')
    assert [i['status'] for i in s['items']] == ['succeeded', 'running']
    assert send(m, 'success')['phase'] == 'completed'


@pytest.mark.parametrize('event,status', [('failure', 'failed'), ('link_lost', 'unconfirmed')])
def test_second_fault_preserves_first_success_without_retry(event, status):
    m = started()
    send(m, 'success')
    s = send(m, event)
    assert [i['status'] for i in s['items']] == ['succeeded', status]
    with pytest.raises(ValueError):
        send(m, 'approve')
    assert m.snapshot() == s


def test_first_fault_cancels_second_without_dispatch():
    m = started()
    s = send(m, 'link_lost')
    assert s['items'][1]['status'] == 'cancelled'
    assert s['items'][1]['receipt'] == 'not_dispatched'


@pytest.mark.parametrize('outcome,status', [('stop_confirmed', 'stopped'), ('success', 'succeeded'), ('link_lost', 'unconfirmed')])
def test_stop_request_is_not_confirmation_and_does_not_overwrite_late_success(outcome, status):
    m = started()
    s = send(m, 'stop')
    assert s['phase'] == 'stopping' and s['items'][0]['status'] == 'running'
    assert s['items'][1]['status'] == 'cancelled'
    s = send(m, outcome)
    assert s['items'][0]['status'] == status
    assert s['items'][1]['receipt'] == 'not_dispatched'


def test_inflight_reset_edit_and_unrequested_stop_confirmation_are_rejected():
    m = started()
    old = m.snapshot()
    for kind in ['reset', 'review', 'stop_confirmed']:
        with pytest.raises(ValueError):
            send(m, kind, ['fan'] if kind == 'review' else None)
        assert m.snapshot() == old


def test_concurrent_approval_starts_once_and_reset_forgets_no_preferences():
    m = RoutineRehearsal()
    s = send(m, 'review', ['purifier'])
    def approve(_):
        try:
            m.event(s['session'], s['revision'], 'approve')
            return True
        except StaleRehearsal:
            return False
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sum(pool.map(approve, range(2))) == 1
    send(m, 'success')
    new = send(m, 'reset')
    assert new['session'] != s['session']
    assert all(i['selected'] for i in new['items'])


def test_api_validates_selection_and_refuses_non_simulator():
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_service] = lambda: SimpleNamespace(_controller=object())
    with TestClient(app) as c:
        assert c.get('/simulator/routine').status_code == 404
        m = RoutineRehearsal()
        app.dependency_overrides[require_simulator] = lambda: SimpleNamespace(routine_rehearsal=m)
        assert c.get('/simulator/routine').status_code == 200
        s = c.get('/simulator/routine/state').json()
        for selected in [[], ['fan', 'fan'], ['unknown'], [True]]:
            body = dict(session=s['session'], revision=s['revision'], event='review', selected=selected)
            assert c.post('/simulator/routine/event', json=body).status_code == 422
            assert m.snapshot() == s
        body.update(event='approve', selected=['fan'])
        assert c.post('/simulator/routine/event', json=body).status_code == 422
