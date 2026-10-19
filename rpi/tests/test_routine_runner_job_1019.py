"""외부 검토 2026-10-19 (3): 루틴이 첫 구간(J1)의 끝을 실행 서비스의 '마지막 실행 번호'로만 기다렸다.

J1이 끝난 뒤 루틴이 그것을 보기 전에 다른 실행(J2, 예: 사용자의 직접 명령)이 시작되면, 마지막 실행 번호가 J1이었다가
J2로 넘어가 루틴은 J1의 끝을 끝내 보지 못하고 '됐는지 몰라요'로 끝났다(그동안 상한 3시간을 기다렸다). 이제 J1 자신의
실행 기록(번호가 J1인 기록)이 보이면 그것으로 판단한다.
"""

from __future__ import annotations

import time

from rpi.routines import RoutineRunner, RunStatus
from rpi.tests.test_routines import HEAT, FakeCare, _result, _runner_setup, _Status


def test_another_job_starting_before_the_poll_does_not_hide_the_first_segment():
    runner, routine, approved, service, care = _runner_setup([lambda c: _result(c)], [HEAT])
    polls = {"n": 0}

    def status():
        # J1은 이미 끝났고(기록 있음) 다른 실행 J2가 돌고 있다가 끝난다 — 마지막 실행 번호는 J1을 거치지 않고 J2가 된다.
        polls["n"] += 1
        return _Status(True, "job-1") if polls["n"] < 3 else _Status(False, "job-other")

    service.status = status
    runner = RoutineRunner(runner._store, service, runner._clock, care, poll_seconds=0.01,
                           job_timeout_seconds=1.0)
    job_id = runner.submit_approved(approved, scenario_id=routine.scenario_key())
    deadline = time.monotonic() + 5
    while runner.get(job_id).status is RunStatus.RUNNING and time.monotonic() < deadline:
        time.sleep(0.01)
    run = runner.get(job_id)
    assert run.status is RunStatus.SUCCEEDED, run.detail


def test_record_missing_after_the_job_ended_is_still_unconfirmed():
    """기록이 없는 채 그 실행이 끝났으면(실행 스레드 예외 등) 예전처럼 '됐는지 몰라요'다 — 지어내지 않는다."""
    runner, routine, approved, service, care = _runner_setup([lambda c: _result(c)], [HEAT])
    service.last_run = lambda: None
    runner = RoutineRunner(runner._store, service, runner._clock, FakeCare(), poll_seconds=0.01,
                           job_timeout_seconds=5.0)
    job_id = runner.submit_approved(approved, scenario_id=routine.scenario_key())
    deadline = time.monotonic() + 3
    while runner.get(job_id).status is RunStatus.RUNNING and time.monotonic() < deadline:
        time.sleep(0.01)
    assert runner.get(job_id).status is RunStatus.UNCONFIRMED
