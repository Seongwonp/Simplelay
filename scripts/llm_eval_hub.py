"""허브 백엔드 컨테이너 안에서 돌리는 말 알아듣기 평가 실행기(읽기만).

    python /tmp/llm_eval_hub.py /tmp/llm_eval_ko.jsonl > /tmp/llm_eval_out.jsonl
    python /tmp/llm_eval_hub.py /tmp/llm_eval_ko.jsonl --model-only > /tmp/llm_eval_model_only.jsonl

- 사용자용 경로(`POST /intent/understand`)를 쓰지 않는다 — 그 경로는 알아들을 때마다
  키오스크·폰에 확인 질문을 만든다. 여기서는 `understand()`만 직접 부른다.
- 서비스(`get_service()`)를 만들지 않는다. 고를 동작 목록은 2026-10-26 허브에 실제로
  있던 11개를 그대로 옮겨 적은 고정 사본이다(지금 허브 목록과 다를 수 있다).
- 언어 모델 서버 주소·제한 시간은 허브 env(`LlmIntentConfig.from_env()`) 그대로다.
  제한 시간에 걸린 문장은 `timeout: true`로 따로 표시한다(판정은 서버와 같이 '고르지 않음').
"""
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.getcwd())

from rpi.intent import llm_intent  # noqa: E402
from rpi.intent.llm_intent import (  # noqa: E402
    IntentChoice,
    LlmIntentConfig,
    build_prompt,
    parse_choice,
    understand,
)


def _thinq(label, description, action, arg, value, aliases, question):
    return IntentChoice(label, description, {'kind': 'thinq', 'appliance_id': 'air_purifier',
                                             'action': action, 'args': {arg: value}}, aliases, question)


CHOICES = (
    _thinq('공기청정기 전원 켜기', 'turn ON air purifier', 'set_power', 'power', 'POWER_ON',
           ('공기청정기 켜줘',), '공기청정기를 켤까요?'),
    _thinq('공기청정기 전원 끄기', 'turn OFF air purifier', 'set_power', 'power', 'POWER_OFF',
           ('공기청정기 꺼줘',), '공기청정기를 끌까요?'),
    _thinq('공기청정기 바람 세기 약', 'air purifier fan LOW', 'set_wind_strength', 'wind_strength', 'LOW',
           ('약풍으로 바꿔줘',), '공기청정기 바람을 약으로 할까요?'),
    _thinq('공기청정기 바람 세기 중', 'air purifier fan MID', 'set_wind_strength', 'wind_strength', 'MID',
           (), '공기청정기 바람을 중으로 할까요?'),
    _thinq('공기청정기 바람 세기 강', 'air purifier fan HIGH', 'set_wind_strength', 'wind_strength', 'HIGH',
           ('강풍으로 바꿔줘',), '공기청정기 바람을 강으로 할까요?'),
    _thinq('공기청정기 바람 세기 자동', 'air purifier fan AUTO', 'set_wind_strength', 'wind_strength', 'AUTO',
           ('자동으로 바꿔줘',), '공기청정기 바람을 자동으로 할까요?'),
    _thinq('공기청정기 운전 모드 청정', 'air purifier clean mode', 'set_job_mode', 'job_mode', 'CLEAN',
           (), '공기청정기를 청정 모드로 할까요?'),
    _thinq('공기청정기 운전 모드 수면', 'air purifier sleep mode', 'set_job_mode', 'job_mode', 'SLEEP',
           (), '공기청정기를 수면 모드로 할까요?'),
    _thinq('공기청정기 운전 모드 자동', 'air purifier auto mode', 'set_job_mode', 'job_mode', 'AUTO',
           (), '공기청정기를 자동 모드로 할까요?'),
    IntentChoice('저녁 공기청정기 켜기', 'saved routine', {'kind': 'routine', 'routine_id': 'eval-evening'},
                 ('저녁 공기청정기 켜기',), '저녁 공기청정기 켜기를 할까요?'),
    IntentChoice('아침 공기청정기 끄기', 'saved routine', {'kind': 'routine', 'routine_id': 'eval-morning'},
                 ('아침 공기청정기 끄기',), '아침 공기청정기 끄기를 할까요?'),
)


def main(path):
    config = LlmIntentConfig.from_env()
    model_only = len(sys.argv) > 2 and sys.argv[2] == '--model-only'
    if not config.url:
        sys.exit('SIMPLELAY_LLM_URL is empty')
    with open(path, encoding='utf-8') as f:
        cases = [json.loads(line) for line in f if line.strip()]
    for case in cases:
        timed_out = []

        def transport(url, body, timeout):
            try:
                return llm_intent.http_transport(url, body, timeout)
            except (TimeoutError, socket.timeout):
                timed_out.append(True)
                raise
            except OSError as exc:  # urllib가 시간 초과를 URLError로 감싸는 경우
                if isinstance(getattr(exc, 'reason', None), (TimeoutError, socket.timeout)):
                    timed_out.append(True)
                raise

        start = time.monotonic()
        if model_only:
            try:
                reply = transport(config.url + '/invoke', {
                    'messages': [{'role': 'system', 'content': build_prompt(CHOICES)},
                                 {'role': 'user', 'content': case['text']}],
                    'stream': False,
                }, config.timeout)
                choice_id = parse_choice(reply['choices'][0]['message']['content'], len(CHOICES))
                selected = CHOICES[choice_id - 1] if choice_id else None
                result = {'understood': selected is not None,
                          'label': selected.label if selected else None,
                          'source': 'llm'}
            except Exception:
                result = {'understood': False, 'label': None, 'source': 'llm', 'error': True}
        else:
            result = understand(case['text'], CHOICES, config, transport=transport)
        latency = time.monotonic() - start
        print(json.dumps({'id': case['id'], 'understood': result['understood'], 'label': result['label'],
                          'source': result['source'], 'timeout': bool(timed_out),
                          'error': bool(result.get('error')),
                          'latency_s': round(latency, 3)}, ensure_ascii=False), flush=True)
    print(json.dumps({'config_timeout_s': config.timeout, 'choices': len(CHOICES)}), file=sys.stderr)


if __name__ == '__main__':
    main(sys.argv[1])
