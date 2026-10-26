import json

import pytest

from scripts.lora.check_dataset import audit_dataset


def _jsonl(path, rows):
    path.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows),
                    encoding='utf-8')


def test_audit_rejects_overlap_and_duplicate(tmp_path):
    evaluation = tmp_path / 'evaluation.jsonl'
    training = tmp_path / 'training.jsonl'
    _jsonl(evaluation, [{'text': 'sample command alpha'}])
    _jsonl(training, [{'text': 'sample command alpha!'}])
    with pytest.raises(ValueError, match='eval_collisions'):
        audit_dataset(training, (evaluation,))
    _jsonl(training, [{'text': 'different phrase'}, {'text': 'different phrase!'}])
    with pytest.raises(ValueError, match='duplicates'):
        audit_dataset(training, (evaluation,))
    _jsonl(training, [{'text': 'different phrase'}])
    assert audit_dataset(training, (evaluation,))['rows'] == 1
