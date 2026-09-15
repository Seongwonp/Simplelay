"""L3 전력 기반 동작 확인(rpi/verifier/power.py) 단위 테스트.

하드웨어 없이 합성 파형(microwave_profile)과 MockPowerSensor만 쓴다.
시각은 샘플 t_s로 주입되므로 시스템 시계와 무관하게 결정적이다.
"""

from __future__ import annotations

import math

import pytest

from rpi.verifier.power import (
    L3Verdict,
    MockPowerSensor,
    OperationPhase,
    PowerConfig,
    PowerSample,
    PowerSignatureDetector,
    ct_voltage_rms_to_watts,
    microwave_profile,
    rms,
)

_HZ = 10.0


def _flat(values_by_segment: list[tuple[float, float]], *, hz: float = _HZ) -> list[PowerSample]:
    """[(지속 초, 전력 W), ...] 구간을 이어 붙인 샘플열."""
    samples: list[PowerSample] = []
    i = 0
    for duration_s, watts in values_by_segment:
        for _ in range(int(round(duration_s * hz))):
            samples.append(PowerSample(t_s=i / hz, watts=watts))
            i += 1
    return samples


def _feed_all(detector: PowerSignatureDetector, samples: list[PowerSample]) -> OperationPhase:
    phase = detector.phase
    for s in samples:
        phase = detector.feed(s)
    return phase


# ═══════════════════════════════════════════════════════════════════════════════
# 1. 변환 함수
# ═══════════════════════════════════════════════════════════════════════════════


class TestConversion:
    def test_one_volt_rms_is_6600_watts(self):
        # 1.0 V rms × 30 A/V × 220 V × PF 1.0
        assert ct_voltage_rms_to_watts(1.0) == pytest.approx(6600.0)

    def test_zero_volt_is_zero_watts(self):
        assert ct_voltage_rms_to_watts(0.0) == 0.0

    def test_power_factor_scales_watts(self):
        cfg = PowerConfig(power_factor=0.5)
        assert ct_voltage_rms_to_watts(1.0, cfg) == pytest.approx(3300.0)

    @pytest.mark.parametrize("bad", [-0.1, math.nan, math.inf])
    def test_invalid_voltage_rejected(self, bad):
        with pytest.raises(ValueError):
            ct_voltage_rms_to_watts(bad)

    def test_rms_of_sine_is_peak_over_root_two(self):
        n = 1000
        values = [math.sin(2 * math.pi * k / n) for k in range(n)]
        assert rms(values) == pytest.approx(1 / math.sqrt(2), rel=1e-6)

    def test_rms_of_empty_rejected(self):
        with pytest.raises(ValueError):
            rms([])


# ═══════════════════════════════════════════════════════════════════════════════
# 2. 시작·완료 판정
# ═══════════════════════════════════════════════════════════════════════════════


class TestMicrowaveProfile:
    def test_start_confirmed_with_baseline_and_peak_then_running(self):
        det = PowerSignatureDetector()
        samples = microwave_profile()  # 3 W → 1,200 W at 1.0 s, 30 s run
        for s in samples:
            det.feed(s)
            if s.t_s >= 3.0:
                break

        assert det.phase is OperationPhase.RUNNING
        v = det.verify_started(since_s=1.0)
        assert v.confirmed is True
        assert v.phase is OperationPhase.RUNNING
        assert v.baseline_w == pytest.approx(3.0)
        assert v.peak_w == pytest.approx(1200.0)
        assert v.decided_at_s == pytest.approx(2.0)  # 1.0 s 상승 + 1.0 s 유지
        assert "기준선 3.0W" in v.detail
        assert "1,200W" in v.detail
        assert "1.0초 유지" in v.detail

    def test_finish_confirmed_after_run(self):
        det = PowerSignatureDetector()
        phase = _feed_all(det, microwave_profile())

        assert phase is OperationPhase.FINISHED
        started = det.verify_started(since_s=1.0)
        assert started.confirmed is True
        finished = det.verify_finished()
        assert finished.confirmed is True
        assert finished.phase is OperationPhase.FINISHED
        assert finished.peak_w == pytest.approx(1200.0)
        # 조리 끝 31.0 s에 하강 시작, 2.0 s 유지 → 33.0 s 확정
        assert finished.decided_at_s == pytest.approx(33.0)

    def test_finish_not_confirmed_while_running(self):
        det = PowerSignatureDetector()
        _feed_all(det, microwave_profile(tail_s=0.0))
        v = det.verify_finished()
        assert v.confirmed is False
        assert v.phase is OperationPhase.RUNNING
        assert v.decided_at_s is None

    def test_short_dip_during_run_does_not_finish(self):
        # 조리 중 1초 순간 정지(인버터 출력 단계 전환 등)는 완료가 아니다
        samples = _flat([(2.0, 3.0), (5.0, 1200.0), (1.0, 5.0), (5.0, 1200.0)])
        det = PowerSignatureDetector()
        assert _feed_all(det, samples) is OperationPhase.RUNNING
        assert det.verify_finished().confirmed is False

    def test_noisy_profile_still_confirms_start(self):
        det = PowerSignatureDetector()
        samples = microwave_profile(noise_w=20.0, seed=7, run_s=10.0)
        for s in samples:
            det.feed(s)
            if s.t_s >= 5.0:
                break
        v = det.verify_started(since_s=1.0)
        assert v.confirmed is True
        assert v.phase is OperationPhase.RUNNING
        assert v.baseline_w is not None and v.baseline_w < 30.0
        assert v.peak_w is not None and v.peak_w > 1150.0

    def test_noisy_profile_is_deterministic_for_seed(self):
        a = microwave_profile(noise_w=20.0, seed=3)
        b = microwave_profile(noise_w=20.0, seed=3)
        c = microwave_profile(noise_w=20.0, seed=4)
        assert a == b
        assert a != c
        assert all(s.watts >= 0 for s in a)


