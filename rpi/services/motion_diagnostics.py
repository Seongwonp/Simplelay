"""Bounded, allowlisted motion events for the authenticated developer view."""

import json
import math
import re


def motion_trace_rows(raw: object) -> list[dict]:
    if not isinstance(raw, str) or len(raw) > 16000:
        return []
    try:
        rows = json.loads(raw)
    except (ValueError, TypeError):
        return []
    if not isinstance(rows, list):
        return []
    result = []
    for row in rows[-32:]:
        if not isinstance(row, dict):
            continue
        clean = {}
        for key in ('seq', 'generation', 'elapsed_ms', 'x_mm', 'y_mm', 'target_x_mm', 'target_y_mm'):
            v = row.get(key)
            if isinstance(v, (int, float)) and not isinstance(v, bool) and -1e308 <= v <= 1e308 and math.isfinite(v):
                clean[key] = v
        for key in ('commandId', 'action', 'state', 'context_id'):
            v = row.get(key)
            if isinstance(v, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,48}', v):
                clean[key] = v
        direction = row.get('direction')
        if direction not in ('tx', 'rx', 'timeout', 'boot', 'link_down'):
            continue
        clean['direction'] = direction
        if type(row.get('homed')) is bool:
            clean['homed'] = row['homed']
        result.append(clean)
    return result
