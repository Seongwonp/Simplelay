from collections import Counter
import json
import re

import pytest

from scripts.lora import make_dataset


@pytest.fixture(scope='module')
def records():
    return make_dataset.generate_records(1500, seed=31)


def test_group_quotas_follow_handoff_ratios():
    assert make_dataset.group_counts(2000) == {
        'indirect': 800, 'direct': 300, 'negation': 300,
        'out_of_list': 400, 'ambiguous': 200,
    }
    assert make_dataset.group_counts(1500) == {
        'indirect': 600, 'direct': 225, 'negation': 225,
        'out_of_list': 300, 'ambiguous': 150,
    }
    with pytest.raises(ValueError):
        make_dataset.group_counts(1499)


def test_dataset_has_balanced_rows_and_closed_list_targets(records):
    assert len(records) == 1500
    assert Counter(row['group'] for row in records) == {
        'indirect': 600, 'direct': 225, 'negation': 225,
        'out_of_list': 300, 'ambiguous': 150,
    }
    assert len({row['id'] for row in records}) == len(records)
    assert len({make_dataset.normalize_text(row['text']) for row in records}) == len(records)
    for row in records:
        messages = row['messages']
        assert [message['role'] for message in messages] == ['system', 'user', 'assistant']
        assert messages[1]['content'] == row['text']
        system = messages[0]['content']
        option_count = sum(1 for line in system.splitlines()
                           if re.match(r'^[1-9][0-9]* ', line))
        target = int(messages[2]['content'])
        if row['group'] in ('indirect', 'direct'):
            assert 1 <= target <= option_count <= make_dataset.MAX_CHOICES
            if 'saved routine' in system.splitlines()[target]:
                assert system.count('saved routine') == 1
        else:
            assert target == 0


def test_system_prompt_uses_the_live_builder(records):
    from rpi.intent.llm_intent import build_prompt

    choices = tuple(make_dataset.EVAL_CHOICES) + (make_dataset.MICROWAVE_CHOICE,)
    prompt = build_prompt(choices)
    # The canonical prompt header and the enumerated option syntax come from the
    # live builder; generated rows retain that exact header even with subsets.
    header = prompt.splitlines()[0]
    assert header == 'You map a Korean user utterance to exactly one action from the list. Reply with the number only. If nothing fits, reply 0.'
    for row in records:
        assert row['messages'][0]['content'].startswith(header + '\n')


def test_eval_and_holdout_phrases_are_not_reused_or_near_copied(records):
    eval_texts = make_dataset.load_eval_texts()
    for row in records:
        assert not make_dataset.overlaps_eval(row['text'], eval_texts)


def test_generator_is_reproducible(records):
    assert records == make_dataset.generate_records(1500, seed=31)


def test_writer_rejects_repository_outputs(tmp_path):
    inside = make_dataset.ROOT / 'lora-training-data.jsonl'
    with pytest.raises(ValueError, match='outside the repository'):
        make_dataset.validate_output_path(inside)

    outside = tmp_path / 'training' / 'examples.jsonl'
    make_dataset.write_dataset(outside, [{'id': 'x', 'messages': []}])
    assert json.loads(outside.read_text(encoding='utf-8')) == {'id': 'x', 'messages': []}


def test_eval_similarity_uses_character_ngrams():
    assert make_dataset.char_ngram_similarity('공기가 탁하다', '공기가 탁하다!') == 1.0
    assert make_dataset.char_ngram_similarity('공기가 탁하다', '공기 상태가 좋다') > 0
    assert make_dataset.char_ngram_similarity('전자레인지 데우기', '현관문 잠그기') < 0.25
