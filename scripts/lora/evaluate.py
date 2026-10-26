"""Compare a local GGUF server with and without the live intent guards.

This is read-only: it never calls the user-facing intent endpoint or executes
an action. Run a local llama.cpp OpenAI-compatible server separately, then pass
its loopback URL. Evaluation examples are loaded from existing fixtures.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from rpi.intent.llm_intent import LlmIntentConfig, build_prompt, parse_choice, understand
from scripts.llm_eval_hub import CHOICES
from scripts.lora.train import outside_repo


REPO_ROOT = Path(__file__).resolve().parents[2]
EVAL_DIR = REPO_ROOT / 'rpi' / 'intent' / 'eval'


def local_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != 'http' or parsed.hostname not in {'127.0.0.1', 'localhost'}:
        raise ValueError('evaluation server must be a local HTTP loopback address')
    return value.rstrip('/') + '/v1/chat/completions'


def ask(url: str, messages: list[dict], timeout: float) -> tuple[str, float]:
    start = time.monotonic()
    payload = json.dumps({'messages': messages, 'stream': False, 'max_tokens': 8},
                         ensure_ascii=False).encode('utf-8')
    request = Request(url, payload, {'Content-Type': 'application/json'}, method='POST')
    with urlopen(request, timeout=timeout) as response:
        data = json.load(response)
    return data['choices'][0]['message']['content'], time.monotonic() - start


def run_case(case: dict, url: str, timeout: float, mode: str) -> dict:
    text = case['text']
    start = time.monotonic()
    error = False
    if mode == 'model_only':
        try:
            reply, _ = ask(url, [{'role': 'system', 'content': build_prompt(CHOICES)},
                                 {'role': 'user', 'content': text}], timeout)
            choice_id = parse_choice(reply, len(CHOICES))
            label = CHOICES[choice_id - 1].label if choice_id else None
        except Exception:
            label = None
            error = True
        source = 'llm'
    else:
        def transport(_url, body, transport_timeout):
            nonlocal error
            try:
                reply, _ = ask(url, body['messages'], transport_timeout)
            except Exception:
                error = True
                raise
            return {'choices': [{'message': {'content': reply}}]}

        result = understand(text, CHOICES, LlmIntentConfig('local', timeout), transport)
        label = result['label']
        source = result['source']
    return {'id': case['id'], 'group': case['group'], 'expect': case['expect'],
            'mode': mode, 'label': label, 'correct': not error and
            (label in case['accept'] if case['expect'] == 'action' else label is None),
            'source': source, 'error': error,
            'latency_s': round(time.monotonic() - start, 3)}


def summarize(rows: list[dict]) -> dict:
    result = {}
    for mode in ('model_only', 'rules_model'):
        subset = [row for row in rows if row['mode'] == mode]
        result[mode] = {}
        for group in ('main', 'holdout', 'demo'):
            part = [row for row in subset if row['set'] == group]
            actionable = [row for row in part if row['expect'] == 'action']
            forbidden = [row for row in part if row['expect'] == 'none'
                         and row['group'] in {'negation', 'out_of_list'}]
            ambiguous = [row for row in part if row['group'] == 'ambiguous']
            result[mode][group] = {
                'action_correct': sum(row['correct'] for row in actionable),
                'action_total': len(actionable),
                'forbidden_false_accept': sum(row['label'] is not None for row in forbidden),
                'forbidden_total': len(forbidden),
                'ambiguous_false_accept': sum(row['label'] is not None for row in ambiguous),
                'ambiguous_total': len(ambiguous),
                'errors': sum(row['error'] for row in part),
                'rows': len(part),
            }
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', default='http://127.0.0.1:18081')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=30)
    options = parser.parse_args()
    url = local_url(options.server)
    output = outside_repo(options.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    cases = []
    for label, name in [('main', 'llm_eval_ko.jsonl'),
                        ('holdout', 'llm_eval_ko_holdout.jsonl')]:
        with (EVAL_DIR / name).open(encoding='utf-8') as stream:
            cases.extend((label, json.loads(line)) for line in stream if line.strip())
    # Repeat the designated demo case without copying its wording into this script.
    demo = next(case for group, case in cases if group == 'main' and case['id'] == 'ind01')
    cases.extend(('demo', {**demo, 'id': f'demo{i:02d}'}) for i in range(1, 21))
    rows = []
    for group, case in cases:
        for mode in ('model_only', 'rules_model'):
            row = run_case(case, url, options.timeout, mode)
            row['set'] = group
            rows.append(row)
            print(json.dumps(row, ensure_ascii=False), flush=True)
    output.write_text(json.dumps({'summary': summarize(rows), 'rows': rows},
                                 ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(summarize(rows), ensure_ascii=False), flush=True)
    if any(row['error'] for row in rows):
        raise SystemExit('evaluation incomplete: model server errors; do not compare scores')


if __name__ == '__main__':
    main()
