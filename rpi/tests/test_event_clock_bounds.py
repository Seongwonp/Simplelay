"""시각 기준점의 유효 기간·상대 드리프트 상한(4차 평가 M-N1, 2026-10-14) — ``rpi/services/event_clock.py``.

한 번 잡은 기준점(``clock_probe``/``clock_ref``)을 오래 쓰면 두 보드 시계의 속도 차이(드리프트)가 기준점 이후 경과만큼
쌓인다. 평가 재현: RPi4 시계가 10ppm 빠르고 기준점을 하루 유지하면 실제 120.5초인 사건이 119.6초로 계산됐다.
수리: 기준점 유효 기간(기본 600초, 측정 필요)을 넘기면 근거 없음(보류), 그 안에서는 상대 드리프트 상한(기본 500ppm,
NTP 최대 보정 속도 수준 — 측정 필요) × 기준점과 사건 사이 간격만큼 끝 시각을 이르게(나이를 길게) 잡고, 그 불확실성이
한계(기본 1초)를 넘으면 보류한다.

가짜 시계 계산 시험이다 — 실제 두 보드의 드리프트를 잰 것이 아니다.
"""

from __future__ import annotations

import pytest

from rpi.services.event_clock import EventClock

RPI4 = "rpi4clockdrift01"
REF_HUB_S = 10_000.0
REF_RPI4_S = 500.0


class _Hub:
    def __init__(self) -> None:
        self.now = REF_HUB_S


def _clock(hub: _Hub, **kwargs) -> EventClock:
    clock = EventClock(lambda: hub.now, **kwargs)
    probe = clock.new_probe()  # 허브 10,000초에 탐침(왕복 0 — 오차는 드리프트만)
    assert clock.on_clock_ref({"probe": probe, "clock_id": RPI4, "t_monotonic_ns": int(REF_RPI4_S * 1e9)})
    return clock


def _rpi4_time(true_end_hub_s: float, rate_ppm: float) -> float:
    """허브 시각으로 ``true_end_hub_s``인 순간의 RPi4 시계 값 — RPi4 시계가 허브보다 ``rate_ppm`` 빠르다(음수면 느림)."""
    return REF_RPI4_S + (true_end_hub_s - REF_HUB_S) * (1 + rate_ppm * 1e-6)


def test_a_reference_older_than_its_validity_is_not_used():
    hub = _Hub()
    clock = _clock(hub, ref_max_age_s=600.0)
    frame = {"clock_id": RPI4, "at_s": _rpi4_time(REF_HUB_S + 590, 0)}
    hub.now = REF_HUB_S + 599
    assert clock.end_local_s(frame) is not None
    hub.now = REF_HUB_S + 601  # 오래 유지한 연결 — 다시 탐침하지 않았다
    assert clock.end_local_s(frame) is None


@pytest.mark.parametrize("rate_ppm", [-450.0, -10.0, 0.0, 10.0, 450.0])
@pytest.mark.parametrize("held_s", [130.0, 350.0, 595.0])
def test_mapped_age_is_never_shorter_than_the_true_age_within_the_drift_bound(rate_ppm, held_s):
    """상대 드리프트가 상한(500ppm) 안이면, 기준점을 유효 기간 안에서 얼마나 오래 썼든 옮긴 끝 시각이 실제보다 늦지 않다
    (= 나이를 실제보다 짧게 잡지 않는다). 수정 전에는 RPi4가 빠르면 늦게 옮겼다."""
    hub = _Hub()
    clock = _clock(hub, drift_ppm=500.0, ref_max_age_s=600.0)
    true_end = REF_HUB_S + held_s - 120.05
    hub.now = REF_HUB_S + held_s
    mapped = clock.end_local_s({"clock_id": RPI4, "at_s": _rpi4_time(true_end, rate_ppm)})
    assert mapped is not None
    assert mapped <= true_end + 1e-9
    assert hub.now - mapped >= 120.05 - 1e-9  # 120초 근처 사건이 상한 안으로 들어오지 않는다


def test_the_evaluation_case_ten_ppm_fast_for_a_day_is_held_not_shortened():
    """평가 재현값: RPi4 10ppm 빠름·기준점 하루 유지·실제 나이 120.5초 → 예전 119.6초. 이제 기준점이 낡아 근거 없음(보류)."""
    hub = _Hub()
    clock = _clock(hub)
    day = 86_400.0
    hub.now = REF_HUB_S + day
    assert clock.end_local_s({"clock_id": RPI4, "at_s": _rpi4_time(hub.now - 120.5, 10.0)}) is None


def test_uncertainty_beyond_the_limit_is_held():
    hub = _Hub()
    clock = _clock(hub, drift_ppm=500.0, ref_max_age_s=600.0, max_uncertainty_s=0.2)
    hub.now = REF_HUB_S + 500
    near = {"clock_id": RPI4, "at_s": _rpi4_time(REF_HUB_S + 300, 0)}  # 간격 300초 × 500ppm = 0.15초
    far = {"clock_id": RPI4, "at_s": _rpi4_time(REF_HUB_S + 450, 0)}  # 450초 × 500ppm = 0.225초 > 0.2초
    assert clock.end_local_s(near) is not None
    assert clock.end_local_s(far) is None


def test_settings_come_from_the_environment(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_EVENT_CLOCK_REF_MAX_AGE_S", "30")
    monkeypatch.setenv("SIMPLELAY_EVENT_CLOCK_DRIFT_PPM", "1000")
    hub = _Hub()
    clock = _clock(hub)
    hub.now = REF_HUB_S + 20
    mapped = clock.end_local_s({"clock_id": RPI4, "at_s": _rpi4_time(REF_HUB_S + 10, 0)})
    assert mapped == pytest.approx(REF_HUB_S + 10 - 10 * 1000e-6)
    hub.now = REF_HUB_S + 31
    assert clock.end_local_s({"clock_id": RPI4, "at_s": _rpi4_time(REF_HUB_S + 25, 0)}) is None
    monkeypatch.setenv("SIMPLELAY_EVENT_CLOCK_DRIFT_PPM", "abc")
    with pytest.raises(RuntimeError):
        EventClock(lambda: 0.0)
