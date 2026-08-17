"""End-to-end loopback: a real ActClient (RPi5 side) wired directly to a
real ActExecutor (RPi4 side) via in-memory pipes -- no serial port, no mocks
of either protocol implementation itself.

ActClient (rpi/services/act_client.py) and ActExecutor
(rpi4/services/act_executor.py) were built and unit-tested independently
against hand-written JSON fixtures matching docs/protocol.md. Those tests
prove each side parses/emits the documented shapes correctly, but never
proved the two actually agree with each other. This file closes that gap by
running them against each other for real.
"""

from __future__ import annotations

import asyncio

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.services.act_client import ActClient, ActLinkError
from rpi.verifier import DangerSoundResult, MockVerifier

from rpi4.services.act_executor import ActExecutor


class _PipeWriter:
    """Feeds writes straight into a paired asyncio.StreamReader -- links two
    executor/client instances together without a real serial port."""

    def __init__(self, peer_reader: asyncio.StreamReader) -> None:
        self._peer_reader = peer_reader

    def write(self, data: bytes) -> None:
        self._peer_reader.feed_data(data)

    async def drain(self) -> None:
        pass


def _make_link() -> tuple[asyncio.StreamReader, _PipeWriter, asyncio.StreamReader, _PipeWriter]:
    """Returns (rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer) cross-wired
    so that whatever one side writes, the other side reads."""
    rpi4_reader = asyncio.StreamReader()
    rpi5_reader = asyncio.StreamReader()
    rpi4_writer = _PipeWriter(rpi5_reader)  # ActExecutor writes -> ActClient reads
    rpi5_writer = _PipeWriter(rpi4_reader)  # ActClient writes -> ActExecutor reads
    return rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer


def _make_executor(reader, writer, *, verifier_outcomes=None) -> ActExecutor:
    outcomes = verifier_outcomes if verifier_outcomes is not None else [True] * 50
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=MockVerifier(outcomes=outcomes),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    return ActExecutor(reader=reader, writer=writer, controller=controller)


def run(coro):
    return asyncio.run(coro)


def test_client_execute_succeeds_against_a_real_executor():
    async def _t():
        rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer = _make_link()
        executor = _make_executor(rpi4_reader, rpi4_writer)
        client = ActClient(rpi5_reader, rpi5_writer)
        await client.start()
        executor_task = asyncio.create_task(executor.run_once())

        result = await client.execute(["시작"], sequence_id="link-1")

        await executor_task
        assert result.sequence_id == "link-1"
        assert result.success is True
        assert result.retry == 0
        await client.stop()
    run(_t())


def test_client_execute_reports_real_retries_from_the_executor():
    async def _t():
        rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer = _make_link()
        # Fails twice, then succeeds -> 3 attempts, 2 retries -- exercises the
        # real ClosedLoopController retry path, not a canned fixture.
        executor = _make_executor(rpi4_reader, rpi4_writer, verifier_outcomes=[False, False, True])
        client = ActClient(rpi5_reader, rpi5_writer)
        await client.start()
        executor_task = asyncio.create_task(executor.run_once())

        result = await client.execute(["시작"], sequence_id="link-2")

        await executor_task
        assert result.success is True
        assert result.retry == 2
        await client.stop()
    run(_t())


def test_client_execute_raises_on_a_real_actuator_failure():
    async def _t():
        rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer = _make_link()

        class ExplodingController:
            def execute(self, buttons):
                raise RuntimeError("boom")

        executor = ActExecutor(reader=rpi4_reader, writer=rpi4_writer, controller=ExplodingController())
        client = ActClient(rpi5_reader, rpi5_writer)
        await client.start()
        executor_task = asyncio.create_task(executor.run_once())

        with pytest.raises(ActLinkError, match="actuator_fail"):
            await client.execute(["시작"], sequence_id="link-3")

        await executor_task
        await client.stop()
    run(_t())


def test_client_receives_a_real_danger_sound_alert_from_the_executor():
    async def _t():
        rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer = _make_link()
        executor = _make_executor(rpi4_reader, rpi4_writer)
        received = []
        client = ActClient(rpi5_reader, rpi5_writer, on_alert=received.append)
        await client.start()

        await executor.report_danger_sound(
            DangerSoundResult(detected=True, band_energy_ratio=0.81, cycle_count=6, mean_period_seconds=0.5)
        )
        await asyncio.sleep(0.02)  # let the client's read loop process it

        assert len(received) == 1
        assert received[0].kind == "danger_sound"
        assert received[0].raised is True
        assert received[0].mean_period_seconds == 0.5

        await executor.report_danger_sound(
            DangerSoundResult(detected=False, band_energy_ratio=0.1, cycle_count=0)
        )
        await asyncio.sleep(0.02)

        assert len(received) == 2
        assert received[1].raised is False
        await client.stop()
    run(_t())


def test_alert_arrives_correctly_even_while_an_execute_is_in_flight():
    async def _t():
        rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer = _make_link()
        executor = _make_executor(rpi4_reader, rpi4_writer)
        received = []
        client = ActClient(rpi5_reader, rpi5_writer, on_alert=received.append)
        await client.start()

        exec_task = asyncio.create_task(client.execute(["시작"], sequence_id="link-4"))
        # give the executor a beat to pick up the execute request
        await asyncio.sleep(0)
        executor_run_task = asyncio.create_task(executor.run_once())

        await executor.report_danger_sound(
            DangerSoundResult(detected=True, band_energy_ratio=0.9, cycle_count=6, mean_period_seconds=0.4)
        )
        await asyncio.sleep(0.02)

        result = await exec_task
        await executor_run_task

        assert result.success is True
        assert len(received) == 1
        assert received[0].raised is True
        await client.stop()
    run(_t())
