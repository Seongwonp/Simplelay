import logging
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from rpi.services.appliance_registry import ApplianceRegistry, BUILTIN_APPLIANCES
from rpi.api.deps import get_appliance_registry, get_service, get_node_registry
from rpi.main import app


@pytest.fixture(autouse=True)
def feature_module():
    # Import per case so removing the feature yields a failure for every new test, not one collection failure.
    from rpi.intent import llm_intent
    for name in ('IntentChoice', 'LlmIntentConfig', 'build_choices', 'build_prompt', 'parse_choice', 'understand'):
        globals()[name] = getattr(llm_intent, name)


def choice():
    return IntentChoice('즉석밥 데우기', 'reheat instant rice (microwave)',
                        {'kind': 'buttons', 'appliance_id': 'microwave', 'buttons': ['즉석밥', '시작']})


@pytest.mark.parametrize('text,expected', [('3', 3), (' 3.', 3), ('번호: 4', 4),
    ('0', 0), ('9', 0), ('', 0), ('garbage', 0), ('-1', 0), ('99 3', 0)])
def test_parser(text, expected):
    assert parse_choice(text, 4) == expected


def test_prompt_is_numbered_closed_list():
    prompt = build_prompt([choice()])
    assert '1 reheat instant rice (microwave)' in prompt
    assert 'number only' in prompt and '0 none' in prompt
    assert 'buttons' not in prompt


def test_config_off_and_timeout(monkeypatch):
    monkeypatch.delenv('SIMPLELAY_LLM_URL', raising=False)
    assert not LlmIntentConfig.from_env().url
    monkeypatch.setenv('SIMPLELAY_LLM_URL', 'http://localhost:8080/')
    monkeypatch.setenv('SIMPLELAY_LLM_TIMEOUT_SECONDS', '7')
    assert LlmIntentConfig.from_env() == LlmIntentConfig('http://localhost:8080', 7)


def test_no_calls_when_off():
    def forbidden(*args):
        pytest.fail('disabled feature called transport')
    assert understand('밥', [choice()], LlmIntentConfig(), forbidden)['source'] == 'off'


def test_transport_and_no_text_logging(caplog):
    calls = []
    def transport(url, body, timeout):
        calls.append((url, body, timeout))
        return {'choices': [{'message': {'content': '1'}}]}
    with caplog.at_level(logging.INFO):
        result = understand('개인 발화 비밀', [choice()], LlmIntentConfig('http://localhost', 2), transport)
    assert result['understood'] and result['source'] == 'llm'
    assert result['action'] == choice().action
    assert result['question'] == '즉석밥 데우기를 할까요?'
    assert calls[0][0] == 'http://localhost/invoke'
    assert calls[0][1]['messages'][1]['content'] == '개인 발화 비밀'
    assert calls[0][1]['stream'] is False and calls[0][2] == 2
    assert '개인 발화 비밀' not in caplog.text


@pytest.mark.parametrize('failure', [TimeoutError(), OSError(), ValueError()])
def test_transport_failures_are_unknown(failure):
    def transport(*args):
        raise failure
    assert not understand('밥', [choice()], LlmIntentConfig('http://localhost'), transport)['understood']


@pytest.mark.parametrize('reply', [{}, {'choices': []}, {'choices': [{'message': {'content': '99'}}]}])
def test_bad_response_is_unknown(reply):
    assert not understand('밥', [choice()], LlmIntentConfig('http://localhost'), lambda *a: reply)['understood']


def test_dynamic_choices_filter_ready_and_cap():
    appliances = [replace(BUILTIN_APPLIANCES[0], appliance_id=f'a{i}') for i in range(25)]
    choices = build_choices(appliances, (), lambda a: a.appliance_id != 'a0',
                            lambda a: {'데우기': ('즉석밥', '시작')})
    assert len(choices) == 20
    assert all(c.action['appliance_id'] != 'a0' for c in choices)
    assert build_choices(appliances, (), lambda a: False, lambda a: {}) == ()


