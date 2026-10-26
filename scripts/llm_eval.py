"""기기 안 언어 모델 말 알아듣기 평가 — 허브에서 잰 결과를 채점해 표로 남긴다.

1) 허브 백엔드 컨테이너 안에서 scripts/llm_eval_hub.py를 돌린다(understand()만 직접 부름 —
   키오스크·폰 확인 질문을 만들지 않는다. 사용자용 HTTP 경로는 쓰지 않는다):

    docker exec -i <백엔드 컨테이너> python /tmp/llm_eval_hub.py /tmp/llm_eval_ko.jsonl > out.jsonl

2) 이 PC에서 채점:

    python scripts/llm_eval.py --results out.jsonl --out result.md [--csv result.csv]

- 문장 묶음: rpi/intent/eval/llm_eval_ko.jsonl (group: indirect·direct·negation·out_of_list·ambiguous).
- ``score()``·``judge()``는 네트워크 없는 순수 함수다(rpi/tests/test_llm_eval_score.py).
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CASES = ROOT / 'rpi' / 'intent' / 'eval' / 'llm_eval_ko.jsonl'
MAPPABLE = ('indirect', 'direct')
MUST_REFUSE = ('negation', 'out_of_list')


def load_cases(path=DEFAULT_CASES):
    with open(path, encoding='utf-8') as f:
        return [json.loads(line) for line in f if line.strip()]


def judge(case, result):
    """한 문장 판정: 'correct' | 'wrong_action' | 'missed' | 'false_accept' | 'refused' | 'timeout' | 'error'.

    제한 시간에 걸린 문장은 서버처럼 '고르지 않음'이지만 따로 센다(거절·놓침으로 섞지 않는다).
    """
    if result.get('error'):
        return 'error'
    if result.get('timeout') and not result.get('understood'):
        return 'timeout'
    chosen = result.get('label') if result.get('understood') else None
    if case['expect'] == 'action':
        if chosen is None:
            return 'missed'
        return 'correct' if chosen in case['accept'] else 'wrong_action'
    return 'false_accept' if chosen is not None else 'refused'


def _pct(n, d):
    return round(100.0 * n / d, 1) if d else None


def _quantile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(round(q * (len(ordered) - 1)))))
    return ordered[index]


def score(rows):
    """rows: [{'case': case, 'result': dict, 'latency_s': float}] -> 요약 dict."""
    verdicts = [(r['case']['group'], judge(r['case'], r['result'])) for r in rows]
    by_group = {}
    for group, verdict in verdicts:
        by_group.setdefault(group, {}).setdefault(verdict, 0)
        by_group[group][verdict] += 1
    mappable = [v for g, v in verdicts if g in MAPPABLE]
    refuse = [v for g, v in verdicts if g in MUST_REFUSE]
    ambiguous = [v for g, v in verdicts if g == 'ambiguous']
    ok = [r for r in rows if not r['result'].get('error')]
    llm = [r['latency_s'] for r in ok if r['result'].get('source') == 'llm']
    every = [r['latency_s'] for r in ok]
    return {
        'total': len(rows),
        'errors': sum(v == 'error' for _, v in verdicts),
        'timeouts': sum(v == 'timeout' for _, v in verdicts),
        'mappable_n': len(mappable),
        'mappable_correct': mappable.count('correct'),
        'mappable_accuracy_pct': _pct(mappable.count('correct'), len(mappable)),
        'mappable_wrong_action': mappable.count('wrong_action'),
        'mappable_missed': mappable.count('missed'),
        'mappable_timeout': mappable.count('timeout'),
        'refuse_n': len(refuse),
        'false_accept': refuse.count('false_accept'),
        'false_accept_rate_pct': _pct(refuse.count('false_accept'), len(refuse)),
        'refuse_timeout': refuse.count('timeout'),
        'ambiguous_n': len(ambiguous),
        'ambiguous_guessed': ambiguous.count('false_accept'),
        'by_group': by_group,
        'source_counts': {s: sum(r['result'].get('source') == s for r in ok)
                          for s in sorted({r['result'].get('source') for r in ok} - {None})},
        'latency_llm_n': len(llm),
        'latency_llm_median_s': round(statistics.median(llm), 2) if llm else None,
        'latency_llm_p90_s': round(_quantile(llm, 0.9), 2) if llm else None,
        'latency_llm_max_s': round(max(llm), 2) if llm else None,
        'latency_all_median_s': round(statistics.median(every), 2) if every else None,
    }


def write_outputs(rows, summary, out_md, out_csv=None):
    lines = ['| id | 묶음 | 문장 | 기대 | 고른 동작 | 판정 | 출처 | 초 |', '|---|---|---|---|---|---|---|---|']
    for r in rows:
        c, res = r['case'], r['result']
        expect = ' / '.join(c['accept']) if c['expect'] == 'action' else '고르지 않음'
        chosen = res.get('label') if res.get('understood') else '-'
        lines.append(f"| {c['id']} | {c['group']} | {c['text']} | {expect} | {chosen} | "
                     f"{judge(c, res)} | {res.get('source', res.get('error', ''))} | {r['latency_s']:.1f} |")
    Path(out_md).write_text('```json\n' + json.dumps(summary, ensure_ascii=False, indent=2) + '\n```\n\n'
                            + '\n'.join(lines) + '\n', encoding='utf-8')
    if out_csv:
        with open(out_csv, 'w', encoding='utf-8-sig', newline='') as f:
            w = csv.writer(f)
            w.writerow(['id', 'group', 'text', 'accept', 'chosen', 'verdict', 'source', 'latency_s'])
            for r in rows:
                c, res = r['case'], r['result']
                w.writerow([c['id'], c['group'], c['text'], '|'.join(c['accept']),
                            res.get('label') if res.get('understood') else '', judge(c, res),
                            res.get('source', res.get('error', '')), f"{r['latency_s']:.2f}"])


def main(argv=None):
    p = argparse.ArgumentParser(description='말 알아듣기 평가 채점')
    p.add_argument('--results', required=True, help='llm_eval_hub.py 출력(jsonl)')
    p.add_argument('--out', required=True, help='결과 표(markdown) 경로')
    p.add_argument('--csv', help='CSV도 남길 경로')
    p.add_argument('--cases', default=str(DEFAULT_CASES))
    args = p.parse_args(argv)
    cases = {c['id']: c for c in load_cases(args.cases)}
    rows = []
    with open(args.results, encoding='utf-8') as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            rows.append({'case': cases[r['id']], 'result': r, 'latency_s': r['latency_s']})
    missing = set(cases) - {r['case']['id'] for r in rows}
    if missing:
        sys.exit(f'결과에 없는 문장: {sorted(missing)}')
    summary = score(rows)
    write_outputs(rows, summary, args.out, args.csv)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
