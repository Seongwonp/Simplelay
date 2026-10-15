"""정지 버튼 대기·보관 상태 기계(rpi4/services/stop_hold.py) — 모의 모션·모의 가전만."""

from __future__ import annotations

import threading
import time

import pytest

from rpi4.models.act_messages import HoldPlan, VerifyTarget, parse_act_message
from rpi4.parking_simulator import Mapping, MmPoint, Point
from rpi4.services.stop_hold import (
    DETAIL_DRIVE_FAULT,
    HoldTiming,
    MockApplianceRun,
    MockHoldMotion,
    NoRunProbe,
    StopHoldSession,
    run_verify_pass,
)

PLAN = HoldPlan("취소", 120.0, 80.0, 2, 10.0, 190.0, appliance_id="microwave")
FAST = HoldTiming(poll_s=0.01, stop_confirm_s=0.15, max_hold_s=30.0, press_gap_s=0.0)


class Recorder:
    def __init__(self):
        self.events: list[dict] = []
        self._lock = threading.Lock()

    def __call__(self, doc):
        with self._lock:
            self.events.append(doc)

    def states(self):
        with self._lock:
            out = []
            for e in self.events:
                if not out or out[-1] != e["hold_state"]:
                    out.append(e["hold_state"])
            return out


def wait_for(pred, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False


def session(probe, motion=None, timing=FAST, plan=PLAN):
    motion = motion or MockHoldMotion()
    rec = Recorder()
    s = StopHoldSession(plan, motion, probe, rec, timing=timing, start_position=(40.0, 60.0))
    s.start()
    assert wait_for(lambda: s.snapshot()["sim_phase"] == "waiting_above_stop" or not s.active)
    return s, motion, rec


def test_hover_then_stop_presses_n_times_confirms_off_then_parks():
    s, motion, rec = session(MockApplianceRun(30, presses_needed=2))
    assert s.snapshot()["hold_state"] == "hovering_stop"
    assert motion.moves() == [(120.0, 80.0)] and motion.presses() == []

    assert s.request_appliance_stop() == "accepted"
    assert s.request_appliance_stop() == "duplicate"  # 같은 요청으로 두 번 누르지 않는다
    assert s.join(5)

    snap = s.snapshot()
    assert snap["hold_state"] == "parked"
    assert snap["stop_outcome"] == "stopped"
    assert snap["park_reason"] == "stop_confirmed"
    assert snap["presses_done"] == 2
    assert motion.presses() == ["취소", "취소"]
    assert motion.moves() == [(120.0, 80.0), (10.0, 190.0)]
    assert rec.states() == ["hovering_stop", "stopping", "parking", "parked"]
    assert "연습 결과" in snap["detail"]


def test_appliance_that_ignores_stop_is_requested_unconfirmed_and_never_repressed():
    probe = MockApplianceRun(30, honors_stop=False, presses_needed=2)
    s, motion, rec = session(probe)
    s.request_appliance_stop()
    assert wait_for(lambda: s.snapshot()["stop_outcome"] == "requested_unconfirmed")
    snap = s.snapshot()
    assert snap["hold_state"] == "hovering_stop"  # 정지 버튼 위에서 계속 기다린다
    assert "가전이 멈췄는지 확인하지 못했어요" in snap["detail"]
    assert s.request_appliance_stop() == "duplicate"
    time.sleep(0.1)
    assert motion.presses() == ["취소", "취소"]
    assert s.active
    s.release()
    assert s.join(5)
    assert s.snapshot()["hold_state"] == "released"


def test_natural_finish_parks_without_pressing():
    s, motion, _ = session(MockApplianceRun(0.2))
    assert s.join(5)
    snap = s.snapshot()
    assert snap["hold_state"] == "parked" and snap["park_reason"] == "appliance_finished"
    assert snap["stop_outcome"] is None and motion.presses() == []
    assert motion.moves()[-1] == (10.0, 190.0)


def test_drive_fault_reports_the_appliance_could_not_be_stopped_by_button():
    motion = MockHoldMotion()
    s, motion, _ = session(MockApplianceRun(30), motion)
    motion.fault = "모터 드라이버 경보"
    s.request_appliance_stop()
    assert s.join(5)
    snap = s.snapshot()
    assert snap["hold_state"] == "fault"
    assert snap["stop_outcome"] == "drive_fault"
    assert snap["detail"] == DETAIL_DRIVE_FAULT
    assert motion.moves() == [(120.0, 80.0)]  # 보관 위치로 자동 이동하지 않는다


def test_drive_stop_is_not_an_appliance_stop():
    s, motion, _ = session(MockApplianceRun(30))
    s.drive_stop()
    assert s.join(5)
    snap = s.snapshot()
    assert snap["hold_state"] == "fault" and snap["stop_outcome"] is None
    assert motion.presses() == []
    assert s.request_appliance_stop() == "not_holding"


def test_stop_after_drive_stop_while_moving_is_drive_fault():
    motion = MockHoldMotion(step_seconds=0.5)
    rec = Recorder()
    s = StopHoldSession(PLAN, motion, MockApplianceRun(30), rec, timing=FAST)
    s.start()
    time.sleep(0.05)  # 정지 버튼으로 가는 중
    s.request_appliance_stop()
    s.drive_stop()
    assert s.join(5)
    snap = s.snapshot()
    assert snap["hold_state"] == "fault"
    assert motion.presses() == []


def test_no_power_reader_means_unconfirmed_and_timeout_parks():
    timing = HoldTiming(poll_s=0.01, stop_confirm_s=0.05, max_hold_s=0.4, press_gap_s=0.0)
    s, motion, _ = session(NoRunProbe(), timing=timing)
    s.request_appliance_stop()
    assert s.join(5)
    snap = s.snapshot()
    assert snap["stop_outcome"] == "requested_unconfirmed"
    assert snap["hold_state"] == "parked" and snap["park_reason"] == "hold_timeout"
    assert "가전이 끝났는지는 확인하지 못했어요" in snap["detail"]


def test_mm_points_and_free_park_edge_reuse_the_parking_model():
    mapping = Mapping(MmPoint(120, 80), MmPoint(10, 190), "free")
    assert mapping.park == MmPoint(10, 190)
    with pytest.raises(ValueError):
        MmPoint(-1, 3)
    with pytest.raises(ValueError):
        Mapping(Point(.8, .7), Point(.5, .5), "top")  # 기존 모서리 규칙은 그대로


def test_verify_pass_moves_only_and_stops_after_a_failure():
    motion = MockHoldMotion()
    events = []
    targets = [VerifyTarget("시작", 10, 10), VerifyTarget("취소", 20, 10), VerifyTarget("보관 위치", 5, 190, "park")]
    results = run_verify_pass(motion, targets, events.append)
    assert [r["status"] for r in results] == ["reached"] * 3
    assert motion.presses() == [] and motion.moves() == [(10, 10), (20, 10), (5, 190)]

    motion = MockHoldMotion()
    calls = []
    original = motion.move_to

    def flaky(x, y):
        calls.append((x, y))
        if len(calls) == 2:
            raise RuntimeError("소프트 리밋 밖")
        original(x, y)

    motion.move_to = flaky
    results = run_verify_pass(motion, targets, events.append)
    assert [r["status"] for r in results] == ["reached", "failed", "skipped"]
    assert "소프트 리밋" in results[1]["detail"]


def test_messages_parse_hold_scope_and_verify_strictly():
    ok = parse_act_message(
        '{"type":"execute","appliance_id":"microwave","sequence_id":"s1","buttons":["시작"],'
        '"hold":{"stop_button":"취소","stop_x_mm":1,"stop_y_mm":2,"stop_presses":2,"park_x_mm":3,"park_y_mm":4}}')
    assert ok.hold == HoldPlan("취소", 1.0, 2.0, 2, 3.0, 4.0, None, "microwave")  # 대상으로 채운다(2026-10-07)
    bad_presses = ('{"type":"execute","appliance_id":"microwave","sequence_id":"s1","buttons":["시작"],"hold":{"stop_button":"취소",'
                   '"stop_x_mm":1,"stop_y_mm":2,"stop_presses":4,"park_x_mm":3,"park_y_mm":4}}')
    assert parse_act_message(bad_presses) is None
    same_spot = bad_presses.replace('"stop_presses":4', '"stop_presses":1').replace('"park_x_mm":3,"park_y_mm":4',
                                                                                    '"park_x_mm":1,"park_y_mm":2')
    assert parse_act_message(same_spot) is None
    assert parse_act_message('{"type":"abort"}').scope == "appliance"
    assert parse_act_message('{"type":"abort","scope":"drive"}').scope == "drive"
    assert parse_act_message('{"type":"abort","scope":"all"}') is None
    verify = parse_act_message('{"type":"verify_pass","sequence_id":"v","targets":[{"button":"a","x_mm":1,"y_mm":2}]}')
    assert verify.targets == (VerifyTarget("a", 1.0, 2.0),)
    assert parse_act_message('{"type":"verify_pass","sequence_id":"v","targets":[]}') is None


def test_power_drop_after_the_confirm_window_is_reported_as_late():
    probe = MockApplianceRun(0.6, honors_stop=False, presses_needed=2)
    s, motion, _ = session(probe)
    s.request_appliance_stop()
    assert wait_for(lambda: s.snapshot()["stop_outcome"] == "requested_unconfirmed")
    assert s.join(5)
    snap = s.snapshot()
    assert snap["stop_outcome"] == "stopped" and snap["hold_state"] == "parked"
    assert "스스로 끝났을 수도" in snap["detail"]
