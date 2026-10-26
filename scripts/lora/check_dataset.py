"""Audit an offline intent dataset against all protected evaluation sets."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from scripts.lora.make_dataset import (
    DEFAULT_SIMILARITY_THRESHOLD,
    load_eval_texts,
    normalize_text,
    overlaps_eval,
    validate_output_path,
)


def audit_dataset(path: Path, eval_paths: tuple[Path, ...] | None = None,
                  threshold: float = DEFAULT_SIMILARITY_THRESHOLD) -> dict:
    source = validate_output_path(path)
    references = load_eval_texts(eval_paths)
    seen = set()
    count = 0
    collisions = 0
    duplicates = 0
    with source.open(encoding='utf-8') as stream:
        for line in stream:
            if not line.strip():
                continue
            row = json.loads(line)
            text = row['text']
            normalized = normalize_text(text)
            duplicates += normalized in seen
            collisions += overlaps_eval(text, references, threshold)
            seen.add(normalized)
            count += 1
    result = {'rows': count, 'eval_references': len(references),
              'duplicates': duplicates, 'eval_collisions': collisions,
              'similarity_threshold': threshold}
    if not count or duplicates or collisions:
        raise ValueError(f'dataset audit failed: {result}')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--similarity-threshold', type=float,
                        default=DEFAULT_SIMILARITY_THRESHOLD)
    options = parser.parse_args()
    if not 0 < options.similarity_threshold <= 1:
        parser.error('similarity threshold must be in (0, 1]')
    print(json.dumps(audit_dataset(options.data, threshold=options.similarity_threshold)))


if __name__ == '__main__':
    main()
