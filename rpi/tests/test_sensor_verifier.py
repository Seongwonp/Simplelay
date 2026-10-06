"""M1 센서 모듈 단위 테스트.

모든 테스트는 하드웨어 없이 FakeCurrentReader / FakeAudioReader를 사용한다.
"""

import numpy as np
import pytest

from rpi.verifier.audio_sensor import AudioSensor, FakeAudioReader, _band_energy_ratio
from rpi.verifier.config import (
    AudioSensorConfig,
    CurrentSensorConfig,
    FusionConfig,
    SensorConfig,
)
from rpi.verifier.current_sensor import CurrentSensor, FakeCurrentReader
from rpi.verifier.fusion import fuse
from rpi.verifier.sensors import SensorVerifier

# ── 공통 상수 ────────────────────────────────────────────────────────────────

_ZERO_V = 2.5          # ACS712-05B 무전류 기준 전압
_SENSITIVITY = 0.185   # V/A
_CHUNK = 512
_RATE = 16_000


# ═══════════════════════════════════════════════════════════════════════════════
# 1. CurrentSensorConfig / AudioSensorConfig / FusionConfig
# ═══════════════════════════════════════════════════════════════════════════════

class TestCurrentSensorConfig:
    def test_defaults_are_valid(self):
        cfg = CurrentSensorConfig()
        assert cfg.sensitivity_mv_per_a == 185.0
        assert cfg.zero_current_voltage == 2.5
        assert cfg.window_size == 20
        assert cfg.press_threshold_a == 0.012

    def test_custom_values_accepted(self):
        cfg = CurrentSensorConfig(press_threshold_a=0.020, window_size=10)
        assert cfg.press_threshold_a == 0.020
        assert cfg.window_size == 10


class TestAudioSensorConfig:
    def test_defaults_are_valid(self):
        cfg = AudioSensorConfig()
        assert cfg.sample_rate == 16_000
        assert cfg.chunk_size == 512
        assert cfg.freq_low_hz == 800
        assert cfg.freq_high_hz == 3_000
        assert cfg.band_energy_threshold == 0.35


class TestFusionConfig:
    def test_weights_must_sum_to_one(self):
        with pytest.raises(ValueError, match="must equal 1.0"):
            FusionConfig(current_weight=0.6, audio_weight=0.6)

    def test_confidence_threshold_must_be_positive(self):
        with pytest.raises(ValueError, match="confidence_threshold"):
            FusionConfig(confidence_threshold=0.0)

    def test_valid_config_accepted(self):
        cfg = FusionConfig(confidence_threshold=0.5, current_weight=0.6, audio_weight=0.4)
        assert cfg.confidence_threshold == 0.5


# ═══════════════════════════════════════════════════════════════════════════════
# 2. FakeCurrentReader
# ═══════════════════════════════════════════════════════════════════════════════

class TestFakeCurrentReader:
    def test_returns_voltages_in_order(self):
        reader = FakeCurrentReader([2.5, 2.6, 2.7])
        assert reader.read_voltage() == pytest.approx(2.5)
        assert reader.read_voltage() == pytest.approx(2.6)
        assert reader.read_voltage() == pytest.approx(2.7)

    def test_holds_last_value_when_exhausted(self):
        reader = FakeCurrentReader([2.5, 2.6])
        reader.read_voltage()
        reader.read_voltage()
        assert reader.read_voltage() == pytest.approx(2.6)
        assert reader.read_voltage() == pytest.approx(2.6)


# ═══════════════════════════════════════════════════════════════════════════════
# 3. CurrentSensor
# ═══════════════════════════════════════════════════════════════════════════════

def _make_current_sensor(voltages: list[float], **kwargs) -> CurrentSensor:
    params = {"window_size": 5, **kwargs}   # kwargs override defaults
    cfg = CurrentSensorConfig(**params)
    return CurrentSensor(FakeCurrentReader(voltages), cfg)


