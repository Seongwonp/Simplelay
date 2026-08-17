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


@dataclass(frozen=True)
class DangerSoundConfig:
    """마이크로 화재/가스 경보음 같은 위험 신호음을 상시 감지하기 위한 설정.

    AudioSensorConfig(버튼음, 단발 프레임 판정)와는 목적이 다르다 — 이건
    여러 프레임에 걸친 "주기적으로 반복되는 소리"를 찾는다. 주파수 대역은
    실측 전 추정값(일반적인 피에조 경보기 대역) — docs/sensor-spec.md가
    버튼음에 요구했던 것과 동일한 실측 절차가 결선 전 필요.
    """

    sample_rate: int = 16_000
    chunk_size: int = 512

    # 경보음 피에조 부저 대역 추정치 (Hz) — 실측 필요
    freq_low_hz: int = 2_800
    freq_high_hz: int = 4_200

    # 대역 에너지 비율 임계값 (0.0–1.0)
    band_energy_threshold: float = 0.35

    # 경보로 판정하기 위한 최소 반복 주기(온셋 간 간격, 초) 범위 —
    # 이 범위 밖 간격은 경보 후보에서 제외
    min_period_seconds: float = 0.3
    max_period_seconds: float = 2.5

    # 오탐(전자레인지 완료음 등 유한 반복) 방지 — 이 횟수 이상 연속으로
    # 일정한 주기를 유지해야 위험으로 판정. 완료음은 보통 3~5회 후 멈춘다.
    min_cycles: int = 6

    # 온셋 기록을 보관하는 분석 윈도우 길이(초) — 이보다 오래된 온셋은 버림
    window_seconds: float = 30.0

    def __post_init__(self) -> None:
        if self.min_period_seconds <= 0 or self.max_period_seconds <= self.min_period_seconds:
            raise ValueError("min_period_seconds must be positive and less than max_period_seconds")
        if self.min_cycles < 2:
            raise ValueError("min_cycles must be at least 2 to establish a period")
