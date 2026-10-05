"""가전 완료 융합(rpi/verifier/done_fusion.py) — 전력 하강 + 종료음."""

from __future__ import annotations

import pytest

from rpi.verifier.done_fusion import (
    DONE_STATES,
    FUSION_ENV_NAMES,
    ApplianceDoneFusion,
    DoneFusionConfig,
    rehearsal_done_event,
)

CFG = DoneFusionConfig(window_s=60.0, wait_s=90.0, cooldown_s=600.0)


def _fusion(expected=("power", "beep")):
    return ApplianceDoneFusion("washer", expected=expected, config=CFG, event="wash_complete")


def test_both_inputs_within_window_confirm():
    f = _fusion()
    assert f.note("beep", at_s=100.0, now_s=102.0, evidence={"beeps": 3}) is None
    event = f.note("power", at_s=110.0, now_s=140.0, evidence={"peak_w": 400})
    assert event is not None
    assert event.state == "done_confirmed"
    assert event.confidence == "confirmed"
    assert event.inputs == ("beep", "power")
    assert event.gap_s == pytest.approx(10.0)
    frame = event.to_frame()
    assert frame["type"] == "appliance_done"
    assert frame["appliance_id"] == "washer"
    assert frame["event"] == "wash_complete"
    assert frame["inputs"] == ["beep", "power"]
    assert frame["evidence"]["power"] == {"peak_w": 400}
    assert frame["source"] == "real"


def test_power_only_after_wait_is_probable():
    f = _fusion()
    assert f.note("power", at_s=0.0, now_s=30.0, evidence={}) is None
    assert f.poll(now_s=100.0) is None  # 기다리는 중(30 + 90 = 120까지)
    event = f.poll(now_s=121.0)
    assert event.state == "done_power_only"
    assert event.confidence == "probable"
    assert event.inputs == ("power",)


def test_beep_only_after_wait_is_probable():
    f = _fusion()
    f.note("beep", at_s=0.0, now_s=0.0, evidence={})
    event = f.poll(now_s=91.0)
    assert event.state == "done_beep_only"


def test_inputs_outside_window_do_not_confirm():
    f = _fusion()
    assert f.note("power", at_s=0.0, now_s=0.0, evidence={}) is None
    event = f.note("beep", at_s=80.0, now_s=80.0, evidence={})  # 60초 창 밖
    assert event is not None and event.state == "done_power_only"
    # 늦은 종료음은 쿨다운 안이라 따로 알리지 않는다(기록만).
    assert f.poll(now_s=500.0) is None
    assert f.ignored[-1]["kind"] == "beep"


def test_single_expected_input_reports_immediately_as_probable():
    f = _fusion(expected=("power",))
    event = f.note("power", at_s=0.0, now_s=0.0, evidence={})
    assert event.state == "done_power_only"


def test_unknown_input_kind_is_rejected():
    with pytest.raises(ValueError):
        _fusion().note("door", at_s=0.0, now_s=0.0, evidence={})


def test_mock_input_marks_event_mock():
    f = _fusion()
    f.note("beep", at_s=0.0, now_s=0.0, evidence={}, source="real")
    event = f.note("power", at_s=1.0, now_s=1.0, evidence={}, source="mock")
    assert event.source == "mock"


def test_flush_resolves_pending_immediately():
    f = _fusion()
    f.note("power", at_s=0.0, now_s=0.0, evidence={})
    assert f.flush(now_s=0.0).state == "done_power_only"


def test_rehearsal_event_is_labelled_injected():
    both = rehearsal_done_event("washer", ["power", "beep"], now_s=5.0)
    assert both.state == "done_confirmed" and both.source == "injected"
    one = rehearsal_done_event("washer", ["beep"], now_s=5.0)
    assert one.state == "done_beep_only" and one.source == "injected"
    with pytest.raises(ValueError):
        rehearsal_done_event("washer", [], now_s=0.0)


def test_states_and_config():
    assert DONE_STATES == ("done_confirmed", "done_power_only", "done_beep_only")
    with pytest.raises(ValueError):
        DoneFusionConfig(window_s=0.0)
    cfg = DoneFusionConfig.from_env({FUSION_ENV_NAMES["window_s"]: "30"})
    assert cfg.window_s == 30.0
