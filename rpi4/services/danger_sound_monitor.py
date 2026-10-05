"""Continuous danger-sound monitoring task — runs alongside ActExecutor.run()
on the RPi4 board (same board as the mic, per docs/architecture.md's Act/
Interpret split).

Feeds AudioReader frames into DangerSoundDetector and forwards every result
to ActExecutor.report_danger_sound(), which does the edge-triggered alert
send. This module owns no protocol knowledge — it's just the read-detect-
report loop.

2026-10-06: 같은 마이크 프레임을 다른 검출기(세탁기 종료음 — rpi4/services/appliance_done_watch.py)와
나눠 쓴다(``frame_listeners``). 마이크 입력 스트림을 둘 열지 않기 위해서다. 위험 소리 판정을 끄고
(``danger=False``) 프레임만 나눠 줄 수도 있다(SIMPLELAY_DANGER_SOUND_ENABLED가 꺼져 있고 종료음만 볼 때).
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable, Iterable

import numpy as np

from rpi.verifier import AudioReader, DangerSoundConfig, DangerSoundDetector

from .act_executor import ActExecutor

log = logging.getLogger(__name__)


class DangerSoundMonitor:
    """Args:
    reader:    Hardware or fake audio reader (same AudioReader ABC as AudioSensor).
    executor:  Receives edge-triggered alert reports.
    config:    Detector calibration; defaults to DangerSoundConfig() if omitted.
    clock:     Monotonic time source — injectable for tests.
    frame_listeners: 프레임마다 ``(pcm, 시각)``으로 부르는 함수들(선택). 실패해도 루프는 계속된다.
    danger:    False면 위험 소리 판정·경보 전송을 하지 않고 프레임만 나눠 준다.
    """

    def __init__(
        self,
        reader: AudioReader,
        executor: ActExecutor,
        config: DangerSoundConfig | None = None,
        clock: Callable[[], float] = time.monotonic,
        frame_listeners: Iterable[Callable[[np.ndarray, float], None]] = (),
        danger: bool = True,
    ) -> None:
        self._reader = reader
        self._executor = executor
        self._detector = DangerSoundDetector(config or DangerSoundConfig())
        self._clock = clock
        self._listeners = list(frame_listeners)
        self._danger = danger

    async def run(self) -> None:
        """Loop forever until cancelled — intended for asyncio.create_task()."""
        log.info("DangerSoundMonitor running (danger=%s, listeners=%d)", self._danger, len(self._listeners))
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
        now = self._clock()
        if self._danger:
            result = self._detector.process_frame(pcm, now)
            await self._executor.report_danger_sound(result)
        for listener in self._listeners:
            try:
                listener(pcm, now)
            except Exception:  # noqa: BLE001 - 다른 검출기 고장이 위험 소리 감지를 멈추지 않게
                log.exception("audio frame listener failed")
