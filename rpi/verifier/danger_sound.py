"""Continuous danger-sound (fire/gas alarm) detector.

Unlike AudioSensor.is_pressed() (single-frame, "was a button just pressed?"),
this is stateful across many frames — it looks for a sound that keeps
repeating at a roughly steady interval, which is how piezo alarm buzzers
behave and appliance completion chimes (a handful of beeps, then silence)
do not.

Detection is two-stage:
  1. Band-energy ratio in the alarm frequency band (see DangerSoundConfig) —
     reuses the same FFT approach as AudioSensor.
  2. Periodicity of the resulting onsets (rising edges) — requires
     min_cycles consecutive, mutually-consistent intervals inside
     [min_period_seconds, max_period_seconds] before declaring detected.
"""

from __future__ import annotations

from dataclasses import dataclass
from statistics import mean, pstdev

import numpy as np

from .audio_sensor import _band_energy_ratio
from .config import DangerSoundConfig


@dataclass(frozen=True)
class DangerSoundResult:
    """Outcome of feeding one frame into DangerSoundDetector."""

    detected: bool
    band_energy_ratio: float
    cycle_count: int
    mean_period_seconds: float | None = None


def _periodicity_score(
    intervals: list[float],
    min_period: float,
    max_period: float,
    max_relative_stddev: float = 0.25,
) -> tuple[bool, float]:
    """Check whether a run of onset intervals looks like a steady repeat.

    Returns (is_periodic, mean_period). All intervals must fall inside
    [min_period, max_period] and be mutually consistent (relative stddev
    below max_relative_stddev) — a handful of intervals is not enough to
    trust a stddev estimate, so callers should also enforce a minimum
    interval count (DangerSoundConfig.min_cycles - 1) before calling this.
    """
    if not intervals:
        return False, 0.0
    if any(not (min_period <= i <= max_period) for i in intervals):
        return False, 0.0
    avg = mean(intervals)
    if len(intervals) == 1:
        return True, avg
    spread = pstdev(intervals)
    relative_spread = spread / avg if avg > 0 else float("inf")
    return relative_spread <= max_relative_stddev, avg


class DangerSoundDetector:
    """Stateful detector — feed it consecutive PCM frames via process_frame().

    Args:
        config: Calibration parameters (frequency band, thresholds, timing).
    """

    def __init__(self, config: DangerSoundConfig) -> None:
        self._cfg = config
        self._onset_timestamps: list[float] = []
        self._was_above_threshold = False

    def process_frame(self, pcm: np.ndarray, timestamp: float) -> DangerSoundResult:
        """Feed one frame (with its capture timestamp, seconds) and get a result.

        timestamp must be monotonically non-decreasing across calls — it is
        the caller's clock (e.g. time.monotonic()), not derived from audio.
        """
        ratio = _band_energy_ratio(
            pcm,
            self._cfg.sample_rate,
            self._cfg.freq_low_hz,
            self._cfg.freq_high_hz,
        )
        is_above = ratio >= self._cfg.band_energy_threshold

        # Rising edge = new onset.
        if is_above and not self._was_above_threshold:
            self._onset_timestamps.append(timestamp)
        self._was_above_threshold = is_above

        self._drop_stale_onsets(timestamp)

        if len(self._onset_timestamps) < self._cfg.min_cycles:
            return DangerSoundResult(False, ratio, len(self._onset_timestamps))

        recent = self._onset_timestamps[-self._cfg.min_cycles :]
        intervals = [b - a for a, b in zip(recent, recent[1:])]
        is_periodic, avg_period = _periodicity_score(
            intervals,
            self._cfg.min_period_seconds,
            self._cfg.max_period_seconds,
        )
        return DangerSoundResult(
            detected=is_periodic,
            band_energy_ratio=ratio,
            cycle_count=len(recent),
            mean_period_seconds=avg_period if is_periodic else None,
        )

    def reset(self) -> None:
        """Clear onset history — call after a confirmed alert is handled."""
        self._onset_timestamps.clear()
        self._was_above_threshold = False

    def _drop_stale_onsets(self, now: float) -> None:
        cutoff = now - self._cfg.window_seconds
        self._onset_timestamps = [t for t in self._onset_timestamps if t >= cutoff]
