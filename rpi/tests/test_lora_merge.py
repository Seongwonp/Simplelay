import json

from scripts.lora.merge import add_gguf_norm_alias


def test_merge_exposes_norm_metadata_for_gguf(tmp_path):
    config = tmp_path / 'config.json'
    config.write_text(json.dumps({'layer_norm_epsilon': 1e-5}), encoding='utf-8')
    assert add_gguf_norm_alias(config)
    assert json.loads(config.read_text(encoding='utf-8'))['rms_norm_eps'] == 1e-5
    assert not add_gguf_norm_alias(config)
