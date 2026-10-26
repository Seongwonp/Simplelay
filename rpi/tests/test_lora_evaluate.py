import pytest

from scripts.lora import evaluate
from scripts.lora.evaluate import local_url, summarize


def test_evaluation_only_allows_local_loopback():
    assert local_url('http://127.0.0.1:18081') == 'http://127.0.0.1:18081/v1/chat/completions'
    with pytest.raises(ValueError, match='loopback'):
        local_url('https://example.invalid')


def test_summary_separates_action_and_false_acceptance():
    rows = [
        {'mode': 'model_only', 'set': 'main', 'group': 'direct', 'expect': 'action',
         'correct': True, 'label': 'a', 'error': False},
        {'mode': 'model_only', 'set': 'main', 'group': 'negation', 'expect': 'none',
         'correct': False, 'label': 'a', 'error': False},
        {'mode': 'rules_model', 'set': 'holdout', 'group': 'out_of_list', 'expect': 'none',
         'correct': True, 'label': None, 'error': False},
    ]
    result = summarize(rows)
    assert result['model_only']['main']['action_correct'] == 1
    assert result['model_only']['main']['forbidden_false_accept'] == 1
    assert result['rules_model']['holdout']['forbidden_false_accept'] == 0
    assert result['rules_model']['holdout2']['rows'] == 0


def test_frozen_second_holdout_is_included_before_demo_repetitions():
    cases = evaluate.load_cases()
    assert sum(group == 'main' for group, _ in cases) == 50
    assert sum(group == 'holdout' for group, _ in cases) == 12
    assert sum(group == 'holdout2' for group, _ in cases) == 30
    assert sum(group == 'demo' for group, _ in cases) == 20
