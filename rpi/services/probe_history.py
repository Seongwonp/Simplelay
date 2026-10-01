"""Opt-in historical diagnostics. Deliberately has no readiness dependency."""
import json
import os
from datetime import datetime

from rpi.tools.board_probe.core import outside, summary


def load_last_probe():
    directory = os.getenv("SIMPLELAY_PROBE_HISTORY_DIR")
    if not directory:
        return None
    candidates = sorted(outside(directory).glob("*.json"), reverse=True)
    if not candidates:
        return None
    # Do not fall back to an older success if the latest file is corrupt.
    path = outside(candidates[0])
    if path.stat().st_size > 2_000_000:
        raise ValueError("점검 기록 크기 초과")
    report = json.loads(path.read_text(encoding="utf-8"))
    stamp = datetime.fromisoformat(report["timestamp_utc"])
    if stamp.tzinfo is None:
        raise ValueError("측정 시각의 시간대 누락")
    return {"label": f"이전 점검 기록({stamp.isoformat()})",
            "measured_at": stamp.isoformat(), "historical_only": True,
            "summary_markdown": summary(report)}
