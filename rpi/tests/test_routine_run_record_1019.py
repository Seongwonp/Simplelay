"""검토 10/19 #3의 남은 경합: 루틴이 한 번 확인하는 사이에 다른 실행(J2)이 시작하고 **끝나기까지** 하면, 서비스의
'마지막 기록'이 이미 J2라 루틴이 J1의 기록을 끝내 못 보고 '됐는지 몰라요'로 끝났다(상한 시간까지 기다린 뒤).

이제 서비스가 실행 번호별 최근 기록을 남기고(``run_record``), 루틴은 그것부터 본다.
"""

from __future__ import annotations

import time

from rpi.api.service_commands import RUN_RECORDS_KEPT, CommandExecutionMixin, RunRecord
from rpi.routines import RoutineRunner, RunStatus
from rpi.tests.test_routines import HEAT, FakeCare, _result, _runner_setup, _Status


def test_a_second_job_finishing_within_one_poll_does_not_hide_the_first_record():
    runner, routine, approved, service, care = _runner_setup([lambda c: _result(c)], [HEAT])
    records: dict[str, RunRecord] = {}
    original_run = service._run

    def run_and_remember(approved_commands):
        record = original_run(approved_commands)
        records[record.job_id] = record
        # 같은 순간 다른 실행 J2가 시작해 끝났다 — 마지막 기록·마지막 번호가 모두 J2다.
        service._last = RunRecord("job-other", None, None, record.results, record.summaries)
        return record

    service._run = run_and_remember
    service.run_record = records.get
    runner = RoutineRunner(runner._store, service, runner._clock, care, poll_seconds=0.01,
                           job_timeout_seconds=1.0)
    job_id = runner.submit_approved(approved, scenario_id=routine.scenario_key())
    deadline = time.monotonic() + 5
    while runner.get(job_id).status is RunStatus.RUNNING and time.monotonic() < deadline:
        time.sleep(0.01)
    run = runner.get(job_id)
    assert run.status is RunStatus.SUCCEEDED, run.detail


def test_service_keeps_recent_records_by_job_id_and_bounds_them():
    import threading

    svc = CommandExecutionMixin()
    svc._lock = threading.Lock()
    svc._init_commands()
    first = RunRecord("J1", None, None, (), ())
    with svc._lock:
        svc._remember_run(first)
        svc._remember_run(RunRecord("J2", None, None, (), ()))
    assert svc.last_run().job_id == "J2"
    assert svc.run_record("J1") is first  # J2가 끝나도 J1의 기록은 번호로 찾는다
    assert svc.run_record("nope") is None
    with svc._lock:
        for i in range(RUN_RECORDS_KEPT):
            svc._remember_run(RunRecord(f"K{i}", None, None, (), ()))
    assert svc.run_record("J1") is None  # 오래된 것부터 버린다(크기 상한)
    assert svc.run_record(f"K{RUN_RECORDS_KEPT - 1}") is not None
    assert len(svc._runs_by_job) == RUN_RECORDS_KEPT
