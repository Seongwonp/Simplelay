"""Train a small, offline QLoRA adapter for the live closed-list prompt.

Example inputs and all model artifacts must be outside the repository. This
script deliberately knows no model identity: --model points to a locally
downloaded public base model whose license has been checked separately.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def outside_repo(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(REPO_ROOT)
    except ValueError:
        return resolved
    raise ValueError('model, dataset, and output must be outside the repository')


def encode_example(row: dict, tokenizer, max_length: int) -> dict:
    messages = row['messages']
    if [item['role'] for item in messages] != ['system', 'user', 'assistant']:
        raise ValueError('expected system/user/assistant training example')
    if not messages[2]['content'].isdigit():
        raise ValueError('answer must be a closed-list number')
    prompt_ids = tokenizer.apply_chat_template(
        messages[:2], tokenize=True, add_generation_prompt=True,
    )
    if hasattr(prompt_ids, 'keys'):
        prompt_ids = prompt_ids['input_ids']
    answer_ids = tokenizer(messages[2]['content'], add_special_tokens=False)['input_ids']
    answer_ids.append(tokenizer.eos_token_id)
    if len(prompt_ids) + len(answer_ids) > max_length:
        raise ValueError('max_length would truncate an action list or answer')
    return {
        'input_ids': prompt_ids + answer_ids,
        'attention_mask': [1] * (len(prompt_ids) + len(answer_ids)),
        'labels': [-100] * len(prompt_ids) + answer_ids,
    }


class JsonlDataset:
    def __init__(self, path: Path, tokenizer, max_length: int):
        self.rows = []
        with path.open(encoding='utf-8') as stream:
            for line in stream:
                if line.strip():
                    self.rows.append(encode_example(json.loads(line), tokenizer, max_length))
        if not self.rows:
            raise ValueError('empty training dataset')

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, index):
        return self.rows[index]


def collate(rows, pad_token_id: int):
    import torch

    width = max(len(row['input_ids']) for row in rows)
    return {
        'input_ids': torch.tensor([row['input_ids'] + [pad_token_id] * (width - len(row['input_ids']))
                                   for row in rows], dtype=torch.long),
        'attention_mask': torch.tensor([row['attention_mask'] + [0] * (width - len(row['attention_mask']))
                                        for row in rows], dtype=torch.long),
        'labels': torch.tensor([row['labels'] + [-100] * (width - len(row['labels']))
                                for row in rows], dtype=torch.long),
    }


def train(model_path: Path, data_path: Path, output_path: Path, *, epochs: int,
          max_length: int, seed: int, max_steps: int = -1) -> None:
    import torch
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              BitsAndBytesConfig, Trainer, TrainingArguments)

    if not torch.cuda.is_available():
        raise RuntimeError('CUDA QLoRA unavailable; do not substitute full-precision training')
    model_path = outside_repo(model_path)
    data_path = outside_repo(data_path)
    output_path = outside_repo(output_path)
    output_path.mkdir(parents=True, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
    if tokenizer.eos_token_id is None:
        raise ValueError('tokenizer has no EOS token')
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    dataset = JsonlDataset(data_path, tokenizer, max_length)

    quant = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type='nf4',
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_use_double_quant=True,
    )
    model = AutoModelForCausalLM.from_pretrained(
        model_path, trust_remote_code=True, quantization_config=quant,
        device_map={'': 0}, torch_dtype=torch.float16,
    )
    # Some custom causal-model classes expose the embedding module but do not
    # implement the standard accessor expected by parameter-efficient tuning.
    try:
        model.get_input_embeddings()
    except NotImplementedError:
        embedding = model.transformer.wte
        model.transformer.get_input_embeddings = lambda: embedding
        model.get_input_embeddings = lambda: embedding
    model.config.use_cache = False
    model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
    targets = {name.rsplit('.', 1)[-1] for name, _ in model.named_modules()}
    if not {'q_proj', 'v_proj'} <= targets:
        raise RuntimeError('base architecture has no q_proj/v_proj modules')
    model = get_peft_model(model, LoraConfig(
        r=16, lora_alpha=32, lora_dropout=0.05,
        bias='none', task_type='CAUSAL_LM', target_modules=['q_proj', 'v_proj'],
    ))
    model.print_trainable_parameters()

    args = TrainingArguments(
        output_dir=str(output_path), num_train_epochs=epochs,
        max_steps=max_steps, per_device_train_batch_size=1,
        gradient_accumulation_steps=8, learning_rate=2e-4,
        lr_scheduler_type='cosine', warmup_steps=15,
        logging_steps=20, save_strategy='epoch', save_total_limit=None,
        fp16=True, gradient_checkpointing=True, optim='adamw_torch',
        dataloader_num_workers=0, remove_unused_columns=False,
        report_to='none', seed=seed,
    )
    trainer = Trainer(
        model=model, args=args, train_dataset=dataset,
        data_collator=lambda rows: collate(rows, tokenizer.pad_token_id),
    )
    trainer.train()
    final_path = output_path / 'final-adapter'
    trainer.save_model(str(final_path))
    tokenizer.save_pretrained(str(final_path))
    (output_path / 'training_log.json').write_text(
        json.dumps({'rows': len(dataset), 'epochs': epochs, 'max_length': max_length,
                    'seed': seed, 'steps': trainer.state.global_step,
                    'history': trainer.state.log_history}, ensure_ascii=False, indent=2),
        encoding='utf-8',
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--epochs', type=int, default=2)
    parser.add_argument('--max-length', type=int, default=384)
    parser.add_argument('--seed', type=int, default=20261026)
    parser.add_argument('--max-steps', type=int, default=-1, help='one-step memory smoke test if set to 1')
    options = parser.parse_args()
    if options.epochs < 1 or options.max_length < 32 or options.max_steps == 0:
        parser.error('invalid training dimensions')
    train(options.model, options.data, options.out, epochs=options.epochs,
          max_length=options.max_length, seed=options.seed, max_steps=options.max_steps)


if __name__ == '__main__':
    main()
