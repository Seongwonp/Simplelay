"""Sensor calibration parameters — always injected, never hardcoded.

All thresholds here are starting estimates from docs/sensor-spec.md.
Replace with real measurements after M1 hardware is connected.
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class CurrentSensorConfig:
    """ACS712-05B + ADS1115 calibration."""

    # ACS712-05B sensitivity: 185 mV/A
    sensitivity_mv_per_a: float = 185.0

    # Voltage at zero current (VCC/2 = 2.5 V for 5 V supply)
    zero_current_voltage: float = 2.5

    # ADS1115 gain setting (2 → ±2.048 V range)
    ads_gain: int = 2

    # ADS1115 data rate (samples per second)
    ads_data_rate: int = 860

    # Moving-average window size (samples)
    window_size: int = 20

    # Current delta above baseline to confirm a press (amperes)
    press_threshold_a: float = 0.012

    # ADC channel index (0–3 for ADS1115)
    channel: int = 0


@dataclass(frozen=True)
class AudioSensorConfig:
    """Microphone + FFT configuration."""

    # Audio capture settings
    sample_rate: int = 16_000
    chunk_size: int = 512

    # FFT band for button-press sound (Hz)
    freq_low_hz: int = 800
    freq_high_hz: int = 3_000

    # Band energy ratio threshold (0.0–1.0)
    band_energy_threshold: float = 0.35

    # Device index for PyAudio (None = system default)
    device_index: int | None = None


@dataclass(frozen=True)
class FusionConfig:
    """Weights and threshold for combining current + audio evidence."""

    # Minimum weighted confidence to declare a press
    confidence_threshold: float = 0.50

    # Weight for current sensor (0.0–1.0)
    current_weight: float = 0.55

    # Weight for audio sensor (0.0–1.0; current + audio must sum ≤ 1.0)
    audio_weight: float = 0.45

    def __post_init__(self) -> None:
        if not 0.0 < self.confidence_threshold <= 1.0:
            raise ValueError("confidence_threshold must be in (0, 1]")
        if not abs(self.current_weight + self.audio_weight - 1.0) < 1e-9:
            raise ValueError("current_weight + audio_weight must equal 1.0")


@dataclass(frozen=True)
class SensorConfig:
    """Top-level sensor configuration passed to SensorVerifier."""

    current: CurrentSensorConfig = field(default_factory=CurrentSensorConfig)
    audio: AudioSensorConfig = field(default_factory=AudioSensorConfig)
    fusion: FusionConfig = field(default_factory=FusionConfig)
