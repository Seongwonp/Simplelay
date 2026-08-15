"""ACS712 current sensor via ADS1115 (I2C ADC).

On real hardware: pip install adafruit-circuitpython-ads1x15 adafruit-blinka
In tests: inject a CurrentReader that returns canned voltages.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections import deque

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


class CurrentSensor:
    """Moving-average + delta detector for ACS712 press events.

    Args:
        reader:  Hardware or fake ADC reader.
        config:  Calibration parameters from SensorConfig.current.
    """

    def __init__(self, reader: CurrentReader, config: CurrentSensorConfig) -> None:
        self._reader = reader
        self._cfg = config
        self._window: deque[float] = deque(maxlen=config.window_size)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def read_current_a(self) -> float:
        """Return the instantaneous current in amperes."""
        v = self._reader.read_voltage()
        return self._voltage_to_current(v)

    def is_pressed(self) -> tuple[bool, float]:
        """Sample one reading and return (pressed, delta_a).

        The delta is the current above the rolling baseline.
        Returns (False, 0.0) until the window is fully primed.
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

    def _voltage_to_current(self, voltage: float) -> float:
        sensitivity_v = self._cfg.sensitivity_mv_per_a / 1000.0
        return (voltage - self._cfg.zero_current_voltage) / sensitivity_v
