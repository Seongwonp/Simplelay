"""SequenceStore unit tests — 5 cases."""

import asyncio

import pytest

from rpi4.services.sequence_store import PendingSequence, SequenceStore


# ── helpers ──────────────────────────────────────────────────────────────────

def run(coro):
    return asyncio.run(coro)


BUTTONS = ("즉석밥", "시작")


# ── tests ────────────────────────────────────────────────────────────────────

def test_put_and_pop_returns_correct_sequence():
    async def _t():
        store = SequenceStore()
        await store.put("seq-1", "즉석밥 데워줘", BUTTONS)
        result = await store.pop("seq-1")
        assert result == PendingSequence(label="즉석밥 데워줘", buttons=BUTTONS)
    run(_t())


def test_pop_nonexistent_id_returns_none():
    async def _t():
        store = SequenceStore()
        assert await store.pop("no-such-id") is None
    run(_t())


def test_put_same_id_overwrites_previous():
    async def _t():
        store = SequenceStore()
        await store.put("seq-1", "first", ("BT-01",))
        await store.put("seq-1", "second", ("BT-02",))
        result = await store.pop("seq-1")
        assert result.label == "second"
        assert result.buttons == ("BT-02",)
    run(_t())


def test_clear_removes_all_entries():
    async def _t():
        store = SequenceStore()
        await store.put("a", "라벨A", ("BT-01",))
        await store.put("b", "라벨B", ("BT-02",))
        await store.clear()
        assert await store.size() == 0
        assert await store.pop("a") is None
        assert await store.pop("b") is None
    run(_t())


def test_concurrent_puts_and_pops_are_consistent():
    async def _t():
        store = SequenceStore()

        async def _writer(i: int):
            await store.put(f"seq-{i}", f"label-{i}", (f"BT-{i:02d}",))

        async def _reader(i: int) -> PendingSequence | None:
            # brief yield so writers and readers interleave
            await asyncio.sleep(0)
            return await store.pop(f"seq-{i}")

        n = 20
        await asyncio.gather(*[_writer(i) for i in range(n)])
        results = await asyncio.gather(*[_reader(i) for i in range(n)])

        # Every item written must be popped exactly once (no duplicates, no loss).
        found = [r for r in results if r is not None]
        assert len(found) == n
        labels = {r.label for r in found}
        assert labels == {f"label-{i}" for i in range(n)}
    run(_t())
