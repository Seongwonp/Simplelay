"""위험소리(화재/가스 경보음) 상시 감지기 단위 테스트.

AudioSensor(단발 프레임 판정)와 달리 DangerSoundDetector는 여러 프레임에
걸친 "주기적 반복"을 본다 — 모든 테스트는 하드웨어 없이 합성 톤/무음
프레임과 수동으로 지정한 timestamp로 진행한다.
"""

import numpy as np
import pytest

from rpi.verifier.audio_sensor import FakeAudioReader
from rpi.verifier.config import DangerSoundConfig
from rpi.verifier.danger_sound import DangerSoundDetector, _periodicity_score

_CHUNK = 512
_RATE = 16_000
_ALARM_TONE_HZ = 3500.0  # DangerSoundConfig 기본 대역(2800-4200Hz) 안


# ═══════════════════════════════════════════════════════════════════════════════
# 1. DangerSoundConfig
# ═══════════════════════════════════════════════════════════════════════════════

class TestDangerSoundConfig:
    def test_defaults_are_valid(self):
        cfg = DangerSoundConfig()
        assert cfg.freq_low_hz == 2_800
        assert cfg.freq_high_hz == 4_200
        assert cfg.min_cycles == 6
        assert cfg.min_period_seconds == 0.3
        assert cfg.max_period_seconds == 2.5

    def test_rejects_inverted_period_range(self):
        with pytest.raises(ValueError, match="min_period_seconds"):
            DangerSoundConfig(min_period_seconds=2.0, max_period_seconds=1.0)

    def test_rejects_non_positive_min_period(self):
        with pytest.raises(ValueError, match="min_period_seconds"):
            DangerSoundConfig(min_period_seconds=0.0, max_period_seconds=1.0)

    def test_rejects_min_cycles_below_two(self):
        with pytest.raises(ValueError, match="min_cycles"):
            DangerSoundConfig(min_cycles=1)


# ═══════════════════════════════════════════════════════════════════════════════
# 2. _periodicity_score (순수 함수)
# ═══════════════════════════════════════════════════════════════════════════════

class TestPeriodicityScore:
    def test_empty_intervals_not_periodic(self):
        is_periodic, avg = _periodicity_score([], 0.3, 2.5)
        assert is_periodic is False
        assert avg == 0.0

    def test_steady_intervals_are_periodic(self):
        is_periodic, avg = _periodicity_score([0.4, 0.4, 0.4, 0.4], 0.1, 1.0)
        assert is_periodic is True
        assert avg == pytest.approx(0.4)

    def test_single_interval_within_range_is_periodic(self):
        is_periodic, avg = _periodicity_score([0.5], 0.3, 2.5)
        assert is_periodic is True
        assert avg == pytest.approx(0.5)

    def test_interval_outside_range_rejected(self):
        # 5.0초는 max_period_seconds(2.5초) 밖 — 너무 느린 반복은 경보로 안 봄
        is_periodic, _ = _periodicity_score([1.0, 5.0, 1.0], 0.3, 2.5)
        assert is_periodic is False

    def test_interval_too_fast_rejected(self):
        is_periodic, _ = _periodicity_score([0.05, 0.05], 0.3, 2.5)
        assert is_periodic is False

    def test_irregular_intervals_rejected(self):
        # 평균 안엔 들지만 편차가 커서 "일정한 반복"이 아님
        is_periodic, _ = _periodicity_score([0.3, 1.2, 0.4, 1.3], 0.1, 2.5)
        assert is_periodic is False

    def test_mild_jitter_still_periodic(self):
        # 실제 하드웨어는 완벽히 일정하지 않다 — 약간의 흔들림은 허용
        is_periodic, avg = _periodicity_score([0.40, 0.42, 0.39, 0.41], 0.1, 1.0)
        assert is_periodic is True
        assert avg == pytest.approx(0.405, abs=0.01)


# ═══════════════════════════════════════════════════════════════════════════════
# 3. DangerSoundDetector — 빠른 테스트용 커스텀 설정 (실제 하드웨어 대역과
#    무관하게 min_cycles/기간을 작게 잡아 시나리오를 짧게 구성)
# ═══════════════════════════════════════════════════════════════════════════════

def _fast_config(**overrides) -> DangerSoundConfig:
    params = {
        "min_cycles": 3,
        "min_period_seconds": 0.1,
        "max_period_seconds": 1.0,
        "window_seconds": 10.0,
        **overrides,
    }
    return DangerSoundConfig(**params)


def _tone_frame() -> np.ndarray:
    return FakeAudioReader.tone(_ALARM_TONE_HZ, _CHUNK, _RATE)


def _silence_frame() -> np.ndarray:
    return FakeAudioReader.silence(_CHUNK)


