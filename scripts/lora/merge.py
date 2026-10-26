"""Merge a local research adapter with its original model (outside the repo)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from scripts.lora.train import outside_repo


def add_gguf_norm_alias(config_path: Path) -> bool:
    """Expose the RMS epsilon key expected by the GGUF converter if needed."""
    config = json.loads(config_path.read_text(encoding='utf-8'))
    if 'layer_norm_epsilon' not in config or 'rms_norm_eps' in config:
        return False
    config['rms_norm_eps'] = config['layer_norm_epsilon']
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n',
                           encoding='utf-8')
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--adapter', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    options = parser.parse_args()
    model_path = outside_repo(options.model)
    adapter_path = outside_repo(options.adapter)
    output_path = outside_repo(options.out)
    output_path.mkdir(parents=True, exist_ok=True)

    import torch
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    model = AutoModelForCausalLM.from_pretrained(
        model_path, trust_remote_code=True, torch_dtype=torch.float16,
        device_map='cpu', low_cpu_mem_usage=True,
    )
    try:
        model.get_input_embeddings()
    except NotImplementedError:
        embedding = model.transformer.wte
        model.transformer.get_input_embeddings = lambda: embedding
        model.get_input_embeddings = lambda: embedding
    merged = PeftModel.from_pretrained(model, adapter_path).merge_and_unload()
    merged.save_pretrained(output_path, safe_serialization=True, max_shard_size='2GB')
    AutoTokenizer.from_pretrained(model_path, trust_remote_code=True).save_pretrained(output_path)
    # Some RMS-normalized models publish the epsilon under the generic name;
    # the GGUF converter expects the RMS-specific alias as metadata.
    add_gguf_norm_alias(output_path / 'config.json')


if __name__ == '__main__':
    main()
