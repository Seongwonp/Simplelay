"""세탁 끝 판정 — CT 전력 '운전 → 대기 복귀' 검출기(rpi/verifier/cycle_end.py) 시험.

합성 전력 곡선만 쓴다(실측 아님). 기준값은 시험용으로 줄였다 — 실제 값은 전부 측정 필요.
"""

from __future__ import annotations

import math
import random

import pytest

from rpi.verifier.cycle_end import (
    CYCLE_ENV_NAMES,
    CycleEndConfig,
    CycleEndTracker,
    detect_cycle_ends,
)
from rpi.verifier.power import PowerSample

CFG = CycleEndConfig(run_min_w=100.0, min_run_s=60.0, standby_max_w=15.0, settle_s=30.0, max_gap_s=5.0)


def _series(segments, *, dt=1.0, t0=0.0):
    """[(지속 초, W), ...] → 1초 간격 샘플."""
    out, t = [], t0
    for duration, watts in segments:
        end = t + duration
        while t < end - 1e-9:
            out.append(PowerSample(t_s=t, watts=watts))
            t += dt
    return out


def test_running_then_standby_is_one_cycle_end_with_measured_values():
    samples = _series([(10, 3), (120, 400), (60, 4)])
    (event,) = detect_cycle_ends(samples, CFG)
    assert event.started_at_s == pytest.approx(10.0)
    assert event.standby_from_s == pytest.approx(130.0)
    # 대기 띠 안에 settle_s(30초) 머문 시각이 완료 시각이다.
    assert event.done_at_s == pytest.approx(160.0)
    assert event.run_s == pytest.approx(120.0)
    assert event.peak_w == pytest.approx(400.0)
    assert event.mean_run_w == pytest.approx(400.0)
    assert event.standby_w == pytest.approx(4.0)
    assert event.dips == 0
    doc = event.as_dict()
    assert doc["standby_from_s"] == pytest.approx(130.0)
    assert "detail" in doc


def test_mid_cycle_dip_shorter_than_settle_is_not_done():
    # 헹굼·담금 사이 20초 하강(settle 30초 미만)은 끝이 아니다 — 하나의 사이클로 본다.
    samples = _series([(5, 3), (100, 400), (20, 5), (100, 600), (45, 3)])
    events = detect_cycle_ends(samples, CFG)
    assert len(events) == 1
    event = events[0]
    assert event.standby_from_s == pytest.approx(225.0)
    assert event.dips == 1
    assert event.peak_w == pytest.approx(600.0)


def test_short_spike_below_min_run_is_not_a_cycle():
    # 문 잠금·표시창처럼 짧게 튄 전력(min_run_s 미만)은 운전이 아니다.
    samples = _series([(5, 3), (20, 500), (60, 3)])
    assert detect_cycle_ends(samples, CFG) == []


def test_still_running_at_end_of_data_is_not_done():
    samples = _series([(5, 3), (200, 400), (10, 3)])  # 대기 10초 — settle 전에 끝
    assert detect_cycle_ends(samples, CFG) == []


def test_noisy_run_with_dips_and_noisy_standby_detects_one_end():
    rng = random.Random(7)
    samples, t = [], 0.0
    for _ in range(10):
        samples.append(PowerSample(t, 3 + rng.uniform(-1, 1)))
        t += 1
    for i in range(300):  # 드럼 회전·정지가 번갈아 드는 운전(가끔 짧게 대기 띠로)
        w = 350 + 150 * math.sin(i / 7) + rng.uniform(-40, 40)
        if i % 50 in (20, 21, 22):
            w = 8.0
        samples.append(PowerSample(t, max(w, 0.0)))
        t += 1
    for _ in range(60):
        samples.append(PowerSample(t, 4 + rng.uniform(-2, 2)))
        t += 1
    events = detect_cycle_ends(samples, CFG)
    assert len(events) == 1
    assert events[0].dips >= 5


def test_mid_band_power_neither_runs_nor_settles():
    # 대기 상한 초과·운전 하한 미만(예: 50 W)은 대기도 운전도 아니다 — 대기 판정을 끊는다.
    samples = _series([(5, 3), (100, 400), (20, 3), (20, 50), (20, 3)])
    assert detect_cycle_ends(samples, CFG) == []


def test_gap_in_stream_does_not_count_as_standby_time():
    samples = _series([(5, 3), (100, 400)])
    samples.append(PowerSample(105.0, 3.0))
    samples.append(PowerSample(160.0, 3.0))  # 55초 끊김 뒤 한 샘플 — 끊긴 시간을 대기로 세지 않는다
    assert detect_cycle_ends(samples, CFG) == []


def test_note_gap_resets_standby_run():
    tracker = CycleEndTracker(CFG)
    for s in _series([(5, 3), (100, 400), (20, 3)]):
        assert tracker.feed(s) is None
    tracker.note_gap()
    for s in _series([(25, 3)], t0=125.0):
        assert tracker.feed(s) is None  # 끊김 뒤 다시 30초가 필요하다
    events = [tracker.feed(s) for s in _series([(10, 3)], t0=150.0)]
    assert any(e is not None for e in events)


def test_tracker_rearms_for_the_next_cycle():
    samples = _series([(5, 3), (100, 400), (40, 3), (100, 500), (40, 3)])
    events = detect_cycle_ends(samples, CFG)
    assert len(events) == 2


def test_invalid_samples_are_ignored():
    tracker = CycleEndTracker(CFG)
    assert tracker.feed(PowerSample(0.0, float("nan"))) is None
    assert tracker.feed(PowerSample(1.0, -5.0)) is None
    assert tracker.phase == "idle"


def test_config_validation_and_env():
    with pytest.raises(ValueError):
        CycleEndConfig(run_min_w=10.0, standby_max_w=20.0)
    with pytest.raises(ValueError):
        CycleEndConfig(settle_s=0.0)
    env = {CYCLE_ENV_NAMES["run_min_w"]: "250", CYCLE_ENV_NAMES["settle_s"]: "90"}
    cfg = CycleEndConfig.from_env(env)
    assert cfg.run_min_w == 250.0 and cfg.settle_s == 90.0
    with pytest.raises(RuntimeError):
        CycleEndConfig.from_env({CYCLE_ENV_NAMES["min_run_s"]: "abc"})
