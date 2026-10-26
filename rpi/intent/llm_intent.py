"""Read-only closed-list intent selection. No execution dependency or model-written commands."""
from __future__ import annotations

import json
import logging
import math
import os
import re
import time
from dataclasses import dataclass
from urllib.request import Request, urlopen

from rpi.intent.llm_guard import post_check, pre_guard
from rpi.intent.normalize import normalize_utterance, refuses_matching
from rpi.josa import josa, with_josa

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class LlmIntentConfig:
    url: str = ''
    timeout: float = 20

    @classmethod
    def from_env(cls):
        try:
            timeout = float(os.environ.get('SIMPLELAY_LLM_TIMEOUT_SECONDS', '20'))
            if not math.isfinite(timeout) or timeout <= 0:
                timeout = 20
        except ValueError:
            timeout = 20
        return cls(os.environ.get('SIMPLELAY_LLM_URL', '').strip().rstrip('/'), timeout)


@dataclass(frozen=True)
class IntentChoice:
    label: str
    description: str
    action: dict
    aliases: tuple[str, ...] = ()
    #: Fixed-template Korean confirmation question (never model text). Empty -> generic form.
    question: str = ''


MAX_CHOICES = 12


_HINTS = {
    '즉석밥 데우기': 'reheat instant rice', '즉석밥 데워줘': 'reheat instant rice',
    '30초 돌려줘': 'heat for 30 seconds, e.g. a small drink or leftovers',
    '1분 돌려줘': 'heat for one minute', '5분 돌려줘': 'heat for five minutes',
    '해동해줘': 'defrost food', '냉동식품 데워줘': 'reheat frozen food',
    '라면 끓여줘': 'cook instant noodles', '취소해줘': 'cancel appliance operation',
}

#: Saved-button purpose suffix -> natural verb form ("즉석밥 데우기" -> "즉석밥을 데울까요?").
_VERB_SUFFIXES = {' 데우기': '데울까요?', ' 끓이기': '끓일까요?'}


def _generic_question(label: str) -> str:
    return f"{with_josa(label, '을', '를')} 할까요?"


def _thinq_text(name: str, category: str, cap, value: str) -> tuple[str, str]:
    """(short English prompt line without user names, natural Korean question)."""
    word = cap.value_label(value)
    obj = with_josa(name, '을', '를')
    if cap.action == 'set_power' and value in ('POWER_ON', 'POWER_OFF'):
        on = value == 'POWER_ON'
        return (f"turn {'ON' if on else 'OFF'} {category}", f"{obj} {'켤' if on else '끌'}까요?")
    if cap.action == 'set_wind_strength':
        return f'{category} fan {value}', f"{name} 바람을 {with_josa(word, '으로', '로')} 할까요?"
    if cap.action == 'set_job_mode':
        return (f'{category} {value.lower()} mode',
                f"{obj} {with_josa(word + ' 모드', '으로', '로')} 할까요?")
    if cap.action == 'set_operation' and value in ('START', 'STOP'):
        return (f"{'start' if value == 'START' else 'pause'} {category}",
                f"{obj} {'시작' if value == 'START' else '일시정지'}할까요?")
    return (f'{category} {cap.action} {value}',
            f"{name} {cap.label}{josa(cap.label, '을', '를')} {with_josa(word, '으로', '로')} 할까요?")


#: 목적 앞말이 시간뿐("30초 데우기")이면 "30초를 데울까요?"가 어색하다 → "전자레인지로 30초 데울까요?".
_DURATION = re.compile(r'\d+\s*(초|분)(\s*\d+\s*초)?')


def _purpose_question(label: str, purpose: str) -> str:
    for suffix, verb in _VERB_SUFFIXES.items():
        obj = purpose[:-len(suffix)].strip()
        if purpose.endswith(suffix) and obj:
            if _DURATION.fullmatch(obj):
                name = label[:-len(purpose)].strip() if label.endswith(purpose) else ''
                return f"{with_josa(name, '으로', '로')} {obj} {verb}" if name else f'{obj} {verb}'
            return f"{with_josa(obj, '을', '를')} {verb}"
    return _generic_question(label)


