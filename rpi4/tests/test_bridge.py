"""UartBridge tests — 12 cases, no real serial port required.

Test doubles
────────────
FakeWriter   — captures bytes written by the bridge (implements _WriterLike)
feed(reader) — convenience to inject a JSON line into an asyncio.StreamReader

All tests use asyncio.run() so no pytest-asyncio plugin is needed.
"""

from __future__ import annotations

import asyncio
import json
from collections import deque
from collections.abc import Iterable
from datetime import datetime, timezone

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import InMemoryUsageLog, RuleBasedIntentResolver
from rpi.intent.ports import Clock
from rpi.verifier import MockVerifier

from rpi4.services.bridge import UartBridge
from rpi4.services.sequence_store import SequenceStore


# ── test doubles ─────────────────────────────────────────────────────────────

class FakeWriter:
    """Captures bytes written by UartBridge without a real transport."""

    def __init__(self) -> None:
        self._buf = b""

    def write(self, data: bytes) -> None:
        self._buf += data

    async def drain(self) -> None:
        pass

    def messages(self) -> list[dict]:
        """Return all complete JSON lines written so far."""
        return [
            json.loads(line)
            for line in self._buf.split(b"\n")
            if line.strip()
        ]

    def clear(self) -> None:
        self._buf = b""


class FixedClock(Clock):
    def __init__(self, dt: datetime | None = None) -> None:
        self._dt = dt or datetime(2026, 8, 15, 12, 0, 0, tzinfo=timezone.utc)

    def now(self) -> datetime:
        return self._dt


def feed(reader: asyncio.StreamReader, doc: dict) -> None:
    """Inject one JSON line into a StreamReader."""
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


def _make_bridge(
    reader: asyncio.StreamReader,
    writer: FakeWriter,
    *,
    grbl_errors: Iterable[Exception | None] = (),
    verifier_outcomes: Iterable[bool] = (),
    usage_log: InMemoryUsageLog | None = None,
    store: SequenceStore | None = None,
) -> UartBridge:
    outcomes = list(verifier_outcomes) or [True] * 50
    controller = ClosedLoopController(
        grbl=MockGrblClient(grbl_errors),
        verifier=MockVerifier(outcomes=outcomes),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    return UartBridge(
        reader=reader,
        writer=writer,
        intent=RuleBasedIntentResolver(),
        controller=controller,
        usage_log=usage_log,
        store=store,
        clock=FixedClock(),
    )


def run(coro):
    return asyncio.run(coro)


# ── tests ─────────────────────────────────────────────────────────────────────

def test_intent_produces_sequence_with_correct_fields():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer)
        feed(reader, {"type": "intent", "text": "우유 데워줘", "timestamp": 0})
        await bridge.run_once()
        msgs = writer.messages()
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "sequence"
        assert m["label"] == "우유 데워줘"
        assert isinstance(m["id"], str) and m["id"]
        assert isinstance(m["buttons"], list) and len(m["buttons"]) > 0
    run(_t())


def test_unknown_intent_returns_result_with_failure_reason():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer)
        feed(reader, {"type": "intent", "text": "알 수 없는 명령", "timestamp": 0})
        await bridge.run_once()
        msgs = writer.messages()
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "result"
        assert m["success"] is False
        assert m["reason"] == "unknown_intent"
    run(_t())


def test_confirm_approved_with_successful_execution_returns_result_success():
    async def _t():
        store = SequenceStore()
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer, store=store)

        # Seed the store as if a prior intent had been processed.
        seq_id = "test-seq-001"
        await store.put(seq_id, "우유 데워줘", ("해동", "시간 90초", "시작"))

        feed(reader, {"type": "confirm", "sequence_id": seq_id, "approved": True})
        await bridge.run_once()

        msgs = writer.messages()
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "result"
        assert m["sequence_id"] == seq_id
        assert m["success"] is True
    run(_t())


