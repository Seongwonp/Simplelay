"""UartBridge — asyncio message router between ESP32 UART and the rpi/ brain.

Message routing table (protocol.md):

  INBOUND (ESP32 → RPi4)          OUTBOUND (RPi4 → ESP32)
  ──────────────────────────────────────────────────────────
  intent {text}          →  sequence {id, label, buttons}
                         |  result   {success:F, reason:'unknown_intent'}  (on error)
  confirm {id, True}     →  result   {id, success}
  confirm {id, False}    →  abort
  abort                  →  abort
  sensor_log {ma, db}    →  (no response; Phase C: route to verifier)

The class accepts duck-typed writer/reader objects so it is fully testable
without a real serial port:
  - real hardware: asyncio.StreamReader / asyncio.StreamWriter from serial_asyncio
  - tests:         asyncio.StreamReader.feed_data()  /  FakeWriter(BytesIO)
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from typing import Protocol

from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.intent import IntentResolver, UnknownIntentError, UsageLog, UsageOutcome, UsageRecord
from rpi.intent.ports import Clock

from ..models.messages import (
    AbortMsg,
    ConfirmMsg,
    InboundMsg,
    IntentMsg,
    SensorLogMsg,
    parse_message,
)
from .sequence_store import SequenceStore

log = logging.getLogger(__name__)


class _WriterLike(Protocol):
    """Minimal interface required by UartBridge; satisfies both asyncio.StreamWriter
    and test doubles without inheritance."""

    def write(self, data: bytes) -> None: ...
    async def drain(self) -> None: ...


class UartBridge:
    """Reads newline-delimited JSON from the ESP32, dispatches to rpi/ logic,
    writes JSON responses back.

    Args:
        reader:     asyncio.StreamReader (serial or test-injected)
        writer:     asyncio.StreamWriter-compatible (serial or FakeWriter)
        intent:     Resolves voice text → button sequence
        controller: Executes a button sequence with closed-loop verification
        usage_log:  Optional log for executed sequences
        store:      Pending-sequence store (default: fresh SequenceStore)
        clock:      Time source for usage log timestamps
    """

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: _WriterLike,
        intent: IntentResolver,
        controller: ClosedLoopController,
        usage_log: UsageLog | None = None,
        store: SequenceStore | None = None,
        clock: Clock | None = None,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._intent = intent
        self._controller = controller
        self._usage_log = usage_log
        self._store = store or SequenceStore()
        self._clock = clock

    # ── Public API ───────────────────────────────────────────────────────────

    async def run(self) -> None:
        """Read lines until EOF or task cancellation."""
        log.info("UartBridge running")
        try:
            while True:
                await self.run_once()
        except asyncio.IncompleteReadError:
            log.info("UartBridge: serial stream closed (EOF)")
        except asyncio.CancelledError:
            log.info("UartBridge: cancelled")
            raise

    async def run_once(self) -> None:
        """Read exactly one newline-terminated line and dispatch it.

        Exposed separately so tests can drive the bridge message-by-message
        without spinning up a full asyncio task.
        """
        raw_bytes = await self._reader.readuntil(b"\n")
        raw = raw_bytes.decode("utf-8", errors="replace").strip()
        if not raw:
            return

        log.debug("RX ← %s", raw)
        msg = parse_message(raw)
        if msg is None:
            log.warning("ignored unrecognised line: %.120s", raw)
            return

        await self._dispatch(msg)

    # ── Dispatch ─────────────────────────────────────────────────────────────

    async def _dispatch(self, msg: InboundMsg) -> None:
        if isinstance(msg, IntentMsg):
            await self._on_intent(msg)
        elif isinstance(msg, ConfirmMsg):
            await self._on_confirm(msg)
        elif isinstance(msg, AbortMsg):
            await self._on_abort()
        elif isinstance(msg, SensorLogMsg):
            self._on_sensor_log(msg)

    # ── Handlers ─────────────────────────────────────────────────────────────

    async def _on_intent(self, msg: IntentMsg) -> None:
        try:
            buttons = self._intent.resolve(msg.text)
        except UnknownIntentError:
            log.warning("unknown intent: %r", msg.text)
            await self._send({"type": "result", "success": False, "reason": "unknown_intent"})
            return

        seq_id = str(uuid.uuid4())
        await self._store.put(seq_id, msg.text, buttons)

        await self._send({
            "type": "sequence",
            "id": seq_id,
            "label": msg.text,
            "buttons": list(buttons),
        })
        log.info("sequence %s dispatched — %d button(s) for %r", seq_id, len(buttons), msg.text)

    async def _on_confirm(self, msg: ConfirmMsg) -> None:
        pending = await self._store.pop(msg.sequence_id)

        if pending is None:
            # Duplicate confirm or stale seq_id — silently ignore to stay robust.
            log.warning("confirm for unknown seq_id %r — ignored", msg.sequence_id)
            return

        if not msg.approved:
            log.info("sequence %r rejected by user", msg.sequence_id)
            await self._send({"type": "abort"})
            return

        # Run the synchronous controller in a thread so the event loop stays
        # responsive to incoming UART data during execution.
        result = await asyncio.to_thread(self._controller.execute, pending.buttons)

        success = result.status is ExecutionStatus.SUCCEEDED

        if self._usage_log is not None and self._clock is not None:
            outcome = UsageOutcome.SUCCEEDED if success else UsageOutcome.FAILED
            self._usage_log.append(
                UsageRecord(self._clock.now(), pending.label, outcome)
            )

        await self._send({
            "type": "result",
            "sequence_id": msg.sequence_id,
            "success": success,
        })
        log.info("sequence %r finished — %s", msg.sequence_id, "ok" if success else "FAILED")

    async def _on_abort(self) -> None:
        await self._store.clear()
        await self._send({"type": "abort"})
        log.warning("abort received from ESP32 — all pending sequences cleared")

    def _on_sensor_log(self, msg: SensorLogMsg) -> None:
        # Phase C TODO: forward to SensorVerifier running on RPi4.
        log.debug("sensor_log: %d mA, %d dB", msg.current_ma, msg.sound_db)

    # ── IO helper ────────────────────────────────────────────────────────────

    async def _send(self, doc: dict) -> None:
        payload = (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
        log.debug("TX → %s", payload.rstrip().decode())
        self._writer.write(payload)
        await self._writer.drain()
