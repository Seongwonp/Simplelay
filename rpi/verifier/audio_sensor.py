"""Microphone-based button-sound detector using FFT band-energy ratio.

On real hardware: pip install sounddevice numpy
In tests: inject an AudioReader that returns canned PCM frames.
"""

from __future__ import annotations

import threading
import time
from abc import ABC, abstractmethod
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from .base import SensorUnavailable
from .config import AudioSensorConfig


@dataclass(frozen=True)
class StampedFrame:
    """시각(monotonic 초, 콜백이 받은 때)이 붙은 PCM 프레임."""

    t: float
    pcm: np.ndarray


class AudioReader(ABC):
    """Hardware boundary — returns one PCM frame as a float32 numpy array."""

    #: True면 ``drain()``이 콜백 시각이 찍힌 프레임을 돌려준다(오래된 프레임을 가를 수 있다).
    #: False인 대역(옛 시험 대역)은 판정 때 프레임 하나를 '지금' 것으로 읽는다.
    stamped: bool = False

    @abstractmethod
    def read_frame(self) -> np.ndarray:
        """Return one chunk of mono audio, normalised to [-1.0, 1.0]."""

    def drain(self) -> list[StampedFrame]:
        """쌓인 프레임을 모두 꺼낸다(오래된 것부터). 읽을 수 없으면 `SensorUnavailable`."""
        return [StampedFrame(time.monotonic(), self.read_frame())]

    def close(self) -> None:
        """Release hardware resources (optional)."""


