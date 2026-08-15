"""Microphone-based button-sound detector using FFT band-energy ratio.

On real hardware: pip install sounddevice numpy
In tests: inject an AudioReader that returns canned PCM frames.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

import numpy as np

from .config import AudioSensorConfig


class AudioReader(ABC):
    """Hardware boundary — returns one PCM frame as a float32 numpy array."""

    @abstractmethod
    def read_frame(self) -> np.ndarray:
        """Return one chunk of mono audio, normalised to [-1.0, 1.0]."""

    def close(self) -> None:
        """Release hardware resources (optional)."""


class SounddeviceReader(AudioReader):
    """Real microphone reader using sounddevice callback mode.

    Keeps a one-frame queue so callers can do synchronous reads.
    Import only when hardware is present.
    """

    def __init__(self, config: AudioSensorConfig) -> None:
        try:
            import queue as _queue
            import sounddevice as sd  # type: ignore[import]
        except ImportError as exc:
            raise RuntimeError(
                "sounddevice is not installed. Run: pip install sounddevice"
            ) from exc

        self._q: _queue.Queue[np.ndarray] = _queue.Queue(maxsize=4)

        def _cb(indata: np.ndarray, frames: int, time: object, status: object) -> None:  # noqa: ARG001
            if not self._q.full():
                self._q.put(indata[:, 0].copy())

        self._stream = sd.InputStream(
            callback=_cb,
            blocksize=config.chunk_size,
            samplerate=config.sample_rate,
            channels=1,
            device=config.device_index,
        )
        self._stream.start()

    def read_frame(self) -> np.ndarray:
        import queue as _queue

        try:
            return self._q.get(timeout=1.0)
        except _queue.Empty:
            return np.zeros(512, dtype=np.float32)

    def close(self) -> None:
        self._stream.stop()
        self._stream.close()


class FakeAudioReader(AudioReader):
    """Test double — returns pre-built PCM frames in order."""

    def __init__(self, frames: list[np.ndarray]) -> None:
        self._frames = list(frames)
        self._index = 0

    def read_frame(self) -> np.ndarray:
        if self._index >= len(self._frames):
            return self._frames[-1]
        frame = self._frames[self._index]
        self._index += 1
        return frame

    # ------------------------------------------------------------------
    # Test helpers
    # ------------------------------------------------------------------

    @staticmethod
    def silence(chunk_size: int = 512) -> np.ndarray:
        """Return a silent frame."""
        return np.zeros(chunk_size, dtype=np.float32)

    @staticmethod
    def tone(
        freq_hz: float,
        chunk_size: int = 512,
        sample_rate: int = 16_000,
        amplitude: float = 0.8,
    ) -> np.ndarray:
        """Return a single-frequency tone frame."""
        t = np.arange(chunk_size) / sample_rate
        return (amplitude * np.sin(2 * np.pi * freq_hz * t)).astype(np.float32)

    @staticmethod
    def noise(chunk_size: int = 512, amplitude: float = 0.05) -> np.ndarray:
        """Return white-noise frame simulating background ambient sound."""
        rng = np.random.default_rng(seed=42)
        return (rng.uniform(-amplitude, amplitude, chunk_size)).astype(np.float32)


def _band_energy_ratio(
    pcm: np.ndarray,
    sample_rate: int,
    f_low: int,
    f_high: int,
) -> float:
    """Return the fraction of FFT energy in [f_low, f_high] Hz."""
    windowed = pcm * np.hanning(len(pcm))
    fft_mag = np.abs(np.fft.rfft(windowed))
    freqs = np.fft.rfftfreq(len(pcm), 1.0 / sample_rate)
    mask = (freqs >= f_low) & (freqs <= f_high)
    total = fft_mag.sum()
    if total < 1e-12:
        return 0.0
    return float(fft_mag[mask].sum() / total)


class AudioSensor:
    """Detects button-press sounds via FFT band-energy ratio.

    Args:
        reader:  Hardware or fake audio reader.
        config:  Calibration parameters from SensorConfig.audio.
    """

    def __init__(self, reader: AudioReader, config: AudioSensorConfig) -> None:
        self._reader = reader
        self._cfg = config

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def is_pressed(self) -> tuple[bool, float]:
        """Read one frame and return (sound_detected, band_energy_ratio).

        band_energy_ratio is always in [0.0, 1.0].
        """
        pcm = self._reader.read_frame()
        ratio = _band_energy_ratio(
            pcm,
            self._cfg.sample_rate,
            self._cfg.freq_low_hz,
            self._cfg.freq_high_hz,
        )
        return ratio >= self._cfg.band_energy_threshold, ratio

    def close(self) -> None:
        self._reader.close()
