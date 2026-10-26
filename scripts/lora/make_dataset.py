"""Build deterministic chat-format examples for closed-list intent selection.

Generated data is intentionally written outside the repository. The system prompt
is always produced by the live ``rpi.intent.llm_intent.build_prompt`` function.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from rpi.intent.llm_intent import IntentChoice, MAX_CHOICES, build_prompt  # noqa: E402
from scripts.llm_eval_hub import CHOICES as EVAL_CHOICES  # noqa: E402

DEFAULT_COUNT = 2000
DEFAULT_SEED = 20261026
GROUP_RATIOS = {
    'indirect': 0.40,
    'direct': 0.15,
    'negation': 0.15,
    'out_of_list': 0.20,
    'ambiguous': 0.10,
}
DEFAULT_SIMILARITY_THRESHOLD = 0.62


@dataclass(frozen=True)
class Example:
    group: str
    text: str
    target: IntentChoice | None


MICROWAVE_CHOICE = IntentChoice(
    '전자레인지 30초 데우기',
    'heat food in microwave for 30 seconds',
    {'kind': 'buttons', 'appliance_id': 'microwave', 'buttons': ['heat_30_seconds']},
    ('전자레인지 30초 데우기',),
    '전자레인지로 30초 데울까요?',
)


def normalize_text(text: str) -> str:
    """Normalize punctuation, compatibility forms, and whitespace for deduplication."""
    value = unicodedata.normalize('NFKC', text).casefold()
    value = re.sub(r"[\s\W_]+", '', value, flags=re.UNICODE)
    return value


def char_ngram_similarity(left: str, right: str, n: int = 2) -> float:
    """Jaccard similarity over normalized character n-grams."""
    a, b = normalize_text(left), normalize_text(right)
    if not a or not b:
        return 1.0 if a == b else 0.0

    def grams(value: str) -> set[str]:
        if len(value) < n:
            return {value}
        return {value[i:i + n] for i in range(len(value) - n + 1)}

    a_grams, b_grams = grams(a), grams(b)
    return len(a_grams & b_grams) / len(a_grams | b_grams)


def load_eval_texts(paths: tuple[Path, ...] | None = None) -> tuple[str, ...]:
    paths = paths or (
        ROOT / 'rpi' / 'intent' / 'eval' / 'llm_eval_ko.jsonl',
        ROOT / 'rpi' / 'intent' / 'eval' / 'llm_eval_ko_holdout.jsonl',
    )
    texts = []
    for path in paths:
        with path.open(encoding='utf-8') as stream:
            for line in stream:
                if line.strip():
                    row = json.loads(line)
                    texts.append(row['text'])
    return tuple(texts)


def overlaps_eval(text: str, eval_texts: tuple[str, ...], threshold: float = DEFAULT_SIMILARITY_THRESHOLD) -> bool:
    normalized = normalize_text(text)
    return any(normalized == normalize_text(reference)
               or char_ngram_similarity(text, reference) >= threshold for reference in eval_texts)


def group_counts(count: int) -> dict[str, int]:
    if not 1500 <= count <= 3000:
        raise ValueError('count must be between 1500 and 3000')
    exact = {group: count * ratio for group, ratio in GROUP_RATIOS.items()}
    counts = {group: int(value) for group, value in exact.items()}
    remainder = count - sum(counts.values())
    order = sorted(GROUP_RATIOS, key=lambda group: exact[group] - counts[group], reverse=True)
    for group in order[:remainder]:
        counts[group] += 1
    return counts


def _device_name(choice: IntentChoice) -> str:
    if choice.action.get('kind') == 'routine':
        return choice.label
    if choice.action.get('kind') == 'buttons':
        return '전자레인지'
    return '공기청정기'


def _action_kind(choice: IntentChoice) -> tuple[str, str]:
    action = choice.action
    if action.get('kind') == 'routine':
        return 'routine', choice.label
    if action.get('kind') == 'buttons':
        return 'microwave', '30초 데우기'
    name = action.get('action', '')
    value = next(iter(action.get('args', {}).values()), '')
    return name, str(value)


def _direct_pool(choice: IntentChoice) -> list[str]:
    kind, value = _action_kind(choice)
    device = _device_name(choice)
    endings = ('줘', '주세요', '주라', '줘요', '좀 해줘', '부탁해', '부탁드려요', '줄래', '해줘')
    if kind == 'set_power':
        verb = '켜' if value == 'POWER_ON' else '꺼'
        forms = (f'{device} 전원 {verb}', f'{device} {verb}', f'{device} 작동 {verb}',
                 f'{device} 가동해' if value == 'POWER_ON' else f'{device} 멈춰',
                 f'{device} 틀어' if value == 'POWER_ON' else f'{device} 꺼줘')
    elif kind == 'set_wind_strength':
        words = {'LOW': '약', 'MID': '중', 'HIGH': '강', 'AUTO': '자동'}
        word = words.get(value, '자동')
        forms = (f'{device} 바람 세기 {word}으로 바꿔', f'{device} 풍량을 {word}으로 맞춰',
                 f'{device} 바람을 {word}풍으로 설정해', f'{device} 바람을 {word}하게 해',
                 f'{device} 풍량을 {word}으로 조절해')
    elif kind == 'set_job_mode':
        words = {'CLEAN': '청정', 'SLEEP': '수면', 'AUTO': '자동'}
        word = words.get(value, value.lower())
        forms = (f'{device} {word} 모드로 바꿔', f'{device} 운전 모드를 {word}으로 해',
                 f'{device} {word} 모드 설정해', f'{device} {word} 모드로 맞춰',
                 f'{device} 운전을 {word} 모드로 해')
    elif kind == 'routine':
        forms = (f'{value} 실행해', f'{value} 시작해', f'{value} 진행해',
                 f'{value} 해줘', f'{value} 돌려줘')
    else:
        forms = ('전자레인지 30초 데워', '전자레인지로 30초 돌려', '음식 30초만 데워',
                 '30초만 데워줘', '전자레인지에 넣고 30초 데워')
    return [f'{form} {ending}' for form in forms for ending in endings]


def _indirect_pool(choice: IntentChoice) -> list[str]:
    kind, value = _action_kind(choice)
    device = _device_name(choice)
    if kind == 'set_power' and value == 'POWER_ON':
        leads = ('공기가 좀 텁텁해서', '요리 냄새가 아직 남아서', '미세먼지가 신경 쓰여서',
                 '실내 공기를 정리하고 싶어서', '먼지가 좀 떠다니는 것 같아서', '방 안이 답답하게 느껴져서')
        tails = ('공기를 깨끗하게 하고 싶어', '공기 정화를 해두면 좋겠어', '청정기를 켜면 좋을 것 같아',
                 '공기 상태를 바꾸고 싶어요', '공기를 한번 정리하고 싶다')
    elif kind == 'set_power':
        leads = ('소리가 조금 거슬려서', '잠깐 조용히 있고 싶어서', '잠시 쉬게 하고 싶어서',
                 '밤이라 소리를 줄이고 싶어서', '기기를 잠시 멈추고 싶어서')
        tails = ('작동을 멈추면 좋겠어', '잠시 꺼두고 싶다', '조용하게 쉬었으면 해', '운전을 그만하면 좋겠어')
    elif kind == 'set_wind_strength':
        words = {'LOW': '부드럽게', 'MID': '적당히', 'HIGH': '강하게', 'AUTO': '알아서'}
        word = words.get(value, '알아서')
        leads = ('바람이 지금은 아쉬워서', '방 안 공기를 순환하고 싶어서', '현재 풍량이 마음에 안 들어서',
                 '공기 흐름을 조금 바꾸고 싶어서', '지금 상황에 맞춰서')
        tails = (f'{word} 나오면 좋겠어', f'{word} 조절되면 좋겠다', f'{word} 쓰고 싶어요',
                 f'{word} 바뀌면 괜찮을 것 같아')
    elif kind == 'set_job_mode':
        words = {'CLEAN': '청정 모드', 'SLEEP': '수면 모드', 'AUTO': '자동 모드'}
        word = words.get(value, '자동 모드')
        leads = ('공기 상태에 맞는 운전으로', '잠자는 동안에는', '지금은 조용하게',
                 '상황에 맞게 기기가', '운전 방식을')
        tails = (f'{word}로 돌면 좋겠어', f'{word}가 필요할 것 같아', f'{word}를 쓰고 싶어요',
                 f'{word}로 바꿔두면 편하겠다')
    elif kind == 'routine':
        leads = ('저녁 준비를 미리 해두면 편해서', '아침에 손이 덜 가게', '정해 둔 순서대로',
                 '평소 하던 동작을', '이 시간에 하던 일을')
        tails = ('해두면 좋겠어', '진행하고 싶어요', '미리 시작해두면 편하겠다', '해도 괜찮을 것 같아')
    else:
        leads = ('따뜻한 음료가 마시고 싶어서', '식은 간식을 먹으려는데', '음식이 조금 차가워서',
                 '간단히 데워 먹고 싶어서', '차가 식어버렸네')
        tails = ('전자레인지로 짧게 데우면 좋겠어', '30초쯤 데우고 싶어요', '잠깐 데워 먹을까 해',
                 '따뜻하게 먹으면 좋겠다')
    prefixes = ('', '음, ', '지금 ', '저기 ', '오늘은 ')
    return [f'{prefix}{lead} {tail}' for prefix in prefixes for lead in leads for tail in tails]


def _negative_pool(choice: IntentChoice) -> list[str]:
    kind, value = _action_kind(choice)
    device = _device_name(choice)
    if kind == 'set_power':
        verb = '켜' if value == 'POWER_ON' else '꺼'
        past = '켰' if value == 'POWER_ON' else '껐'
        forms = (f'{device} {verb}지 마', f'{device} {verb}지 말아줘', f'{device} {verb}지 않아도 돼',
                 f'{device}는 {verb} 필요 없어', f'방금 {device} {past}으니 다시 하지 마',
                 f'이미 {device} {past}어, 또 하지 말아줘', f'{device}는 그대로 두고 건드리지 마')
    elif kind == 'set_wind_strength':
        word = {'LOW': '약', 'MID': '중', 'HIGH': '강', 'AUTO': '자동'}[value]
        forms = (f'{device} 바람을 {word}으로 바꾸지 마', f'{device} 풍량 {word}으로 하지 말아줘',
                 f'{device} 바람 세기는 이미 {word}이야', f'아까 {device} 풍량을 {word}으로 해놨어',
                 f'{device}를 {word}풍으로 맞출 필요 없어', f'{device} 풍량을 다시 바꾸지 않아도 돼')
    elif kind == 'set_job_mode':
        word = {'CLEAN': '청정', 'SLEEP': '수면', 'AUTO': '자동'}[value]
        forms = (f'{device} {word} 모드로 바꾸지 마', f'{device}를 {word} 모드로 하지 말아줘',
                 f'{device}는 이미 {word} 모드야', f'방금 {device}를 {word} 모드로 설정했어',
                 f'{word} 모드는 필요 없어', f'{device} 운전 모드를 다시 건드리지 마')
    elif kind == 'routine':
        forms = (f'{choice.label} 실행하지 마', f'{choice.label} 하지 않아도 돼', f'{choice.label}는 이미 했어',
                 f'방금 {choice.label} 진행했으니 다시 하지 말아줘', f'{choice.label} 시작할 필요 없어')
    else:
        forms = ('전자레인지 30초 데우지 마', '음식은 데우지 않아도 돼', '방금 전자레인지로 데웠어',
                 '전자레인지는 지금 돌리지 말아줘', '30초 데우기는 필요 없어')
    # Extra no-op paraphrases keep the refusal class broad and avoid teaching only
    # action-specific negation strings. They never imply another listed action.
    devices = ('공기청정기', '공청기', '전자레인지', '에어컨', '인덕션', '밥솥', '세탁기',
               '선풍기', '가습기', '조명', 'TV', '냉장고', '커튼', '보일러')
    generic = ('건은 이미 처리했어, 또 하지 마', '는 방금 해놔서 다시 할 필요 없어',
               '는 지금 그대로 두면 돼', '는 당분간 건드리지 말아줘',
               '는 지금 할 필요 없어', '는 아까 바꿨으니 더 만지지 마',
               '는 이미 끝났어, 다시 실행하지 마', '는 잠깐 멈춰두고 아무것도 바꾸지 말자',
               '는 이번에는 하지 말아주세요', '는 그대로 놔두는 게 좋겠어',
               '는 이미 맞춰 뒀으니 그대로 두자', '는 추가로 실행하지 않아도 돼',
               '는 방금 확인했으니 다시 건드리지 마', '는 변경하지 않고 둘게',
               '는 원하는 상태니까 더 바꾸지 마', '는 지금 손대지 않는 게 낫겠어',
               '는 다 끝났으니 추가로 실행하지 말아줘', '는 다음에 할게, 지금은 하지 마',
               '는 잘 되고 있으니 그냥 그대로 둬', '는 일단 보류해두자',
               '는 처리 완료됐어, 다시 시작하지 마', '는 그대로 놔두는 게 좋을 듯해',
               '는 오늘은 건너뛰어도 괜찮아', '는 이미 충분하니까 더 하지 말자',
               '는 당장은 변경하지 말아주세요', '는 다시 실행할 이유가 없어')
    return list(forms) + [f'{device}{tail}' for device in devices for tail in generic]


def _out_of_list_pool() -> list[str]:
    devices = ('에어컨', '인덕션', '전기밥솥', '텔레비전', '전등', '커튼', '보일러', '냉장고',
               '선풍기', '가습기', '로봇 청소기', '인터폰', '제습기', '스탠드 조명')
    requests = ('켜줘', '꺼 주세요', '온도를 낮춰줘', '풍량을 높여줘', '예약해줘',
                '작동을 시작해', '절전 모드로 바꿔줘', '문을 열어줘', '밝기를 줄여줘')
    contexts = ('', '지금 ', '저녁에 ', '아침에 ', '오늘은 ')
    return [f'{context}{device} {request}' for context in contexts for device in devices for request in requests]


def _ambiguous_pool() -> list[str]:
    references = ('그거', '그쪽', '그 상태', '그것', '아까 말한 거', '저거', '그거 있잖아')
    requests = ('좀 해줘', '어떻게 하지', '바꿔볼까', '한번 해볼까', '조금 해도 되나', '하면 좋겠어')
    openers = ('', '음, ', '저기 ', '그냥 ', '흠, ')
    return [f'{opener}{reference} {request}' for opener in openers
            for reference in references for request in requests]


def _sample_choices(target: IntentChoice | None, all_choices: tuple[IntentChoice, ...], rng: random.Random) -> tuple[IntentChoice, ...]:
    remaining = [choice for choice in all_choices if choice is not target]
    # The live prompt describes every routine as "saved routine", without its
    # name. Two such options are indistinguishable to the model, so never label
    # one of them as the unique correct answer in the same training prompt.
    if target is not None and target.action.get('kind') == 'routine':
        remaining = [choice for choice in remaining if choice.action.get('kind') != 'routine']
    available_count = len(remaining) + (target is not None)
    count = rng.randint(min(2, available_count), available_count)
    extras = rng.sample(remaining, count - 1) if target is not None else rng.sample(all_choices, count)
    selected = [target, *extras] if target is not None else extras
    rng.shuffle(selected)
    if len(selected) > MAX_CHOICES:
        raise AssertionError('choice list exceeds live prompt limit')
    return tuple(selected)


def _quota_pool(group: str, all_choices: tuple[IntentChoice, ...]) -> list[Example]:
    if group in ('indirect', 'direct', 'negation'):
        result = []
        for choice in all_choices:
            phrases = {
                'indirect': _indirect_pool,
                'direct': _direct_pool,
                'negation': _negative_pool,
            }[group](choice)
            result.extend(Example(group, text, choice if group != 'negation' else None) for text in phrases)
        return result
    if group == 'out_of_list':
        return [Example(group, text, None) for text in _out_of_list_pool()]
    return [Example(group, text, None) for text in _ambiguous_pool()]


def _build_pool(group: str, all_choices: tuple[IntentChoice, ...], eval_texts: tuple[str, ...],
                threshold: float, seen: set[str]) -> list[Example]:
    pool = []
    local = set()
    for example in _quota_pool(group, all_choices):
        normalized = normalize_text(example.text)
        if not normalized or normalized in seen or normalized in local:
            continue
        if overlaps_eval(example.text, eval_texts, threshold):
            continue
        local.add(normalized)
        pool.append(example)
    return pool


def generate_records(count: int = DEFAULT_COUNT, seed: int = DEFAULT_SEED,
                     eval_paths: tuple[Path, ...] | None = None,
                     similarity_threshold: float = DEFAULT_SIMILARITY_THRESHOLD) -> list[dict]:
    quotas = group_counts(count)
    rng = random.Random(seed)
    eval_texts = load_eval_texts(eval_paths)
    all_choices = tuple(EVAL_CHOICES) + (MICROWAVE_CHOICE,)
    if len(all_choices) > MAX_CHOICES:
        raise RuntimeError('action snapshot is larger than the live prompt limit')

    examples: list[Example] = []
    seen_texts: set[str] = set()
    for group, quota in quotas.items():
        pool = _build_pool(group, all_choices, eval_texts, similarity_threshold, seen_texts)
        if len(pool) < quota:
            raise RuntimeError(f'only {len(pool)} clean {group} phrases available; need {quota}')
        rng.shuffle(pool)
        chosen = pool[:quota]
        examples.extend(chosen)
        seen_texts.update(normalize_text(example.text) for example in chosen)

    rng.shuffle(examples)
    rows = []
    for index, example in enumerate(examples, 1):
        choices = _sample_choices(example.target, all_choices, rng)
        target_index = next((i for i, choice in enumerate(choices, 1) if choice is example.target), 0)
        messages = [
            {'role': 'system', 'content': build_prompt(choices)},
            {'role': 'user', 'content': example.text},
            {'role': 'assistant', 'content': str(target_index)},
        ]
        rows.append({'id': f'intent-{index:05d}', 'group': example.group,
                     'text': example.text, 'messages': messages})
    return rows


def validate_output_path(path: Path) -> Path:
    output = path.expanduser().resolve()
    try:
        output.relative_to(ROOT.resolve())
    except ValueError:
        return output
    raise ValueError('dataset output must be outside the repository')


def write_dataset(path: Path, rows: list[dict]) -> None:
    output = validate_output_path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('w', encoding='utf-8', newline='\n') as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Generate offline closed-list intent training examples.')
    parser.add_argument('--out', required=True, type=Path, help='JSONL destination outside the repository')
    parser.add_argument('--count', type=int, default=DEFAULT_COUNT, help='number of examples (1500..3000)')
    parser.add_argument('--seed', type=int, default=DEFAULT_SEED)
    parser.add_argument('--similarity-threshold', type=float, default=DEFAULT_SIMILARITY_THRESHOLD)
    args = parser.parse_args(argv)
    try:
        rows = generate_records(args.count, args.seed, similarity_threshold=args.similarity_threshold)
        write_dataset(args.out, rows)
    except (OSError, ValueError, RuntimeError) as exc:
        parser.error(str(exc))
    print(f'Wrote {len(rows)} examples to {validate_output_path(args.out)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