class TestCurrentSensor:
    def test_voltage_to_current_at_zero(self):
        sensor = _make_current_sensor([_ZERO_V])
        assert sensor.read_current_a() == pytest.approx(0.0, abs=1e-6)

    def test_voltage_above_zero_gives_positive_current(self):
        # +185 mV above zero → +1 A
        sensor = _make_current_sensor([_ZERO_V + _SENSITIVITY])
        assert sensor.read_current_a() == pytest.approx(1.0, abs=1e-4)

    def test_voltage_below_zero_gives_negative_current(self):
        sensor = _make_current_sensor([_ZERO_V - _SENSITIVITY])
        assert sensor.read_current_a() == pytest.approx(-1.0, abs=1e-4)

    def test_not_pressed_before_window_primed(self):
        # window_size=5, provide only 3 samples
        voltages = [_ZERO_V] * 3 + [_ZERO_V + 0.1]
        sensor = _make_current_sensor(voltages)
        for _ in range(3):
            pressed, _ = sensor.is_pressed()
            assert pressed is False

    def test_pressed_false_during_stable_baseline(self):
        stable = [_ZERO_V] * 10
        sensor = _make_current_sensor(stable)
        for _ in range(10):
            pressed, delta = sensor.is_pressed()
        assert pressed is False
        assert delta == pytest.approx(0.0, abs=1e-6)

    def test_pressed_true_on_sudden_current_spike(self):
        # 5 stable samples to prime window, then a spike
        threshold_a = 0.012
        spike_v = _ZERO_V + (threshold_a + 0.005) * _SENSITIVITY
        voltages = [_ZERO_V] * 5 + [spike_v]
        sensor = _make_current_sensor(voltages, press_threshold_a=threshold_a)
        for _ in range(5):
            sensor.is_pressed()
        pressed, delta = sensor.is_pressed()
        assert pressed is True
        assert delta > threshold_a

    def test_pressed_false_when_spike_below_threshold(self):
        threshold_a = 0.012
        small_spike_v = _ZERO_V + (threshold_a * 0.5) * _SENSITIVITY
        voltages = [_ZERO_V] * 5 + [small_spike_v]
        sensor = _make_current_sensor(voltages, press_threshold_a=threshold_a)
        for _ in range(5):
            sensor.is_pressed()
        pressed, _ = sensor.is_pressed()
        assert pressed is False

    def test_prime_fills_window(self):
        sensor = _make_current_sensor([_ZERO_V] * 20)
        sensor.prime()
        # After priming, window should have exactly window_size entries
        assert len(sensor._window) == sensor._cfg.window_size

    def test_prime_with_explicit_samples(self):
        sensor = _make_current_sensor([_ZERO_V] * 30, window_size=10)
        sensor.prime(samples=8)
        assert len(sensor._window) == 8

    def test_window_rolls_over_baseline(self):
        # Long stable run — window should track the moving mean accurately
        voltages = [_ZERO_V + i * 0.001 for i in range(30)]
        sensor = _make_current_sensor(voltages, window_size=5)
        for _ in range(30):
            sensor.is_pressed()
        # No sudden jump, so should never be pressed
        # (all deltas are within 0.001V * ... / 0.185 ≈ tiny)
        pressed, _ = sensor.is_pressed()
        assert pressed is False


# ═══════════════════════════════════════════════════════════════════════════════
# 4. FakeAudioReader helpers
# ═══════════════════════════════════════════════════════════════════════════════

class TestFakeAudioReaderHelpers:
    def test_silence_is_zeros(self):
        frame = FakeAudioReader.silence(_CHUNK)
        assert frame.shape == (_CHUNK,)
        assert np.all(frame == 0.0)

    def test_tone_has_correct_peak_frequency(self):
        freq = 1500.0
        frame = FakeAudioReader.tone(freq, _CHUNK, _RATE)
        fft_mag = np.abs(np.fft.rfft(frame))
        freqs = np.fft.rfftfreq(_CHUNK, 1.0 / _RATE)
        peak = freqs[np.argmax(fft_mag)]
        # Allow ±1 bin tolerance
        bin_width = _RATE / _CHUNK
        assert abs(peak - freq) <= bin_width

    def test_noise_has_small_amplitude(self):
        frame = FakeAudioReader.noise(_CHUNK)
        assert frame.max() < 0.1
        assert frame.min() > -0.1


# ═══════════════════════════════════════════════════════════════════════════════
# 5. _band_energy_ratio
# ═══════════════════════════════════════════════════════════════════════════════

class TestBandEnergyRatio:
    def test_silence_returns_zero(self):
        silence = np.zeros(_CHUNK, dtype=np.float32)
        ratio = _band_energy_ratio(silence, _RATE, 800, 3000)
        assert ratio == pytest.approx(0.0)

    def test_tone_inside_band_returns_high_ratio(self):
        tone = FakeAudioReader.tone(1500, _CHUNK, _RATE)
        ratio = _band_energy_ratio(tone, _RATE, 800, 3000)
        assert ratio > 0.7

    def test_tone_outside_band_returns_low_ratio(self):
        # 100 Hz tone — below the 800 Hz lower bound
        tone = FakeAudioReader.tone(100, _CHUNK, _RATE)
        ratio = _band_energy_ratio(tone, _RATE, 800, 3000)
        assert ratio < 0.1

    def test_band_entirely_above_signal_returns_low_ratio(self):
        tone = FakeAudioReader.tone(500, _CHUNK, _RATE)
        ratio = _band_energy_ratio(tone, _RATE, 2000, 4000)
        assert ratio < 0.05

    def test_noise_ratio_is_roughly_proportional_to_band_width(self):
        noise = FakeAudioReader.noise(_CHUNK)
        # 800–3000 Hz out of 0–8000 Hz Nyquist → ~27 % of band
        ratio = _band_energy_ratio(noise, _RATE, 800, 3000)
        assert 0.1 < ratio < 0.6  # wide tolerance for random noise


