"""DangerSoundMonitor tests — no real microphone required."""

from __future__ import annotations

import asyncio

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier import DangerSoundConfig, FakeAudioReader, MockVerifier

from rpi4.services.act_executor import ActExecutor
from rpi4.services.danger_sound_monitor import DangerSoundMonitor
from rpi4.tests.test_act_executor import FakeWriter

_CHUNK = 512
_RATE = 16_000
_ALARM_TONE_HZ = 3500.0


def _make_executor() -> tuple[ActExecutor, FakeWriter]:
    writer = FakeWriter()
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=MockVerifier(outcomes=[True] * 50),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    executor = ActExecutor(reader=asyncio.StreamReader(), writer=writer, controller=controller)
    return executor, writer


def _fast_config(**overrides) -> DangerSoundConfig:
    params = {
        "min_cycles": 3,
        "min_period_seconds": 0.1,
        "max_period_seconds": 1.0,
        "window_seconds": 10.0,
        **overrides,
    }
    return DangerSoundConfig(**params)


def run(coro):
    return asyncio.run(coro)


def test_tick_forwards_a_single_frame_to_the_detector_and_executor():
    async def _t():
        executor, writer = _make_executor()
        reader = FakeAudioReader([FakeAudioReader.tone(_ALARM_TONE_HZ, _CHUNK, _RATE)])
        clock_values = iter([0.0])
        monitor = DangerSoundMonitor(
            reader, executor, config=_fast_config(), clock=lambda: next(clock_values)
        )

        await monitor.tick()

        # A single onset is below min_cycles=3 — no alert message yet.
        assert writer.messages() == []
    run(_t())


def test_repeated_periodic_ticks_raise_an_alert():
    async def _t():
        executor, writer = _make_executor()
        tone = FakeAudioReader.tone(_ALARM_TONE_HZ, _CHUNK, _RATE)
        silence = FakeAudioReader.silence(_CHUNK)
        # tone/silence pairs at t=0.0, 0.4, 0.8, 1.2 — steady 0.4s period.
        frames = [tone, silence, tone, silence, tone, silence, tone, silence]
        times = [0.0, 0.1, 0.4, 0.5, 0.8, 0.9, 1.2, 1.3]
        reader = FakeAudioReader(frames)
        clock_values = iter(times)
        monitor = DangerSoundMonitor(
            reader, executor, config=_fast_config(), clock=lambda: next(clock_values)
        )

        for _ in times:
            await monitor.tick()

        msgs = writer.messages()
        assert msgs[-1]["type"] == "alert"
        assert msgs[-1]["kind"] == "danger_sound"
    run(_t())


def test_silence_never_raises_an_alert():
    async def _t():
        executor, writer = _make_executor()
        reader = FakeAudioReader([FakeAudioReader.silence(_CHUNK)] * 20)
        clock_values = iter(i * 0.1 for i in range(20))
        monitor = DangerSoundMonitor(
            reader, executor, config=_fast_config(), clock=lambda: next(clock_values)
        )

        for _ in range(20):
            await monitor.tick()

        assert writer.messages() == []
    run(_t())


def test_run_loop_can_be_cancelled():
    async def _t():
        executor, _writer = _make_executor()
        reader = FakeAudioReader([FakeAudioReader.silence(_CHUNK)])
        monitor = DangerSoundMonitor(reader, executor, config=_fast_config(), clock=lambda: 0.0)

        task = asyncio.create_task(monitor.run())
        await asyncio.sleep(0.05)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        assert task.cancelled()
    run(_t())