class TestRejectedStarts:
    def test_inrush_spike_does_not_confirm_start(self):
        # 0.2 s 1,500 W 돌입 후 대기로 복귀
        samples = _flat([(2.0, 3.0), (0.2, 1500.0), (5.0, 3.0)])
        det = PowerSignatureDetector()
        assert _feed_all(det, samples) is OperationPhase.IDLE

        v = det.verify_started(since_s=2.0)
        assert v.confirmed is False
        assert "시작 전력 상승이 확인되지 않음" in v.detail
        assert v.peak_w == pytest.approx(1500.0)

    def test_small_load_change_fails_absolute_rise(self):
        # 3 W → 60 W: 배율은 20배지만 상승 57 W < 300 W
        samples = _flat([(2.0, 3.0), (6.0, 60.0)])
        det = PowerSignatureDetector()
        assert _feed_all(det, samples) is OperationPhase.IDLE
        v = det.verify_started(since_s=2.0)
        assert v.confirmed is False
        assert "60.0W" in v.detail

    def test_high_idle_baseline_fails_ratio(self):
        # 400 W → 900 W: 상승 500 W ≥ 300 W 이지만 배율 2.25 < 5
        samples = _flat([(2.0, 400.0), (6.0, 900.0)])
        det = PowerSignatureDetector()
        assert _feed_all(det, samples) is OperationPhase.IDLE
        v = det.verify_started(since_s=2.0)
        assert v.confirmed is False
        assert v.baseline_w == pytest.approx(400.0)
        assert "900W" in v.detail

    def test_baseline_is_median_robust_to_idle_spike(self):
        # 대기 중 한 샘플 튐(200 W)이 있어도 기준선은 중앙값 3 W
        idle = _flat([(2.0, 3.0)])
        idle[10] = PowerSample(t_s=idle[10].t_s, watts=200.0)
        run = [PowerSample(t_s=2.0 + i / _HZ, watts=1000.0) for i in range(20)]
        det = PowerSignatureDetector()
        _feed_all(det, idle + run)
        v = det.verify_started(since_s=2.0)
        assert v.confirmed is True
        assert v.baseline_w == pytest.approx(3.0)

    def test_rise_before_press_is_not_attributed_to_press(self):
        det = PowerSignatureDetector()
        _feed_all(det, microwave_profile(run_s=10.0, tail_s=0.0))
        v = det.verify_started(since_s=5.0)
        assert v.confirmed is False
        assert "이미 동작 중" in v.detail


class TestTimeout:
    def test_pending_before_timeout(self):
        det = PowerSignatureDetector()
        _feed_all(det, _flat([(4.0, 3.0)]))  # 마지막 샘플 3.9 s
        v = det.verify_started(since_s=0.0)
        assert v.confirmed is False
        assert v.phase is OperationPhase.IDLE
        assert v.detail == "판정 대기"
        assert v.decided_at_s is None

    def test_pending_with_no_samples(self):
        v = PowerSignatureDetector().verify_started(since_s=0.0)
        assert v.confirmed is False
        assert v.detail == "판정 대기"

    def test_pending_reports_current_phase_while_starting(self):
        det = PowerSignatureDetector()
        _feed_all(det, _flat([(2.0, 3.0), (0.5, 1200.0)]))
        v = det.verify_started(since_s=2.0)
        assert v.phase is OperationPhase.STARTING
        assert v.detail == "판정 대기"

    def test_not_confirmed_after_timeout_reports_peak(self):
        samples = _flat([(1.0, 3.0), (0.5, 80.0), (5.0, 3.0)])
        det = PowerSignatureDetector()
        _feed_all(det, samples)  # 마지막 샘플 6.4 s ≥ 0.5 + 5.0
        v = det.verify_started(since_s=0.5)
        assert v.confirmed is False
        assert v.phase is OperationPhase.IDLE
        assert "시작 전력 상승이 확인되지 않음" in v.detail
        assert "관측 최대 80.0W" in v.detail
        assert v.peak_w == pytest.approx(80.0)
        assert v.decided_at_s == pytest.approx(5.5)

    def test_start_confirmed_after_deadline_is_not_confirmed(self):
        # 조작 0 s, 상승 4.5 s → 확정 5.5 s > 제한 5.0 s
        samples = _flat([(4.5, 3.0), (3.0, 1200.0)])
        det = PowerSignatureDetector()
        assert _feed_all(det, samples) is OperationPhase.RUNNING
        v = det.verify_started(since_s=0.0)
        assert v.confirmed is False
        assert "시작 전력 상승이 확인되지 않음" in v.detail


