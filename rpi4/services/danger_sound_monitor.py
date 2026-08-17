"""Continuous danger-sound monitoring task — runs alongside ActExecutor.run()
on the RPi4 board (same board as the mic, per docs/architecture.md's Act/
Interpret split).

Feeds AudioReader frames into DangerSoundDetector and forwards every result
to ActExecutor.report_danger_sound(), which does the edge-triggered alert
send. This module owns no protocol knowledge — it's just the read-detect-
report loop.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable

from rpi.verifier import AudioReader, DangerSoundConfig, DangerSoundDetector

from .act_executor import ActExecutor

log = logging.getLogger(__name__)


class DangerSoundMonitor:
    """Args:
    reader:    Hardware or fake audio reader (same AudioReader ABC as AudioSensor).
    executor:  Receives edge-triggered alert reports.
    config:    Detector calibration; defaults to DangerSoundConfig() if omitted.
    clock:     Monotonic time source — injectable for tests.
    """

    def __init__(
        self,
        reader: AudioReader,
        executor: ActExecutor,
        config: DangerSoundConfig | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._reader = reader
        self._executor = executor
        self._detector = DangerSoundDetector(config or DangerSoundConfig())
        self._clock = clock

    async def run(self) -> None:
        """Loop forever until cancelled — intended for asyncio.create_task()."""
        log.info("DangerSoundMonitor running")
        try:
            while True:
                await self.tick()
        except asyncio.CancelledError:
            log.info("DangerSoundMonitor: cancelled")
            raise

    async def tick(self) -> None:
        """Read and process exactly one frame — exposed for step-by-step tests."""
        # read_frame() blocks on real hardware; keep the event loop responsive
        # to UART traffic the same way ActExecutor._on_execute offloads work.
        pcm = await asyncio.to_thread(self._reader.read_frame)
        result = self._detector.process_frame(pcm, self._clock())
        await self._executor.report_danger_sound(result)
