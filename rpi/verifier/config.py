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

    # ── 누름 관측 구간(2026-10-07) — 아래 값은 전부 추측, 실측 필요 ──
    # 누르는 동안 ADC를 읽는 간격(초). ADS1115 860 SPS면 한 번 읽기에 약 1.2 ms.
    sample_interval_s: float = 0.002
    # 누름 명령이 끝난 뒤에도 더 읽는 시간(초) — 가전 반응 지연을 덮는다.
    post_press_s: float = 0.05
    # 기준선 대비 임계값을 넘은 표본이 이만큼 있어야 누름으로 본다(단발 잡음 거르기).
    min_samples_above: int = 2
    # 한 관측 구간의 상한(초). 넘으면 센서 이상으로 본다(닫히지 않은 창 방지).
    max_window_s: float = 30.0
    # 이 범위 밖 전압은 단절로 본다(None이면 검사 안 함). 분압 회로 확인 전이라 기본 꺼짐.
    valid_voltage_range: tuple[float, float] | None = None

    def __post_init__(self) -> None:
        if self.window_size < 1:
            raise ValueError("window_size must be at least 1")
        if self.min_samples_above < 1:
            raise ValueError("min_samples_above must be at least 1")
        if self.sample_interval_s <= 0 or self.max_window_s <= 0 or self.post_press_s < 0:
            raise ValueError(
                "sample_interval_s/max_window_s must be positive, post_press_s non-negative"
            )


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

    # ── 누름 관측 구간(2026-10-07) — 아래 값은 전부 추측, 실측 필요 ──
    # 콜백 큐 길이(프레임). 차면 가장 오래된 프레임을 버리고 최신을 남긴다.
    # 512 샘플/16 kHz 기준 128프레임 ≈ 4 s.
    queue_frames: int = 128
    # 누름 명령이 끝난 뒤에도 기다리는 시간(초) — 입력 지연·버튼음 꼬리를 덮는다.
    post_press_s: float = 0.15
    # 이만큼 더 기다려도 구간 안 프레임이 없으면 마이크 단절로 본다(초).
    stall_timeout_s: float = 0.5
    # 구간 안에서 임계값을 넘은 프레임이 이만큼 있어야 버튼음으로 본다.
    min_frames_above: int = 1

    def __post_init__(self) -> None:
        if self.queue_frames < 1 or self.min_frames_above < 1:
            raise ValueError("queue_frames and min_frames_above must be at least 1")
        if self.post_press_s < 0 or self.stall_timeout_s <= 0:
            raise ValueError("post_press_s must be non-negative and stall_timeout_s positive")


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