class TestDangerSoundDetector:
    def test_silence_never_detected(self):
        detector = DangerSoundDetector(_fast_config())
        result = None
        for t in np.arange(0.0, 5.0, 0.1):
            result = detector.process_frame(_silence_frame(), float(t))
        assert result.detected is False
        assert result.cycle_count == 0

    def test_steady_periodic_pulses_are_detected(self):
        # 0.4초 간격으로 짧게 울리는 톤 — 경보 부저의 전형적 패턴
        detector = DangerSoundDetector(_fast_config())
        pulse_times = [0.0, 0.4, 0.8, 1.2]
        result = None
        for t in pulse_times:
            result = detector.process_frame(_tone_frame(), t)
            result = detector.process_frame(_silence_frame(), t + 0.1)
        assert result.detected is True
        assert result.cycle_count == 3
        assert result.mean_period_seconds == pytest.approx(0.4, abs=1e-6)

    def test_single_pulse_not_enough_cycles(self):
        detector = DangerSoundDetector(_fast_config())
        result = detector.process_frame(_tone_frame(), 0.0)
        assert result.detected is False
        assert result.cycle_count == 1

    def test_finite_chime_stops_before_min_cycles_reached(self):
        # 전자레인지 완료음처럼 2번만 울리고 멈추는 경우 — 절대 detected 안 됨
        detector = DangerSoundDetector(_fast_config(min_cycles=6))
        result = None
        for t in [0.0, 0.4]:
            result = detector.process_frame(_tone_frame(), t)
            result = detector.process_frame(_silence_frame(), t + 0.1)
        # 이후 오래 무음이 이어져도 새 온셋이 없으니 계속 미검출
        for t in np.arange(2.0, 10.0, 0.5):
            result = detector.process_frame(_silence_frame(), float(t))
        assert result.detected is False

    def test_irregular_pulses_not_detected(self):
        detector = DangerSoundDetector(_fast_config())
        pulse_times = [0.0, 0.9, 1.0, 2.5]  # 간격이 들쭉날쭉
        result = None
        for t in pulse_times:
            result = detector.process_frame(_tone_frame(), t)
            result = detector.process_frame(_silence_frame(), t + 0.05)
        assert result.detected is False

    def test_sustained_tone_without_gaps_yields_single_onset(self):
        # 온셋은 "상승 엣지"이므로 끊김 없는 연속 톤은 온셋 1개뿐 — 반복으로 안 잡힘
        detector = DangerSoundDetector(_fast_config())
        result = None
        for t in np.arange(0.0, 3.0, 0.1):
            result = detector.process_frame(_tone_frame(), float(t))
        assert result.cycle_count == 1
        assert result.detected is False

    def test_stale_onsets_are_dropped_outside_window(self):
        detector = DangerSoundDetector(_fast_config(window_seconds=1.0))
        # 윈도우(1.0초) 밖으로 밀려날 오래된 온셋들
        for t in [0.0, 0.3, 0.6]:
            detector.process_frame(_tone_frame(), t)
            detector.process_frame(_silence_frame(), t + 0.05)
        # 한참 뒤 새 온셋 하나만 추가 — 오래된 것들은 윈도우에서 밀려나야 함
        result = detector.process_frame(_tone_frame(), 5.0)
        assert result.cycle_count == 1

    def test_reset_clears_history(self):
        detector = DangerSoundDetector(_fast_config())
        for t in [0.0, 0.4, 0.8]:
            detector.process_frame(_tone_frame(), t)
            detector.process_frame(_silence_frame(), t + 0.05)
        detector.reset()
        result = detector.process_frame(_tone_frame(), 100.0)
        assert result.cycle_count == 1
        assert result.detected is False

    def test_band_energy_ratio_reported_even_when_not_detected(self):
        detector = DangerSoundDetector(_fast_config())
        result = detector.process_frame(_tone_frame(), 0.0)
        assert result.band_energy_ratio > 0.35

    def test_default_config_alarm_band_tone_triggers_onset(self):
        # 실제 기본 설정값(2800-4200Hz)으로도 온셋이 잡히는지 확인
        detector = DangerSoundDetector(DangerSoundConfig())
        result = detector.process_frame(_tone_frame(), 0.0)
        assert result.band_energy_ratio > DangerSoundConfig().band_energy_threshold
        assert result.cycle_count == 1

    def test_out_of_band_tone_never_triggers(self):
        detector = DangerSoundDetector(_fast_config())
        low_tone = FakeAudioReader.tone(500.0, _CHUNK, _RATE)  # 대역(2800-4200Hz) 밖
        result = None
        for t in [0.0, 0.4, 0.8, 1.2]:
            result = detector.process_frame(low_tone, t)
        assert result.cycle_count == 0
        assert result.detected is False