def test_registered_functions_and_profile_intersection():
    from rpi.services.thinq.bindings import air_purifier_binding
    from rpi.commands import ControlRoute
    a = replace(BUILTIN_APPLIANCES[0], appliance_id='air', name='거실 청정기',
        control_path=ControlRoute.THINQ, thinq=air_purifier_binding('private-device'))
    choices = build_choices([a], (), lambda a: True, lambda a: {},
        lambda a: {'set_power': {'allowed': ['POWER_ON']}})
    assert len(choices) == 1
    assert choices[0].action == {'kind': 'thinq', 'appliance_id': 'air', 'action': 'set_power', 'args': {'power': 'POWER_ON'}}
    assert 'private-device' not in build_prompt(choices)
    assert build_choices([a], (), lambda a: True, lambda a: {}) == ()


def test_routine_targets_and_fingerprint():
    from rpi.routines.model import Routine, RoutineStep
    a = BUILTIN_APPLIANCES[0]
    routine = Routine('saved', '밥 데우기', (RoutineStep('press_sequence', a.appliance_id, ('즉석밥', '시작')),))
    choices = build_choices([a], [routine], lambda a: True, lambda a: {})
    assert len(choices) == 1 and choices[0].action['kind'] == 'routine'
    assert choices[0].action['fingerprint'] == routine.steps_fingerprint()
    assert build_choices([], [routine], lambda a: True, lambda a: {}) == ()
    assert build_choices([a], [replace(routine, mode='notify')], lambda a: True, lambda a: {}) == ()


@pytest.mark.parametrize('text', ['멈춰', '켜지 마', '그만'])
def test_refused_phrases_never_call_model(text):
    def forbidden(*args):
        pytest.fail('negated/stop request sent to model')
    assert not understand(text, [choice()], LlmIntentConfig('http://localhost'), forbidden)['understood']


def test_exact_rules_skip_model_and_ambiguous_targets_do_not_guess():
    def forbidden(*args):
        pytest.fail('deterministic match sent to model')
    assert understand('즉석밥 데우기', [choice()], LlmIntentConfig('http://localhost'), forbidden)['source'] == 'rules'
    second = replace(choice(), action={'kind': 'buttons', 'appliance_id': 'second', 'buttons': ['시작']})
    assert not understand('즉석밥 데우기', [choice(), second], LlmIntentConfig('http://localhost'), forbidden)['understood']


def test_endpoint_off_auth_validation_and_no_execution(monkeypatch):
    monkeypatch.delenv('SIMPLELAY_LLM_URL', raising=False)
    client = TestClient(app)
    result = client.post('/intent/understand', json={'text': '밥'}).json()
    assert result == dict(understood=False, action=None, label=None, question=None, source='off')
    for text in ['', ' ' * 3, 'a' * 201]:
        assert client.post('/intent/understand', json={'text': text}).status_code == 422
    monkeypatch.delenv('SIMPLELAY_ALLOW_UNAUTHENTICATED', raising=False)
    monkeypatch.setenv('SIMPLELAY_API_KEY', 'test-only-key')
    assert client.post('/intent/understand', json={'text': '밥'}).status_code == 401


def test_heat_endpoint_returns_only_proposal(monkeypatch):
    from rpi.api import intent_router
    from types import SimpleNamespace
    registry = ApplianceRegistry()
    service = SimpleNamespace(revision_options=lambda aid: {'즉석밥 데우기': ('즉석밥', '시작')})
    monkeypatch.setenv('SIMPLELAY_LLM_URL', 'http://localhost')
    monkeypatch.setattr(intent_router, 'readiness_view', lambda *args: ('operable', [], True))
    monkeypatch.setattr(intent_router, 'builtin_appliances_visible', lambda: True)
    monkeypatch.setattr(intent_router, 'get_routine_store', lambda: SimpleNamespace(list=lambda: ()))
    monkeypatch.setattr('rpi.intent.llm_intent.http_transport', lambda *a: {'choices': [{'message': {'content': '1'}}]})
    app.dependency_overrides[get_service] = lambda: service
    app.dependency_overrides[get_appliance_registry] = lambda: registry
    app.dependency_overrides[get_node_registry] = lambda: None
    try:
        result = TestClient(app).post('/intent/understand', json={'text': '햇반 하나 돌려줘'}).json()
        assert result['understood'] is True
        assert result['action']['kind'] == 'buttons'
        assert '할까요?' in result['question']
        assert 'job_id' not in result
    finally:
        app.dependency_overrides.clear()