# ═══════════════════════════════════════════════════════════════════════════════
# 3. 잘못된 입력
# ═══════════════════════════════════════════════════════════════════════════════


class TestBadSamples:
    def test_nan_negative_and_out_of_order_samples_ignored(self):
        det = PowerSignatureDetector()
        good = microwave_profile(run_s=5.0, tail_s=3.0)
        noisy: list[PowerSample] = []
        for s in good:
            noisy.append(s)
            noisy.append(PowerSample(t_s=s.t_s + 0.01, watts=math.nan))
            noisy.append(PowerSample(t_s=s.t_s + 0.02, watts=-50.0))
            noisy.append(PowerSample(t_s=s.t_s + 0.03, watts=math.inf))
            noisy.append(PowerSample(t_s=math.nan, watts=1200.0))
            # 시간 역행: 대기 구간에 큰 전력을 끼워 넣어도 무시돼야 한다
            noisy.append(PowerSample(t_s=s.t_s - 0.5, watts=5000.0))
            noisy.append(PowerSample(t_s=s.t_s, watts=5000.0))  # 같은 시각 중복

        ref = PowerSignatureDetector()
        assert _feed_all(det, noisy) is _feed_all(ref, good)
        assert det.verify_started(since_s=1.0) == ref.verify_started(since_s=1.0)
        assert det.verify_finished() == ref.verify_finished()
        assert det.verify_finished().confirmed is True
        assert det.verify_started(since_s=1.0).peak_w == pytest.approx(1200.0)

    def test_feed_returns_phase_for_ignored_sample(self):
        det = PowerSignatureDetector()
        assert det.feed(PowerSample(t_s=0.0, watts=math.nan)) is OperationPhase.IDLE
        assert det.feed(PowerSample(t_s=0.0, watts=-1.0)) is OperationPhase.IDLE


# ═══════════════════════════════════════════════════════════════════════════════
# 4. 센서 · 결과 계약
# ═══════════════════════════════════════════════════════════════════════════════


class TestMockPowerSensor:
    def test_returns_samples_in_order_then_repeats_last(self):
        samples = [PowerSample(0.0, 3.0), PowerSample(0.1, 1200.0)]
        sensor = MockPowerSensor(samples)
        assert sensor.read() == samples[0]
        assert sensor.read() == samples[1]
        assert sensor.read() == samples[1]
        assert sensor.read() == samples[1]

    def test_empty_rejected(self):
        with pytest.raises(ValueError):
            MockPowerSensor([])

    def test_sensor_drives_detector(self):
        samples = microwave_profile(run_s=5.0)
        sensor = MockPowerSensor(samples)
        det = PowerSignatureDetector()
        for _ in range(len(samples) + 10):  # 소진 후 반복 샘플은 같은 시각이라 무시
            det.feed(sensor.read())
        assert det.phase is OperationPhase.FINISHED


class TestVerdictContract:
    def test_verdict_layer_is_l3(self):
        det = PowerSignatureDetector()
        _feed_all(det, microwave_profile(run_s=5.0))
        verdicts = [
            det.verify_started(since_s=1.0),
            det.verify_finished(),
            PowerSignatureDetector().verify_started(since_s=0.0),
            PowerSignatureDetector().verify_finished(),
        ]
        assert all(isinstance(v, L3Verdict) and v.layer == "L3" for v in verdicts)

    def test_verdict_is_frozen(self):
        v = PowerSignatureDetector().verify_finished()
        with pytest.raises(Exception):
            v.confirmed = True  # type: ignore[misc]

    def test_phase_values_are_strings(self):
        assert OperationPhase.RUNNING == "running"
        assert [p.value for p in OperationPhase] == [
            "idle", "starting", "running", "stopping", "finished",
        ]

    def test_invalid_config_rejected(self):
        with pytest.raises(ValueError):
            PowerConfig(power_factor=0.0)
        with pytest.raises(ValueError):
            PowerConfig(start_rise_ratio=0.5)
