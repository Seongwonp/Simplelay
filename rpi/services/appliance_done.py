"""RPi4 ``appliance_done`` 프레임(세탁 끝: CT 전력 + 종료음 융합)의 RPi5 쪽 해석·기록(2026-10-06).

프레임 모양은 docs/protocol.md "RPi4 → RPi5 추가 프레임"과 `rpi/verifier/done_fusion.py`
(`ApplianceDoneEvent.to_frame`). 상태와 입력이 맞지 않는 프레임(두 입력이라면서 하나만 등)은 받지 않는다 —
'끝났어요'를 지어내지 않기 위해서다. 기록은 증거 대장(가산점 (2) 멀티모달)용으로 최근 50건을 둔다.
"""

from __future__ import annotations

import math
import re
import threading
import time
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


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


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
    at_s = doc.get("at_s")
    sent_ns = doc.get("t_monotonic_ns")
    return {
        # RPi4 단조 시각(2026-10-13, 자동 실행 규칙): 끝의 물리 시각(at_s)과 프레임을 낸 시각(t_monotonic_ns).
        # 같은 사건 판별(재전송·재연결)과 사건 나이(내보낸 시각 - 끝 시각)에 쓴다. 없거나 숫자가 아니면 None.
        "at_s": float(at_s) if _number(at_s) else None,
        "t_monotonic_ns": int(sent_ns) if _number(sent_ns) else None,
        # 그 시각들의 단조 시계(RPi4 프로세스) 식별자(3차 평가 M1). 받는 쪽은 같은 식별자의 기준점이 있을 때만
        # 자기 시계로 옮긴다(rpi/services/event_clock.py). 없거나 형식이 틀리면 None — 자동 실행은 보류.
        "clock_id": doc.get("clock_id") if isinstance(doc.get("clock_id"), str)
        and _ID.fullmatch(doc.get("clock_id")) else None,
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
    """받은 완료 기록(최근 50건). 스레드 안전.

    루틴 ``wait_until_done``(시연 v3 갭 M2)이 기다릴 수 있게 받은 순서 번호를 매긴다: 구간을 보내기 전에 `mark`를
    잡고, 그 뒤에 온 그 가전의 기록만 `wait_for`로 받는다(지난 사이클의 끝을 세지 않는다).
    """

    def __init__(self, clock=None) -> None:
        self._clock = clock
        self._cond = threading.Condition()
        self._items: deque[dict] = deque(maxlen=50)
        self._seq = 0

    def append(self, record: dict) -> dict:
        entry = dict(record)
        if self._clock is not None:
            entry["received_at"] = self._clock.now().isoformat()
        with self._cond:
            self._seq += 1
            entry["_seq"] = self._seq
            self._items.append(entry)
            self._cond.notify_all()
        return {k: v for k, v in entry.items() if k != "_seq"}

    def recent(self) -> list[dict]:
        with self._cond:
            return [{k: v for k, v in e.items() if k != "_seq"} for e in reversed(self._items)]

    def mark(self) -> int:
        """지금까지 받은 기록의 번호. 이 뒤에 온 것만 `wait_for`가 본다."""
        with self._cond:
            return self._seq

    def wait_for(self, appliance_id: str, after: int, timeout_s: float,
                 cancel: threading.Event | None = None, *, poll_s: float = 0.1) -> dict | None:
        """``after`` 뒤에 온 그 가전의 첫 기록. ``timeout_s``가 지나거나 ``cancel``이 서면 None."""
        deadline = time.monotonic() + timeout_s
        with self._cond:
            while True:
                for entry in self._items:
                    if entry["_seq"] > after and entry.get("appliance_id") == appliance_id:
                        return {k: v for k, v in entry.items() if k != "_seq"}
                remaining = deadline - time.monotonic()
                if remaining <= 0 or (cancel is not None and cancel.is_set()):
                    return None
                self._cond.wait(min(remaining, poll_s))
