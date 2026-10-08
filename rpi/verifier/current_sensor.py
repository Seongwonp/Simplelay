"""ACS712 current sensor via ADS1115 (I2C ADC).

On real hardware: pip install adafruit-circuitpython-ads1x15 adafruit-blinka
In tests: inject a CurrentReader that returns canned voltages.
"""

from __future__ import annotations

import math
import threading
import time
from abc import ABC, abstractmethod
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass

from .base import SensorUnavailable
from .config import CurrentSensorConfig


class CurrentReader(ABC):
    """Hardware boundary — reads a single voltage sample from the ADC."""

    @abstractmethod
    def read_voltage(self) -> float:
        """Return the current ADC channel voltage in volts."""


class Ads1115Reader(CurrentReader):
    """Real ADS1115 reader. Import only when hardware is present."""

    def __init__(self, config: CurrentSensorConfig) -> None:
        # Deferred import so the module loads on dev machines without RPi libs.
        try:
            import board  # type: ignore[import]
            import busio  # type: ignore[import]
            import adafruit_ads1x15.ads1115 as ADS  # type: ignore[import]
            from adafruit_ads1x15.analog_in import AnalogIn  # type: ignore[import]
        except ImportError as exc:
            raise RuntimeError(
                "adafruit-circuitpython-ads1x15 is not installed. "
                "Run: pip install adafruit-circuitpython-ads1x15 adafruit-blinka"
            ) from exc

        i2c = busio.I2C(board.SCL, board.SDA)
        ads = ADS.ADS1115(i2c, data_rate=config.ads_data_rate)
        ads.gain = config.ads_gain
        channel_map = [ADS.P0, ADS.P1, ADS.P2, ADS.P3]
        self._chan = AnalogIn(ads, channel_map[config.channel])

    def read_voltage(self) -> float:
        return float(self._chan.voltage)


class FakeCurrentReader(CurrentReader):
    """Test double — returns injected voltage samples in order."""

    def __init__(self, voltages: list[float]) -> None:
        self._voltages = list(voltages)
        self._index = 0

    def read_voltage(self) -> float:
        if self._index >= len(self._voltages):
            return self._voltages[-1]  # hold last value
        v = self._voltages[self._index]
        self._index += 1
        return v


@dataclass(frozen=True)
class CurrentSample:
    """시각(monotonic 초)이 붙은 전류 표본."""

    t: float
    amps: float


@dataclass(frozen=True)
class CurrentWindowResult:
    """한 누름 관측 구간의 전류 판정."""

    pressed: bool
    peak_delta_a: float
    baseline_a: float
    samples: int
    above: int


