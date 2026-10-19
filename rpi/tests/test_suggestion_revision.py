from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from time import sleep

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.deps import get_suggestion_service
from rpi.api.router import router
from rpi.intent.rules import RuleBasedIntentResolver, UnknownIntentError
from rpi.intent.suggestions import UnknownSuggestionError
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.tests.test_completed_actions import setup


def prepared():
    service, executor, controller, clock, usage = setup()
    executor._appliance_registry = ApplianceRegistry()
    card, = service.create_suggestions()
    return service, executor, controller, clock, usage, card


def test_shared_power_label_does_not_offer_aircon_action_on_induction():
    _, executor, _, _, _, _ = prepared()
    assert executor.revision_options('induction') == {}


def test_revision_invalidates_original_without_execution_or_learning():
    svc, _, controller, _, usage, old = prepared()
    before = usage.records()
    new = svc.revise(old.suggestion_id, '30초 돌려줘')
    assert new.appliance_id == old.appliance_id
    assert new.expires_at == old.expires_at
    assert new.steps == ('30초', '시작')
    assert new.revised_from == old.suggestion_id
    assert new.occurrences == 0
    assert controller.calls == [] and usage.records() == before
    with pytest.raises(UnknownSuggestionError):
        svc.approve_submit(old.suggestion_id)
    assert svc.create_suggestions() == ()
    assert svc.pending() == (new,)


def test_new_approval_executes_reviewed_sequence_once():
    svc, executor, controller, _, _, old = prepared()
    new = svc.revise(old.suggestion_id, '30초 돌려줘')
    job = svc.approve_submit(new.suggestion_id)
    for _ in range(100):
        if not executor._running:
            break
        sleep(.01)
    assert controller.calls == [('30초', '시작')]
    # 다시 보낸 승인은 같은 실행 번호만 돌려주고 다시 누르지 않는다(승인 영수증, 검토 10/19 A).
    assert svc.approve_submit(new.suggestion_id) == job
    sleep(.05)
    assert controller.calls == [('30초', '시작')]


@pytest.mark.parametrize('method', ['approve', 'approve_submit'])
def test_reinterpretation_cannot_change_approved_buttons(method):
    svc, executor, controller, _, _, old = prepared()
    new = svc.revise(old.suggestion_id, '30초 돌려줘')
    executor._intent = RuleBasedIntentResolver({'30초 돌려줘': ('5분', '시작')})
    with pytest.raises(UnknownIntentError):
        getattr(svc, method)(new.suggestion_id)
    assert controller.calls == []


@pytest.mark.parametrize('purpose', ['없는 동작', '에어컨 켜줘', '즉석밥 데워줘'])
def test_invalid_or_unchanged_choice_preserves_original(purpose):
    svc, _, controller, _, _, old = prepared()
    with pytest.raises(UnknownIntentError):
        svc.revise(old.suggestion_id, purpose)
    assert svc.pending() == (old,) and controller.calls == []


def test_expiry_is_not_extended_and_presence_is_rechecked():
    svc, _, controller, clock, _, old = prepared()
    new = svc.revise(old.suggestion_id, '30초 돌려줘')
    svc._presence_gate = lambda: False
    with pytest.raises(UnknownSuggestionError):
        svc.approve_submit(new.suggestion_id)
    svc._presence_gate = lambda: True
    clock.set(old.expires_at + timedelta(seconds=1))
    assert svc.pending() == () and controller.calls == []


def test_parallel_edits_only_one_wins():
    svc, _, controller, _, _, old = prepared()
    def edit(purpose):
        try:
            return svc.revise(old.suggestion_id, purpose)
        except UnknownSuggestionError:
            return None
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(edit, ['30초 돌려줘', '1분 돌려줘']))
    assert sum(r is not None for r in results) == 1
    assert len(svc.pending()) == 1 and controller.calls == []


def test_api_revision_cannot_change_target_and_returns_new_preview():
    svc, _, controller, _, _, old = prepared()
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_suggestion_service] = lambda: svc
    with TestClient(app) as client:
        path = f'/suggestions/{old.suggestion_id}'
        assert '30초 돌려줘' in client.get(path + '/revision-options').json()['options']
        assert client.post(path + '/revise', json={'purpose': '30초 돌려줘', 'appliance_id': 'other'}).status_code == 422
        response = client.post(path + '/revise', json={'purpose': '30초 돌려줘'})
        assert response.status_code == 200
        assert response.json()['id'] != old.suggestion_id
        assert response.json()['steps'] == ['30초', '시작']
        assert client.post(path + '/approve').status_code == 404
    assert controller.calls == []