class SounddeviceReader(AudioReader):
    """Real microphone reader using sounddevice callback mode.

    콜백이 프레임마다 monotonic 시각을 찍어 길이 ``queue_frames``의 큐에 넣는다. 큐가
    차면 **가장 오래된 프레임을 버리고 최신을 남긴다**(2026-10-07 — 옛 구현은 새 프레임을
    버려 누름 때 소리 대신 오래된 소리가 남았다).

    ``drain()``은 스트림이 멈췄으면(장치 제거 등) `SensorUnavailable`을 낸다 — 무음과 다르다.
    ``read_frame()``은 위험 소리 감시 루프가 쓰는 옛 동기 읽기다(1초 안에 프레임이 없으면 0 프레임).
    Import only when hardware is present.
    """

    stamped = True

    def __init__(
        self,
        config: AudioSensorConfig,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        try:
            import sounddevice as sd  # type: ignore[import]
        except ImportError as exc:
            raise RuntimeError(
                "sounddevice is not installed. Run: pip install sounddevice"
            ) from exc

        self._clock = clock
        self._chunk = config.chunk_size
        self._frames: deque[StampedFrame] = deque(maxlen=config.queue_frames)
        self._ready = threading.Condition()
        self._closed = False
        #: 큐가 차서 버린 프레임 수(진단용).
        self.dropped = 0

        def _cb(indata: np.ndarray, frames: int, time_info: object, status: object) -> None:  # noqa: ARG001
            frame = StampedFrame(self._clock(), indata[:, 0].copy())
            with self._ready:
                if len(self._frames) == self._frames.maxlen:
                    self.dropped += 1
                self._frames.append(frame)  # 가득 차면 deque가 가장 오래된 것을 버린다
                self._ready.notify()

        self._stream = sd.InputStream(
            callback=_cb,
            blocksize=config.chunk_size,
            samplerate=config.sample_rate,
            channels=1,
            device=config.device_index,
        )
        self._stream.start()

    def read_frame(self) -> np.ndarray:
        with self._ready:
            if not self._frames:
                self._ready.wait(timeout=1.0)
            if self._frames:
                return self._frames.popleft().pcm
        return np.zeros(self._chunk, dtype=np.float32)

    def drain(self) -> list[StampedFrame]:
        if self._closed or not bool(getattr(self._stream, "active", False)):
            raise SensorUnavailable("microphone stream is not active (device removed or stopped)")
        with self._ready:
            frames = list(self._frames)
            self._frames.clear()
        return frames

    def close(self) -> None:
        self._closed = True
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

    # Test helpers

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


@dataclass(frozen=True)
class AudioWindowResult:
    """한 누름 관측 구간의 버튼음 판정."""

    pressed: bool
    peak_ratio: float
    frames: int
    above: int


class AudioSensor:
    """Detects button-press sounds via FFT band-energy ratio.

    누름 판정은 **관측 구간**으로 한다(2026-10-07, 인계 노트북-3 §A H2):
    ``open_window()``가 누르기 직전 시각을 잡고 큐에 쌓인(오래된) 프레임을 버린다.
    ``close_window()``는 누름 뒤 ``post_press_s``까지 기다려 구간 안 프레임만 판정한다.
    구간 안 프레임이 하나도 없으면(콜백이 멈춤) `SensorUnavailable` — 무음과 다르다.
    시각이 없는 대역(``stamped=False``)은 판정 때 프레임 하나를 읽는다(옛 동작).

    Args:
        reader:  Hardware or fake audio reader.
        config:  Calibration parameters from SensorConfig.audio.
    """

    def __init__(
        self,
        reader: AudioReader,
        config: AudioSensorConfig,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._reader = reader
        self._cfg = config
        self._clock = clock
        self._sleep = sleep
        self._opened_at: float | None = None

    # Public API

    def is_pressed(self) -> tuple[bool, float]:
        """Read one frame and return (sound_detected, band_energy_ratio).

        band_energy_ratio is always in [0.0, 1.0].
        """
        pcm = self._reader.read_frame()
        ratio = self._ratio(pcm)
        return ratio >= self._cfg.band_energy_threshold, ratio

    @property
    def window_open(self) -> bool:
        return self._opened_at is not None

    def open_window(self) -> None:
        """구간 시작 — 지금까지 쌓인 프레임은 누름 전 소리라 버린다."""
        if self._reader.stamped:
            self._reader.drain()
        self._opened_at = self._clock()

    def cancel_window(self) -> None:
        self._opened_at = None

    def close_window(self, press_ended_at: float | None = None) -> AudioWindowResult:
        if self._opened_at is None:
            raise RuntimeError("no open audio observation window")
        opened_at = self._opened_at
        self._opened_at = None
        if not self._reader.stamped:
            _, ratio = self.is_pressed()
            above = int(ratio >= self._cfg.band_energy_threshold)
            return AudioWindowResult(bool(above), ratio, 1, above)

        end = self._clock() if press_ended_at is None else press_ended_at
        until = end + self._cfg.post_press_s
        deadline = until + self._cfg.stall_timeout_s
        poll = min(self._cfg.chunk_size / self._cfg.sample_rate / 2, 0.01)
        frames: list[StampedFrame] = []
        while True:
            frames.extend(f for f in self._reader.drain() if f.t >= opened_at)
            if frames and frames[-1].t >= until:
                break
            now = self._clock()
            if now >= deadline or (frames and now >= until):
                break
            self._sleep(poll)
        in_window = [f for f in frames if opened_at <= f.t <= until]
        if not in_window:
            raise SensorUnavailable(
                "microphone delivered no frames during the press window (disconnected or stalled)"
            )
        ratios = [self._ratio(f.pcm) for f in in_window]
        above = sum(1 for r in ratios if r >= self._cfg.band_energy_threshold)
        return AudioWindowResult(
            pressed=above >= self._cfg.min_frames_above,
            peak_ratio=max(ratios),
            frames=len(in_window),
            above=above,
        )

    def close(self) -> None:
        self._reader.close()

    def _ratio(self, pcm: np.ndarray) -> float:
        return _band_energy_ratio(
            pcm,
            self._cfg.sample_rate,
            self._cfg.freq_low_hz,
            self._cfg.freq_high_hz,
        )
