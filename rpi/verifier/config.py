"""Sensor calibration parameters — always injected, never hardcoded.

All thresholds here are starting estimates from docs/sensor-spec.md.
Replace with real measurements after M1 hardware is connected.
"""

import math
import os
from collections.abc import Mapping
from dataclasses import dataclass, field, replace


@dataclass(frozen=True)
class CurrentSensorConfig:
    """ACS712-05B + ADS1115 calibration."""

    # ACS712-05B sensitivity: 185 mV/A
    sensitivity_mv_per_a: float = 185.0

    # Voltage at zero current (VCC/2 = 2.5 V for 5 V supply) — 실측 필요.
    # ADC 입력에서 본 값이다. 분압 회로가 있으면 그 뒤 전압을 준다(SIMPLELAY_CURRENT_ZERO_V).
    # 주의(2026-10-07, 평가 M2): 이 기본값은 아래 gain 2(±2.048 V)와 함께 쓸 수 없다 — 영점이 측정 범위
    # 밖이다. 실제 분압 회로는 팀원 확인 전이라 어느 쪽도 고치지 않고, 센서를 켤 때
    # `check_current_sensor_config`가 시작을 거절한다.
    zero_current_voltage: float = 2.5

    # ADS1115 gain setting (2 → ±2.048 V range) — 실측 필요(SIMPLELAY_CURRENT_ADC_GAIN)
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
    # L1 전류 창이다(L3 전력의 시작 제한시간과 별개). 모션 어댑터에서는 자동 원점·
    # XY 이동 뒤 Z 직전에 열므로 home_timeout_s/move_timeout_s는 이 30초를 쓰지 않는다.
    # Z 누름·냉각 대기·post_press_s는 포함된다. press_timeout_s와 함께 실측해 정해야 하며
    # 누름이 더 오래 걸리면 센서 이상으로 중단한다. 임계값·시간은 실측 필요.
    max_window_s: float = 30.0
    # 수집 완전성 한계는 추측값이며 ADC 속도·스케줄링 지연 실측 필요.
    max_sample_age_s: float = 0.25
    max_sample_gap_s: float = 0.25
    min_window_samples: int = 3
    thread_join_timeout_s: float = 2.0
    # 이 범위 밖 전압은 단절로 본다(None이면 검사 안 함). 분압 회로 확인 전이라 기본 꺼짐.
    valid_voltage_range: tuple[float, float] | None = None

    def __post_init__(self) -> None:
        for name in ("max_sample_age_s", "max_sample_gap_s", "thread_join_timeout_s"):
            value = getattr(self, name)
            if not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be finite and positive")
        if self.min_window_samples < 1:
            raise ValueError("min_window_samples must be at least 1")
        if self.window_size < 1:
            raise ValueError("window_size must be at least 1")
        if self.min_samples_above < 1:
            raise ValueError("min_samples_above must be at least 1")
        if self.sample_interval_s <= 0 or self.max_window_s <= 0 or self.post_press_s < 0:
            raise ValueError(
                "sample_interval_s/max_window_s must be positive, post_press_s non-negative"
            )


#: ADS1115 gain → 측정 범위(±V). 단일 입력(AINx–GND)은 0~이 값까지 읽는다.
ADS1115_FULL_SCALE_V: dict[float, float] = {2 / 3: 6.144, 1: 4.096, 2: 2.048, 4: 1.024, 8: 0.512, 16: 0.256}

#: 전류 센서 설정 환경 변수(센서를 켤 때만 읽는다). 값은 전부 실측 필요.
CURRENT_ZERO_V_ENV = "SIMPLELAY_CURRENT_ZERO_V"
CURRENT_ADC_GAIN_ENV = "SIMPLELAY_CURRENT_ADC_GAIN"


class SensorConfigError(ValueError):
    """센서 설정이 물리적으로 맞지 않는다 — 기동 전에 거절한다(메시지는 사람이 읽는 한국어)."""


