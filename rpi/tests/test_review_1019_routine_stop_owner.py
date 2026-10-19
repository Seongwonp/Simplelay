"""외부 검토 2026-10-19: 루틴 정지(``POST /routines/runs/{id}/stop``)가 상관없는 새 실행을 긴급 정지할 수 있었다.

루틴 구간이 끝난 뒤 순서기가 그것을 알아채기 전(``RoutineRun.active``가 아직 참)에 다른 실행이 시작되면, 루틴 정지가
'지금 실행 중'만 보고 그 실행에 긴급 정지를 보냈다. 이제 그 루틴 구간의 실행일 때만 장치 정지를 보낸다.
가짜 서비스로만 시험.
"""

from __future__ import annotations

import time
from datetime import timedelta
from types import SimpleNamespace

from rpi.api.service import NO_STOP_FENCE
from rpi.api.service_commands import RunRecord
from rpi.commands import ApprovedCommand
from rpi.intent.mock import FixedClock
from rpi.routines import RoutineRunner, RoutineStore, RunStatus, build_routine, compile_commands
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.tests.test_routines import HEAT, THU_0730, _body, _result

ANNOUNCE = {"kind": "announce", "text": "인덕션도 켤게요"}
INDUCTION = {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]}


class _Service:
    def __init__(self) -> None:
        self.state = SimpleNamespace(running=False, job_id=None, last_job_id=None)
        self._last_job_id = None
        self.records: dict[str, RunRecord] = {}
        self.stops = 0
        self.on_execute = None

    def status(self):
        return self.state

    def set(self, *, running, job_id=None, last_job_id=None):
        self.state = SimpleNamespace(running=running, job_id=job_id, last_job_id=last_job_id)
        self._last_job_id = last_job_id

    def _record(self, job_id, approved):
        return RunRecord(job_id, None, None, tuple(_result(a.command) for a in approved),
                         tuple("s" for _ in approved))

    def submit_approved(self, approved, **kw):
        self.pending = self._record("job-1", approved)
        self.set(running=True, job_id="job-1", last_job_id=None)
        return "job-1"

    def execute_approved(self, approved, *, approval_guard=None, **kw):
        if approval_guard is not None:
            approval_guard()
        record = self._record("job-2", approved)
        if self.on_execute is not None:
            self.on_execute()
        self.records["job-2"] = record
        return record

    def run_record(self, job_id):
        return self.records.get(job_id)

    def last_run(self):
        return None

    def emergency_stop_report(self):
        self.stops += 1

    def stop_if_owned(self, *, expected_job_id=None, fence=NO_STOP_FENCE):
        """실제 서비스처럼 소유일 때만 멈춘다(확인과 정지가 한 번에)."""
        state = self.state
        if not state.running:
            return None
        if expected_job_id is not None:
            owned = state.job_id == expected_job_id
        else:
            owned = fence is not NO_STOP_FENCE and state.last_job_id == fence
        if owned:
            self.emergency_stop_report()
        return owned or None


def _setup(steps):
    store = RoutineStore()
    clock = FixedClock(THU_0730)
    routine = store.save(build_routine(_body(steps=steps), routine_id="rt-o", now=clock.now()))
    approved = tuple(ApprovedCommand(c, "card-1", clock.now(), "요약", clock.now() + timedelta(minutes=15))
                     for c in compile_commands(routine, ApplianceRegistry()))
    service = _Service()
    runner = RoutineRunner(store, service, clock, poll_seconds=0.005, sleep=time.sleep)
    return runner, routine, approved, service


def _wait(cond, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if cond():
            return True
        time.sleep(0.005)
    return False


def test_stop_after_first_segment_ended_does_not_stop_an_unrelated_new_job():
    runner, routine, approved, service = _setup([HEAT])
    job_id = runner.submit_approved(approved, scenario_id=routine.scenario_key())
    run = runner.get(job_id)
    assert run is not None and run.active
    # 루틴 첫 구간(job-1)은 끝났고 순서기가 아직 모른다 — 그 사이 상관없는 실행(job-x)이 시작됐다.
    service.set(running=True, job_id="job-x", last_job_id="job-1")

    assert runner.stop(job_id) is True
    assert service.stops == 0

    service.records["job-1"] = service.pending
    assert _wait(lambda: run.status is not RunStatus.RUNNING)


def test_stop_during_the_routines_own_first_segment_still_stops_it():
    runner, routine, approved, service = _setup([HEAT])
    job_id = runner.submit_approved(approved, scenario_id=routine.scenario_key())
    assert runner.stop(job_id) is True
    assert service.stops == 1
    service.records["job-1"] = service.pending
    run = runner.get(job_id)
    assert _wait(lambda: run.status is not RunStatus.RUNNING)


def test_later_segment_stop_only_hits_its_own_job():
    runner, routine, approved, service = _setup([HEAT, ANNOUNCE, INDUCTION])
    seen = {}

    def during_segment():
        # 이 구간의 실행(job-2)이 도는 중: 정지는 이 실행을 멈춘다.
        service.set(running=True, job_id="job-2", last_job_id="job-1")
        runner.stop(seen["run_id"])
        seen["own"] = service.stops
        # job-2가 끝나고 순서기가 돌아오기 전에 상관없는 실행이 시작됐다 — 그 실행은 멈추지 않는다.
        service.set(running=True, job_id="job-x", last_job_id="job-2")
        run = runner.get(seen["run_id"])
        run.status = RunStatus.RUNNING  # 정지 표시만 다시 보려고 상태를 유지한다
        runner.stop(seen["run_id"])
        seen["after"] = service.stops

    service.on_execute = during_segment
    original_submit = service.submit_approved

    def submit(approved, **kw):
        job = original_submit(approved, **kw)
        service.records["job-1"] = service.pending
        service.set(running=False, job_id=None, last_job_id="job-1")
        return job

    service.submit_approved = submit  # type: ignore[method-assign]
    seen["run_id"] = "job-1"
    runner.submit_approved(approved, scenario_id=routine.scenario_key())
    run = runner.get("job-1")
    assert _wait(lambda: run.status is not RunStatus.RUNNING or "after" in seen)
    assert _wait(lambda: "after" in seen)
    assert seen["own"] == 1
    assert seen["after"] == 1
