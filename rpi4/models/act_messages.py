"""Typed representations of the RPi5 → RPi4 UART protocol (docs/protocol.md).

This is a *different* leg than models/messages.py (which covers ESP32 ↔
the Interpret side). Here RPi5 has already resolved a purpose into a button
sequence and just wants RPi4 to execute it — no intent resolution happens
on this leg.

Inbound (RPi5 → RPi4):
  execute        — already-resolved button sequence to run through the closed loop
  abort          — cancel; forwarded to the safety controller
  inject_failure — arm demo failure injection for the next execution (rehearsal)
  clear_failure  — disarm a previously armed injection

Outbound (RPi4 → RPi5): plain dicts serialised by ActExecutor._send().
"""

from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass(frozen=True)
class ExecuteMsg:
    sequence_id: str
    buttons: tuple[str, ...]


@dataclass(frozen=True)
class AbortMsg:
    pass


@dataclass(frozen=True)
class InjectFailureMsg:
    """리허설 실패 주입 무장 — POST /demo/inject-failure의 UART 전달판.
    검증이 RPi4에서 일어나는 UART 모드에서도 결선 핵심 장면("일부러
    실패시켜도 스스로 재시도")을 연출할 수 있게 한다."""

    button_index: int
    attempts: int


@dataclass(frozen=True)
class ClearFailureMsg:
    pass


InboundActMsg = ExecuteMsg | AbortMsg | InjectFailureMsg | ClearFailureMsg


def parse_act_message(raw: str) -> InboundActMsg | None:
    """Parse one JSON line from the RPi5 serial stream.

    Returns None for malformed JSON, non-dict payloads, unknown ``type``
    fields, or structurally invalid known types (e.g. execute with no
    buttons). Never raises; callers can safely ignore a None return.
    """
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return None

    if not isinstance(doc, dict):
        return None

    msg_type = doc.get("type")

    if msg_type == "execute":
        seq_id = doc.get("sequence_id", "")
        buttons = doc.get("buttons", [])
        if not isinstance(seq_id, str) or not seq_id.strip():
            return None
        if not isinstance(buttons, list) or not buttons:
            return None
        if not all(isinstance(b, str) and b.strip() for b in buttons):
            return None
        return ExecuteMsg(sequence_id=seq_id.strip(), buttons=tuple(buttons))

    if msg_type == "abort":
        return AbortMsg()

    if msg_type == "inject_failure":
        button_index = doc.get("button_index")
        attempts = doc.get("attempts")
        # 스키마(DemoInjectFailureRequest)와 같은 범위 — 링크 건너편이라고
        # 검증을 느슨하게 하지 않는다
        if not isinstance(button_index, int) or isinstance(button_index, bool):
            return None
        if not isinstance(attempts, int) or isinstance(attempts, bool):
            return None
        if button_index < 0 or not 1 <= attempts <= 10:
            return None
        return InjectFailureMsg(button_index=button_index, attempts=attempts)

    if msg_type == "clear_failure":
        return ClearFailureMsg()

    return None  # unknown type — not an error, just silently ignored