def _full_scale(gain: float) -> float | None:
    for key, volts in ADS1115_FULL_SCALE_V.items():
        if math.isclose(float(gain), key, rel_tol=0, abs_tol=1e-9):
            return volts
    return None


def current_sensor_config_problems(cfg: CurrentSensorConfig) -> list[str]:
    """전류 센서 설정의 모순(없으면 빈 목록). 실측 전 기본값의 조합 오류를 잡는 검사이지 보정이 아니다."""
    problems: list[str] = []
    fs = _full_scale(cfg.ads_gain)
    if fs is None:
        problems.append(f"ADS1115 gain {cfg.ads_gain}은 없는 값이에요(2/3·1·2·4·8·16 중 하나)")
    if not 0 <= cfg.channel <= 3:
        problems.append(f"ADS1115 채널 {cfg.channel}은 없는 값이에요(0~3)")
    if not (math.isfinite(cfg.sensitivity_mv_per_a) and cfg.sensitivity_mv_per_a > 0):
        problems.append(f"전류 센서 감도 {cfg.sensitivity_mv_per_a} mV/A는 0보다 커야 해요")
    zero = cfg.zero_current_voltage
    if fs is not None:
        if not (math.isfinite(zero) and 0 < zero < fs):
            problems.append(
                f"영전류 전압 {zero} V가 ADS1115 gain {cfg.ads_gain}의 측정 범위(0~{fs} V) 밖이에요 — "
                "전류가 0일 때도 ADC가 끝값에 붙어 누름 전류를 읽을 수 없어요")
        else:
            swing = cfg.press_threshold_a * cfg.sensitivity_mv_per_a / 1000.0
            if zero + swing >= fs:
                problems.append(
                    f"영전류 전압 {zero} V에 누름 임계 전류({cfg.press_threshold_a} A)만큼 더하면 "
                    f"측정 범위(0~{fs} V)를 넘어요")
        rng = cfg.valid_voltage_range
        if rng is not None:
            lo, hi = rng
            if not (0 <= lo < hi <= fs) or not lo < zero < hi:
                problems.append(
                    f"정상 전압 범위 {lo}~{hi} V는 측정 범위(0~{fs} V) 안에 있고 영전류 전압 {zero} V를 "
                    "품어야 해요")
    return problems


def check_current_sensor_config(cfg: CurrentSensorConfig) -> None:
    """모순이 있으면 `SensorConfigError`(시작 거절). 센서를 켤 때만 부른다 — 기본 mock 기동은 검사하지 않는다."""
    problems = current_sensor_config_problems(cfg)
    if problems:
        raise SensorConfigError(
            "전류 센서 설정이 맞지 않아 센서 검증을 시작하지 않아요: " + "; ".join(problems)
            + f". 분압 회로·ADC gain을 팀원과 확인해 {CURRENT_ZERO_V_ENV}·{CURRENT_ADC_GAIN_ENV}로 맞춰 "
            "주세요(값은 실측 필요)")


def current_sensor_config_from_env(env: Mapping[str, str] | None = None,
                                   base: "CurrentSensorConfig | None" = None) -> CurrentSensorConfig:
    """``SIMPLELAY_CURRENT_ZERO_V``·``SIMPLELAY_CURRENT_ADC_GAIN``로 기본값을 덮는다(없으면 그대로)."""
    src = os.environ if env is None else env
    cfg = base or CurrentSensorConfig()
    changes: dict = {}
    for name, key in ((CURRENT_ZERO_V_ENV, "zero_current_voltage"), (CURRENT_ADC_GAIN_ENV, "ads_gain")):
        raw = (src.get(name) or "").strip()
        if not raw:
            continue
        try:
            value = float(raw)
        except ValueError as exc:
            raise SensorConfigError(f"{name} 값을 숫자로 읽을 수 없어요: {raw!r}") from exc
        if key == "ads_gain" and value.is_integer():
            value = int(value)
        changes[key] = value
    return replace(cfg, **changes) if changes else cfg


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
