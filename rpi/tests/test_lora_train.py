from pathlib import Path

import pytest

from scripts.lora.train import collate, encode_example, outside_repo


class TokenizerStub:
    eos_token_id = 99

    def apply_chat_template(self, messages, tokenize, add_generation_prompt):
        assert [message['role'] for message in messages] == ['system', 'user']
        assert tokenize and add_generation_prompt
        return [11, 12, 13]

    def __call__(self, text, add_special_tokens):
        assert text == '2' and not add_special_tokens
        return {'input_ids': [22]}


def test_answer_only_has_loss_and_list_is_not_truncated():
    row = {'messages': [
        {'role': 'system', 'content': '1 on\n2 off\n0 none'},
        {'role': 'user', 'content': '꺼줘'},
        {'role': 'assistant', 'content': '2'},
    ]}
    encoded = encode_example(row, TokenizerStub(), 5)
    assert encoded['input_ids'] == [11, 12, 13, 22, 99]
    assert encoded['labels'] == [-100, -100, -100, 22, 99]
    with pytest.raises(ValueError, match='truncate'):
        encode_example(row, TokenizerStub(), 4)


def test_collator_masks_padding():
    torch = pytest.importorskip('torch')
    rows = [
        {'input_ids': [11, 22, 99], 'attention_mask': [1, 1, 1], 'labels': [-100, 22, 99]},
        {'input_ids': [11, 99], 'attention_mask': [1, 1], 'labels': [-100, 99]},
    ]
    batch = collate(rows, 0)
    assert torch.equal(batch['input_ids'][1], torch.tensor([11, 99, 0]))
    assert torch.equal(batch['attention_mask'][1], torch.tensor([1, 1, 0]))
    assert torch.equal(batch['labels'][1], torch.tensor([-100, 99, -100]))


def test_training_artifact_path_must_be_outside_repository(tmp_path):
    with pytest.raises(ValueError, match='outside the repository'):
        outside_repo(Path(__file__))
    assert outside_repo(tmp_path) == tmp_path.resolve()