class CurrentSensor:
    """ACS712 press detector.

    누름 판정은 **관측 구간**으로 한다(2026-10-07, 인계 노트북-3 §A H1):

    1. ``open_window()`` — 누르기 직전에 ``window_size``개를 읽어 기준선을 만든다.
       생성 직후 첫 누름도 기준선이 차 있다(옛 이동평균은 창이 찰 때까지 늘 False였다).
    2. 누르는 동안 배경 스레드가 ``sample_interval_s``마다 읽어 시각과 함께 쌓는다.
    3. ``close_window()`` — 누름이 끝난 뒤 ``post_press_s``만큼 더 읽고 닫는다. 구간 안
       표본 중 기준선보다 ``press_threshold_a``를 넘은 것이 ``min_samples_above``개 이상이면 누름.

    읽기 예외·비유한 값·``valid_voltage_range`` 밖 전압은 `SensorUnavailable`이다 —
    전류 0(정상적인 '반응 없음')과 구분한다. 임계값·간격은 전부 추측, 실측 필요.

    ``is_pressed``·``prime``은 옛 이동평균 경로(단위 시험용)로 남긴다.

    Args:
        reader:  Hardware or fake ADC reader.
        config:  Calibration parameters from SensorConfig.current.
        clock:   monotonic clock(초) — 표본 시각.
        sleep:   누름 뒤 대기(시험에서 바꿔 끼울 수 있다).
    """

    def __init__(
        self,
        reader: CurrentReader,
        config: CurrentSensorConfig,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._reader = reader
        self._cfg = config
        self._clock = clock
        self._sleep = sleep
        self._window: deque[float] = deque(maxlen=config.window_size)
        # 관측 구간 상태
        self._lock = threading.Lock()
        self._samples: list[CurrentSample] = []
        self._fault: SensorUnavailable | None = None
        self._halt = threading.Event()
        self._generation = 0
        self._thread: threading.Thread | None = None
        self._baseline_a = 0.0
        self._opened_at = 0.0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def read_current_a(self) -> float:
        """Return the instantaneous current in amperes."""
        v = self._reader.read_voltage()
        return self._voltage_to_current(v)

    def read_sample(self) -> CurrentSample:
        """한 번 읽어 시각을 붙인다. 읽을 수 없으면 `SensorUnavailable`."""
        try:
            v = float(self._reader.read_voltage())
        except SensorUnavailable:
            raise
        except Exception as exc:  # noqa: BLE001 - I2C·드라이버 오류는 종류와 무관하게 단절
            raise SensorUnavailable(f"current sensor read failed: {exc}") from exc
        if not math.isfinite(v):
            raise SensorUnavailable(f"current sensor returned a non-finite voltage ({v})")
        valid = self._cfg.valid_voltage_range
        if valid is not None and not valid[0] <= v <= valid[1]:
            raise SensorUnavailable(
                f"current sensor voltage {v:.3f} V outside {valid[0]}..{valid[1]} V (disconnected?)"
            )
        return CurrentSample(self._clock(), self._voltage_to_current(v))

    @property
    def window_open(self) -> bool:
        return self._thread is not None

    def open_window(self) -> None:
        """누르기 직전 기준선을 잡고 연속 수집을 시작한다. 열린 창이 있으면 버린다."""
        self.cancel_window()
        baseline = [self.read_sample() for _ in range(self._cfg.window_size)]
        self._baseline_a = sum(s.amps for s in baseline) / len(baseline)
        with self._lock:
            self._samples = []
            self._fault = None
        self._opened_at = self._clock()
        # 종료된 세대의 신호는 절대 clear하지 않는다. 막힌 ADC 읽기는 강제 종료할 수
        # 없지만, 돌아온 뒤에는 세대 검사로 표본·오류를 버리고 종료한다.
        self._halt = threading.Event()
        self._thread = threading.Thread(
            target=self._collect,
            args=(self._generation, self._halt, self._opened_at),
            name="current-window", daemon=True
        )
        self._thread.start()

    def close_window(self, press_ended_at: float | None = None) -> CurrentWindowResult:
        """누름 뒤 ``post_press_s``까지 더 읽고 닫아 판정한다."""
        if self._thread is None:
            raise RuntimeError("no open current observation window")
        end = self._clock() if press_ended_at is None else press_ended_at
        remaining = end + self._cfg.post_press_s - self._clock()
        if remaining > 0:
            self._sleep(remaining)
        closed_at = self._clock()
        self._stop_thread()
        with self._lock:
            fault = self._fault
            samples = [s for s in self._samples if s.t >= self._opened_at]
        if fault is not None:
            raise fault
        if not samples:
            raise SensorUnavailable("current sensor produced no samples during the press window")
        if len(samples) < self._cfg.min_window_samples:
            raise SensorUnavailable("current observation has insufficient samples")
        if closed_at - samples[-1].t > self._cfg.max_sample_age_s:
            raise SensorUnavailable("current observation last sample is stale")
        times = [self._opened_at, *(s.t for s in samples), closed_at]
        if any(b - a > self._cfg.max_sample_gap_s for a, b in zip(times, times[1:])):
            raise SensorUnavailable("current observation has an uncovered interval")
        deltas = [s.amps - self._baseline_a for s in samples]
        above = sum(1 for d in deltas if d > self._cfg.press_threshold_a)
        return CurrentWindowResult(
            pressed=above >= self._cfg.min_samples_above,
            peak_delta_a=max(max(deltas), 0.0),
            baseline_a=self._baseline_a,
            samples=len(samples),
            above=above,
        )

    def cancel_window(self) -> None:
        """판정 없이 창을 닫는다(누름 실패·중단)."""
        if self._thread is not None:
            self._stop_thread()

    def is_pressed(self) -> tuple[bool, float]:
        """Sample one reading and return (pressed, delta_a).

        옛 이동평균 경로 — 창이 찰 때까지 (False, 0.0)이다. 폐루프 판정은
        ``open_window``/``close_window``를 쓴다(`SensorVerifier`).
        """
        current_a = self.read_current_a()
        self._window.append(current_a)

        if len(self._window) < self._cfg.window_size:
            return False, 0.0

        baseline = sum(self._window) / len(self._window)
        delta = current_a - baseline
        return delta > self._cfg.press_threshold_a, max(delta, 0.0)

    def prime(self, samples: int | None = None) -> None:
        """Fill the moving-average window (blocking, for hardware startup)."""
        n = samples or self._cfg.window_size
        for _ in range(n):
            self._window.append(self.read_current_a())

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _collect(self, generation: int, halt: threading.Event, opened_at: float) -> None:
        deadline = opened_at + self._cfg.max_window_s
        while not halt.is_set():
            try:
                sample = self.read_sample()
            except SensorUnavailable as exc:
                with self._lock:
                    if generation == self._generation and not halt.is_set():
                        self._fault = exc
                return
            with self._lock:
                if generation != self._generation or halt.is_set():
                    return
                self._samples.append(sample)
                if sample.t > deadline:
                    self._fault = SensorUnavailable(
                        f"current observation window exceeded {self._cfg.max_window_s} s"
                    )
                    return
            halt.wait(self._cfg.sample_interval_s)

    def _stop_thread(self) -> None:
        thread = self._thread
        self._thread = None
        with self._lock:
            self._halt.set()
            self._generation += 1
        if thread is not None:
            thread.join(timeout=self._cfg.thread_join_timeout_s)
            if thread.is_alive():
                with self._lock:
                    self._fault = SensorUnavailable("current reader still alive after join timeout")

    def _voltage_to_current(self, voltage: float) -> float:
        sensitivity_v = self._cfg.sensitivity_mv_per_a / 1000.0
        return (voltage - self._cfg.zero_current_voltage) / sensitivity_v
