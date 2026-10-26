"""scripts/llm_eval.py 채점 함수 — 네트워크 없이."""
import importlib.util
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location('llm_eval', _ROOT / 'scripts' / 'llm_eval.py')
llm_eval = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(llm_eval)


def _case(group, accept=()):
    return {'id': 'x', 'group': group, 'text': 't', 'expect': 'action' if accept else 'none',
            'accept': list(accept)}


def _row(case, label=None, source='llm', latency=1.0, error=None):
    result = {'error': error} if error else {'understood': label is not None, 'label': label, 'source': source}
    return {'case': case, 'result': result, 'latency_s': latency}


def test_judge_verdicts():
    on = _case('indirect', ['켜기'])
    assert llm_eval.judge(on, {'understood': True, 'label': '켜기'}) == 'correct'
    assert llm_eval.judge(on, {'understood': True, 'label': '끄기'}) == 'wrong_action'
    assert llm_eval.judge(on, {'understood': False, 'label': None}) == 'missed'
    neg = _case('negation')
    assert llm_eval.judge(neg, {'understood': True, 'label': '켜기'}) == 'false_accept'
    assert llm_eval.judge(neg, {'understood': False, 'label': None}) == 'refused'
    assert llm_eval.judge(neg, {'error': 'URLError'}) == 'error'
    # 시간 초과는 거절·놓침과 섞지 않는다.
    assert llm_eval.judge(on, {'understood': False, 'label': None, 'timeout': True}) == 'timeout'
    assert llm_eval.judge(neg, {'understood': False, 'label': None, 'timeout': True}) == 'timeout'


def test_timeouts_counted_separately():
    rows = [_row(_case('indirect', ['켜기']), None, latency=20),
            _row(_case('negation'), None, latency=20)]
    for r in rows:
        r['result']['timeout'] = True
    s = llm_eval.score(rows)
    assert (s['timeouts'], s['mappable_timeout'], s['refuse_timeout']) == (2, 1, 1)
    assert s['mappable_missed'] == 0 and s['false_accept'] == 0 and s['mappable_accuracy_pct'] == 0.0


def test_score_summary():
    rows = [
        _row(_case('indirect', ['켜기']), '켜기', latency=8),
        _row(_case('indirect', ['켜기']), '끄기', latency=10),
        _row(_case('direct', ['끄기']), '끄기', source='rules', latency=0.1),
        _row(_case('direct', ['끄기']), None, latency=12),
        _row(_case('negation'), None, source='rules', latency=0.1),
        _row(_case('out_of_list'), '켜기', latency=9),
        _row(_case('ambiguous'), '켜기', latency=11),
        _row(_case('out_of_list'), error='TimeoutError', latency=60),
    ]
    s = llm_eval.score(rows)
    assert (s['mappable_n'], s['mappable_correct'], s['mappable_accuracy_pct']) == (4, 2, 50.0)
    assert (s['mappable_wrong_action'], s['mappable_missed']) == (1, 1)
    # 오류도 분모에 든다 — 거절로 세지 않는다.
    assert (s['refuse_n'], s['false_accept'], s['false_accept_rate_pct']) == (3, 1, 33.3)
    assert s['ambiguous_guessed'] == 1 and s['errors'] == 1
    assert s['latency_llm_n'] == 5 and s['latency_llm_median_s'] == 10
    assert s['latency_llm_p90_s'] == 12
    assert s['source_counts'] == {'llm': 5, 'rules': 2}


def test_fixed_set_shape():
    cases = llm_eval.load_cases()
    assert len(cases) == 50
    assert len({c['id'] for c in cases}) == 50
    groups = [c['group'] for c in cases]
    assert {g: groups.count(g) for g in set(groups)} == {
        'indirect': 20, 'direct': 10, 'negation': 8, 'out_of_list': 8, 'ambiguous': 4}
    for c in cases:
        assert (c['expect'] == 'action') == bool(c['accept'])