def test_confirm_approved_with_failing_controller_returns_result_failure():
    async def _t():
        store = SequenceStore()
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        # All verifier outcomes are False → controller reports SAFETY_STOPPED.
        bridge = _make_bridge(reader, writer, verifier_outcomes=[False] * 20, store=store)

        seq_id = "test-seq-002"
        await store.put(seq_id, "우유 데워줘", ("해동",))

        feed(reader, {"type": "confirm", "sequence_id": seq_id, "approved": True})
        await bridge.run_once()

        msgs = writer.messages()
        assert len(msgs) == 1
        assert msgs[0]["type"] == "result"
        assert msgs[0]["success"] is False
    run(_t())


def test_confirm_rejected_sends_abort_and_clears_pending():
    async def _t():
        store = SequenceStore()
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer, store=store)

        seq_id = "test-seq-003"
        await store.put(seq_id, "우유 데워줘", ("해동",))

        feed(reader, {"type": "confirm", "sequence_id": seq_id, "approved": False})
        await bridge.run_once()

        msgs = writer.messages()
        assert len(msgs) == 1
        assert msgs[0]["type"] == "abort"
        # Sequence must have been removed from the store.
        assert await store.pop(seq_id) is None
    run(_t())


def test_abort_message_echoes_abort_and_clears_store():
    async def _t():
        store = SequenceStore()
        await store.put("x", "라벨", ("BT-01",))

        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer, store=store)

        feed(reader, {"type": "abort"})
        await bridge.run_once()

        msgs = writer.messages()
        assert len(msgs) == 1
        assert msgs[0]["type"] == "abort"
        assert await store.size() == 0
    run(_t())


def test_sensor_log_produces_no_response():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer)
        feed(reader, {"type": "sensor_log", "current_ma": 320, "sound_db": 45})
        await bridge.run_once()
        assert writer.messages() == []
    run(_t())


def test_malformed_json_produces_no_response_and_no_crash():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer)
        reader.feed_data(b"this is not json\n")
        await bridge.run_once()
        assert writer.messages() == []
    run(_t())


def test_unknown_message_type_produces_no_response_and_no_crash():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer)
        feed(reader, {"type": "future_type", "data": 42})
        await bridge.run_once()
        assert writer.messages() == []
    run(_t())


def test_intent_then_confirm_full_round_trip():
    async def _t():
        store = SequenceStore()
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer, store=store)

        # Step 1 — intent arrives.
        feed(reader, {"type": "intent", "text": "우유 데워줘", "timestamp": 0})
        await bridge.run_once()

        seq_msgs = writer.messages()
        assert len(seq_msgs) == 1
        assert seq_msgs[0]["type"] == "sequence"
        seq_id = seq_msgs[0]["id"]

        writer.clear()

        # Step 2 — user approves.
        feed(reader, {"type": "confirm", "sequence_id": seq_id, "approved": True})
        await bridge.run_once()

        result_msgs = writer.messages()
        assert len(result_msgs) == 1
        assert result_msgs[0]["type"] == "result"
        assert result_msgs[0]["sequence_id"] == seq_id
        assert result_msgs[0]["success"] is True
    run(_t())


def test_confirmed_execution_appends_to_usage_log():
    async def _t():
        store = SequenceStore()
        usage_log = InMemoryUsageLog()
        reader = asyncio.StreamReader()
        writer = FakeWriter()

        controller = ClosedLoopController(
            grbl=MockGrblClient(),
            verifier=MockVerifier(outcomes=[True] * 10),
            alerts=MockAlertSink(),
            safety=MockSafetyController(),
        )
        bridge = UartBridge(
            reader=reader,
            writer=writer,
            intent=RuleBasedIntentResolver(),
            controller=controller,
            usage_log=usage_log,
            store=store,
            clock=FixedClock(),
        )

        seq_id = "log-test-001"
        await store.put(seq_id, "우유 데워줘", ("해동",))
        feed(reader, {"type": "confirm", "sequence_id": seq_id, "approved": True})
        await bridge.run_once()

        records = usage_log.records()
        assert len(records) == 1
        assert records[0].purpose == "우유 데워줘"
    run(_t())


def test_confirm_with_unknown_seq_id_is_silently_ignored():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        bridge = _make_bridge(reader, writer)
        feed(reader, {"type": "confirm", "sequence_id": "ghost-id", "approved": True})
        await bridge.run_once()
        # No response — bridge swallows stale confirms gracefully.
        assert writer.messages() == []
    run(_t())