# ═══════════════════════════════════════════════════════════════════════════════
# 6. AudioSensor
# ═══════════════════════════════════════════════════════════════════════════════

def _make_audio_sensor(frames: list[np.ndarray], **kwargs) -> AudioSensor:
    params = {"band_energy_threshold": 0.35, **kwargs}   # kwargs override defaults
    cfg = AudioSensorConfig(**params)
    return AudioSensor(FakeAudioReader(frames), cfg)


class TestAudioSensor:
    def test_silence_not_pressed(self):
        sensor = _make_audio_sensor([FakeAudioReader.silence()])
        pressed, ratio = sensor.is_pressed()
        assert pressed is False
        assert ratio == pytest.approx(0.0)

    def test_in_band_tone_is_pressed(self):
        tone = FakeAudioReader.tone(1500)
        sensor = _make_audio_sensor([tone])
        pressed, ratio = sensor.is_pressed()
        assert pressed is True
        assert ratio > 0.35

    def test_out_of_band_tone_not_pressed(self):
        tone = FakeAudioReader.tone(100)  # 100 Hz — below band
        sensor = _make_audio_sensor([tone])
        pressed, ratio = sensor.is_pressed()
        assert pressed is False

    def test_ratio_clamped_between_zero_and_one(self):
        tone = FakeAudioReader.tone(1200)
        sensor = _make_audio_sensor([tone])
        _, ratio = sensor.is_pressed()
        assert 0.0 <= ratio <= 1.0

    def test_high_threshold_suppresses_moderate_signal(self):
        # White noise has ~25-35% band energy in 800-3000 Hz; threshold=0.90 rejects it
        noise = FakeAudioReader.noise()
        sensor = _make_audio_sensor([noise], band_energy_threshold=0.90)
        pressed, ratio = sensor.is_pressed()
        assert ratio < 0.90
        assert pressed is False

    def test_consecutive_frames_processed_independently(self):
        frames = [FakeAudioReader.silence(), FakeAudioReader.tone(1500)]
        sensor = _make_audio_sensor(frames)
        p1, _ = sensor.is_pressed()
        p2, _ = sensor.is_pressed()
        assert p1 is False
        assert p2 is True


# ═══════════════════════════════════════════════════════════════════════════════
# 7. fuse()
# ═══════════════════════════════════════════════════════════════════════════════

class TestFuse:
    _cfg = FusionConfig()  # current=0.55, audio=0.45, threshold=0.50

    def test_both_signals_positive_gives_full_confidence(self):
        result = fuse(True, 0.020, True, 0.8, self._cfg)
        assert result.pressed is True
        assert result.confidence == pytest.approx(1.0)

    def test_both_signals_negative_gives_zero_confidence(self):
        result = fuse(False, 0.0, False, 0.0, self._cfg)
        assert result.pressed is False
        assert result.confidence == pytest.approx(0.0)

    def test_current_only_above_threshold(self):
        # current=0.55 ≥ 0.50 threshold
        result = fuse(True, 0.015, False, 0.0, self._cfg)
        assert result.pressed is True
        assert result.confidence == pytest.approx(0.55)

    def test_audio_only_below_threshold(self):
        # audio=0.45 < 0.50 threshold
        result = fuse(False, 0.0, True, 0.7, self._cfg)
        assert result.pressed is False
        assert result.confidence == pytest.approx(0.45)

    def test_detail_string_contains_signal_info(self):
        result = fuse(True, 0.020, False, 0.1, self._cfg)
        assert "✅" in result.detail
        assert "❌" in result.detail
        assert "mA" in result.detail
        assert "ratio" in result.detail

    def test_confidence_within_valid_range(self):
        for current in [True, False]:
            for audio in [True, False]:
                result = fuse(current, 0.01, audio, 0.5, self._cfg)
                assert 0.0 <= result.confidence <= 1.0

    def test_custom_weights_change_decision(self):
        # With heavy current bias (0.8), current alone crosses threshold 0.50
        cfg = FusionConfig(current_weight=0.8, audio_weight=0.2, confidence_threshold=0.5)
        result = fuse(True, 0.015, False, 0.0, cfg)
        assert result.pressed is True
        assert result.confidence == pytest.approx(0.8)

    def test_high_threshold_requires_both_signals(self):
        cfg = FusionConfig(current_weight=0.55, audio_weight=0.45, confidence_threshold=0.90)
        assert fuse(True, 0.015, False, 0.0, cfg).pressed is False
        assert fuse(False, 0.0, True, 0.7, cfg).pressed is False
        assert fuse(True, 0.015, True, 0.7, cfg).pressed is True


