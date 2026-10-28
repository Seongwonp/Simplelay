"""Typed representations of every UART message exchanged with ESP32.

This is UartBridge's message set — the ESP32 <-> RPi5(Interpret) leg, despite
living in the rpi4/ package (see services/bridge.py's module docstring).

Inbound (ESP32 → RPi5):
  intent     — voice text from app; trigger intent resolution
  confirm    — user approved or rejected the suggested sequence
  abort      — hardware E-STOP or app emergency_stop
  sensor_log — raw ADC/mic readings (not forwarded from here; see
               services/bridge.py's _on_sensor_log)

Outbound (RPi5 → ESP32): plain dicts serialised by UartBridge._send().
"""

from __future__ import annotations

import json
from dataclasses import dataclass


# Inbound message types

@dataclass(frozen=True)
class IntentMsg:
    text: str
    timestamp: int = 0


@dataclass(frozen=True)
class ConfirmMsg:
    sequence_id: str
    approved: bool


@dataclass(frozen=True)
class AbortMsg:
    pass


@dataclass(frozen=True)
class SensorLogMsg:
    current_ma: int
    sound_db: int


InboundMsg = IntentMsg | ConfirmMsg | AbortMsg | SensorLogMsg


# Parser

def parse_message(raw: str) -> InboundMsg | None:
    """Parse one JSON line from the ESP32 serial stream.

    Returns None for:
    - Malformed JSON
    - Unknown ``type`` fields (forward-compatible: new firmware types are ignored)
    - Structurally invalid known types (e.g. intent with blank text)

    Never raises; callers can safely ignore a None return.
    """
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return None

    if not isinstance(doc, dict):
        return None

    msg_type = doc.get("type")

    if msg_type == "intent":
        text = doc.get("text", "")
        if not isinstance(text, str) or not text.strip():
            return None
        return IntentMsg(
            text=text.strip(),
            timestamp=int(doc.get("timestamp", 0)),
        )

    if msg_type == "confirm":
        seq_id = doc.get("sequence_id", "")
        if not isinstance(seq_id, str) or not seq_id.strip():
            return None
        return ConfirmMsg(
            sequence_id=seq_id.strip(),
            approved=bool(doc.get("approved", False)),
        )

    if msg_type == "abort":
        return AbortMsg()

    if msg_type == "sensor_log":
        return SensorLogMsg(
            current_ma=int(doc.get("current_ma", 0)),
            sound_db=int(doc.get("sound_db", 0)),
        )

    return None  # unknown type — not an error, just silently ignored
