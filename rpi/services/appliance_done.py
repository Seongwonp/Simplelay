"""RPi4 ``appliance_done`` 프레임(세탁 끝: CT 전력 + 종료음 융합)의 RPi5 쪽 해석·기록(2026-10-06).

프레임 모양은 docs/protocol.md "RPi4 → RPi5 추가 프레임"과 `rpi/verifier/done_fusion.py`
(`ApplianceDoneEvent.to_frame`). 상태와 입력이 맞지 않는 프레임(두 입력이라면서 하나만 등)은 받지 않는다 —
'끝났어요'를 지어내지 않기 위해서다. 기록은 증거 대장(가산점 (2) 멀티모달)용으로 최근 50건을 둔다.
"""

from __future__ import annotations

import re
import threading
from collections import deque
from collections.abc import Mapping

from rpi.verifier.done_fusion import DONE_INPUTS, DONE_SOURCES, DONE_STATES

_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
_EVENT = re.compile(r"[a-z][a-z0-9_]{0,63}")
_STATE_INPUTS = {
    "done_confirmed": {"power", "beep"},
    "done_power_only": {"power"},
    "done_beep_only": {"beep"},
}


def parse_appliance_done(doc: Mapping) -> dict | None:
    """검증한 기록(dict) 또는 None."""
    if not isinstance(doc, Mapping) or doc.get("type", "appliance_done") != "appliance_done":
        return None
    appliance = doc.get("appliance_id")
    event = doc.get("event")
    state = doc.get("state")
    source = doc.get("source")
    inputs = doc.get("inputs")
    if not (isinstance(appliance, str) and _ID.fullmatch(appliance)):
        return None
    if not (isinstance(event, str) and _EVENT.fullmatch(event)):
        return None
    if state not in DONE_STATES or source not in DONE_SOURCES:
        return None
    if not isinstance(inputs, list) or not inputs or any(i not in DONE_INPUTS for i in inputs):
        return None
    if set(inputs) != _STATE_INPUTS[state]:
        return None
    evidence = doc.get("evidence")
    return {
        "appliance_id": appliance,
        "event": event,
        "state": state,
        "confidence": "confirmed" if state == "done_confirmed" else "probable",
        "inputs": list(dict.fromkeys(inputs)),
        "expected_inputs": [i for i in doc.get("expected_inputs") or [] if i in DONE_INPUTS],
        "source": source,
        "gap_s": doc.get("gap_s") if isinstance(doc.get("gap_s"), (int, float)) else None,
        "fusion_window_s": doc.get("fusion_window_s"),
        "evidence": dict(evidence) if isinstance(evidence, Mapping) else {},
    }


class ApplianceDoneLog:
    """받은 완료 기록(최근 50건). 스레드 안전."""

    def __init__(self, clock=None) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._items: deque[dict] = deque(maxlen=50)

    def append(self, record: dict) -> dict:
        entry = dict(record)
        if self._clock is not None:
            entry["received_at"] = self._clock.now().isoformat()
        with self._lock:
            self._items.append(entry)
        return entry

    def recent(self) -> list[dict]:
        with self._lock:
            return list(reversed(self._items))