def build_choices(appliances, routines, ready, purposes, profile_support=None) -> tuple[IntentChoice, ...]:
    """Inputs are snapshots and read-only callbacks. Only registered, ready actions, at most 12.

    Prompt lines carry no user-written names (device, purpose, routine): nothing to inject.
    """
    available = {a.appliance_id: a for a in appliances if ready(a)}
    result = []
    seen = set()

    def add(label, description, action, aliases=(), question=''):
        key = json.dumps(action, sort_keys=True, ensure_ascii=False)
        if key not in seen and len(result) < MAX_CHOICES:
            seen.add(key)
            result.append(IntentChoice(label, description, action, tuple(aliases), question))

    per_category = {}
    for a in available.values():
        category = a.category.value.replace('_', ' ')
        per_category[category] = per_category.get(category, 0) + 1
        if per_category[category] > 1:  # Short ASCII disambiguator instead of the user's name.
            category = f'{category} #{per_category[category]}'
        binding = a.thinq
        if binding is not None:
            support = profile_support(a) if profile_support is not None else {}
            for cap in binding.capabilities:
                allowed = support.get(cap.action, {}).get('allowed', ())
                for value in cap.allowed:
                    if value not in allowed:
                        continue
                    label = f'{a.name} {cap.setting_phrase(value)}'
                    aliases = [fn.purpose for fn in binding.functions
                               if fn.action == cap.action and dict(fn.args) == {cap.arg: value}]
                    description, question = _thinq_text(a.name, category, cap, value)
                    add(label, description,
                        {'kind': 'thinq', 'appliance_id': a.appliance_id,
                         'action': cap.action, 'args': {cap.arg: value}}, aliases, question)
        else:
            for purpose, steps in purposes(a).items():
                label = f'{a.name} {purpose}'
                add(label, f'{_HINTS.get(purpose, "saved action")} ({category})',
                    {'kind': 'buttons', 'appliance_id': a.appliance_id, 'buttons': list(steps)},
                    (purpose, label), _purpose_question(label, purpose))
    for routine in routines:
        if (routine.mode != 'approve' or not routine.device_steps
                or any(s.appliance_id not in available for s in routine.device_steps)):
            continue
        # Validate against this snapshot, including unsupported/changed button maps.
        from rpi.routines.model import compile_commands, RoutineValidationError
        from types import SimpleNamespace
        try:
            commands = compile_commands(routine, SimpleNamespace(get=available.get))
            # A ready device can still lack one command in its current profile.
            for command in commands:
                a = available[command.target_id]
                if a.thinq is not None:
                    support = profile_support(a) if profile_support is not None else {}
                    cap = a.thinq.capability(command.action)
                    if command.args_dict().get(cap.arg) not in support.get(cap.action, {}).get('allowed', ()):
                        raise RoutineValidationError('unsupported command')
        except (RoutineValidationError, ValueError):
            continue
        add(routine.name, 'saved routine',
            {'kind': 'routine', 'routine_id': routine.routine_id,
             'fingerprint': routine.steps_fingerprint()}, (routine.name,), _generic_question(routine.name))
    return tuple(result)


def build_prompt(choices) -> str:
    # Lines hold no user-written names (nothing to inject). The response cannot add actions.
    return ('You map a Korean user utterance to exactly one action from the list. '
            'Reply with the number only. If nothing fits, reply 0.\n'
            + '\n'.join(f'{i} {c.description}' for i, c in enumerate(choices, 1)) + '\n0 none')


def parse_choice(text, count: int) -> int:
    if not isinstance(text, str):
        return 0
    match = re.search(r'(?<![\w.])[+-]?\d+', text)
    if match is None or len(match[0]) > 3:
        return 0
    value = int(match[0])
    return value if 1 <= value <= count else 0


def http_transport(url, body, timeout):
    request = Request(url, json.dumps(body, ensure_ascii=False).encode('utf-8'),
                      {'Content-Type': 'application/json'}, method='POST')
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read(65537))


def unknown(source, reason=None):
    result = dict(understood=False, action=None, label=None, question=None, source=source)
    if reason:  # 규칙이 거른 까닭(out_of_list·already_done·no_need·contradiction) — 화면 문구용 아님.
        result['reason'] = reason
    return result


def understand(text, choices, config, transport=None):
    if not config.url:
        return unknown('off')
    if not choices or refuses_matching(text):
        return unknown('rules')
    # Deterministic exact matching wins only when one action matches; ambiguous targets never guessed.
    matches = [c for c in choices if normalize_utterance(text) in
               {normalize_utterance(s) for s in (c.label, *c.aliases)}]
    if len(matches) > 1:
        return unknown('rules')
    source = 'rules'
    selected = matches[0] if matches else None
    if selected is None:
        # 모델 앞 규칙 거르기(llm_guard): 목록 밖 기기·이미 함·필요 없음은 '고르지 않음', 뻔한 값은 규칙이 고른다.
        guard = pre_guard(text, choices)
        if guard is not None and guard[0] == 'none':
            return unknown('rules', guard[1])
        if guard is not None:
            selected = guard[1]
    if selected is None:
        start = time.monotonic()
        try:
            reply = (transport or http_transport)(config.url + '/invoke', {
                'messages': [{'role': 'system', 'content': build_prompt(choices)},
                             {'role': 'user', 'content': text}], 'stream': False}, config.timeout)
            index = parse_choice(reply['choices'][0]['message']['content'], len(choices))
            selected = choices[index - 1] if index else None
        except Exception:  # Fail closed; do not log response/error bodies or user text.
            selected = None
        finally:
            log.info('intent selection choices=%d latency_ms=%d', len(choices), (time.monotonic() - start) * 1000)
        source = 'llm'
        # 모델 뒤 확인: 고른 동작이 문장과 어긋나면(켜기 ↔ 끄는 말 등) 버린다.
        if selected is not None and post_check(text, selected):
            return unknown(source, 'contradiction')
    if selected is None:
        return unknown(source)
    return dict(understood=True, action=selected.action, label=selected.label,
                question=selected.question or _generic_question(selected.label), source=source)