# ═══════════════════════════════════════════════════════════════════════════════
# 8. SensorVerifier (통합)
# ═══════════════════════════════════════════════════════════════════════════════

def _make_verifier(
    voltages: list[float],
    frames: list[np.ndarray],
    config: SensorConfig | None = None,
) -> SensorVerifier:
    cfg = config or SensorConfig(
        current=CurrentSensorConfig(window_size=5),
    )
    return SensorVerifier(
        config=cfg,
        current_reader=FakeCurrentReader(voltages),
        audio_reader=FakeAudioReader(frames),
    )


class TestSensorVerifier:
    def test_both_sensors_positive_returns_pressed(self):
        spike_v = _ZERO_V + 0.02 * _SENSITIVITY
        voltages = [_ZERO_V] * 5 + [spike_v]
        frames = [FakeAudioReader.tone(1500)]
        verifier = _make_verifier(voltages, frames)
        result = verifier.verify("BT-05")
        assert result.pressed is True
        assert result.confidence >= 0.5

    def test_both_sensors_negative_returns_not_pressed(self):
        voltages = [_ZERO_V] * 6
        frames = [FakeAudioReader.silence()] * 6
        verifier = _make_verifier(voltages, frames)
        result = verifier.verify("BT-05")
        assert result.pressed is False
        assert result.confidence == pytest.approx(0.0)

    def test_button_name_does_not_affect_result(self):
        # verify() accepts any button name — result depends only on sensor state
        voltages = [_ZERO_V] * 6
        frames = [FakeAudioReader.silence()] * 6
        verifier = _make_verifier(voltages, frames)
        r1 = verifier.verify("BT-01")
        verifier2 = _make_verifier([_ZERO_V] * 6, [FakeAudioReader.silence()] * 6)
        r2 = verifier2.verify("BT-99")
        assert r1.pressed == r2.pressed

    def test_result_satisfies_verification_result_invariant(self):
        voltages = [_ZERO_V] * 6
        frames = [FakeAudioReader.silence()] * 6
        verifier = _make_verifier(voltages, frames)
        result = verifier.verify("BT-01")
        assert 0.0 <= result.confidence <= 1.0
        assert isinstance(result.detail, str)
        assert len(result.detail) > 0

    def test_verify_returns_verificationresult_type(self):
        from rpi.verifier.base import VerificationResult
        voltages = [_ZERO_V] * 6
        frames = [FakeAudioReader.silence()] * 6
        verifier = _make_verifier(voltages, frames)
        result = verifier.verify("BT-05")
        assert isinstance(result, VerificationResult)

    def test_close_does_not_raise(self):
        voltages = [_ZERO_V] * 6
        frames = [FakeAudioReader.silence()] * 6
        verifier = _make_verifier(voltages, frames)
        verifier.close()  # should not raise

    def test_custom_fusion_config_applied(self):
        # current_weight=0.55, threshold=0.80 → current alone (0.55) won't pass
        cfg = SensorConfig(
            current=CurrentSensorConfig(window_size=5),
            fusion=FusionConfig(
                current_weight=0.55,
                audio_weight=0.45,
                confidence_threshold=0.80,
            ),
        )
        spike_v = _ZERO_V + 0.1 * _SENSITIVITY
        voltages = [_ZERO_V] * 5 + [spike_v]
        frames = [FakeAudioReader.silence()]   # audio NOT pressed
        verifier = _make_verifier(voltages, frames, config=cfg)
        result = verifier.verify("BT-05")
        # current alone (0.55) < threshold (0.80) → not pressed
        assert result.pressed is False
        assert result.confidence == pytest.approx(0.55)

    def test_integrates_with_closed_loop_controller(self):
        """SensorVerifier plugs into ClosedLoopController without error."""
        from rpi.controller import ClosedLoopController, ExecutionStatus
        from rpi.controller.mock import (
            MockAlertSink,
            MockGrblClient,
            MockSafetyController,
        )

        spike_v = _ZERO_V + 0.02 * _SENSITIVITY
        voltages = [_ZERO_V] * 5 + [spike_v] * 3
        frames = [FakeAudioReader.tone(1500)] * 8
        verifier = _make_verifier(voltages, frames)

        # 준비 호출 없이(2026-10-07): 컨트롤러가 누르기 직전에 기준선을 잡는다

        controller = ClosedLoopController(
            grbl=MockGrblClient(),
            verifier=verifier,
            alerts=MockAlertSink(),
            safety=MockSafetyController(),
        )
        result = controller.execute(["BT-05"])
        assert result.status is ExecutionStatus.SUCCEEDED
