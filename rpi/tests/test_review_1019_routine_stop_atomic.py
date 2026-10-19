"""검토 2026-10-19: 루틴 정지의 '내 실행인가' 확인과 긴급 정지 등록이 한 잠금 안에 있지 않았다.

루틴 정지(``RoutineRunner.stop``)가 ``status()``로 실행 번호를 읽고 서비스 잠금을 놓은 뒤 ``emergency_stop_report()``가
잠금을 다시 잡았다. 그 사이 루틴 구간이 끝나고 다른 클라이언트의 실행이 시작되면 루틴 정지가 그 실행을 멈췄다.
이제 서비스의 ``stop_if_owned``가 확인과 정지 등록을 한 잠금 안에서 한다. 실행 대상은 가짜 — 실물 미검증.
"""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone

from rpi.api import SimpleLayService
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.routines import RoutineRunner, RoutineStore
from rpi.routines.runner import RoutineRun

NOW = datetime(2026, 10, 19, 19, tzinfo=timezone(timedelta(hours=9)))


class _Controller:
    """정지 요청이 닿은 순간의 실행 번호를 적는다."""

    def __init__(self) -> None:
        self.service: SimpleLayService | None = None
        self.stopped_jobs: list[str | None] = []

    def execute(self, buttons, targets=None):  # pragma: no cover - 이 시험은 실행하지 않는다
        raise AssertionError("not used")

    def request_stop(self):
        self.stopped_jobs.append(self.service._current_job_id)


class _FlipOnFirstRelease:
    """서비스 잠금 흉내 — 처음 놓일 때 루틴 구간(job-A)이 끝나고 다른 실행(job-B)이 시작된 것처럼 바꾼다."""

    def __init__(self, service: SimpleLayService) -> None:
        self._inner = threading.Lock()
        self._service = service
        self._flipped = False

    def acquire(self, *args, **kwargs):
        return self._inner.acquire(*args, **kwargs)

    def release(self):
        flip = not self._flipped
        self._flipped = True
        if flip:
            self._service._last_job_id = self._service._current_job_id
            self._service._current_job_id = "job-B"
        self._inner.release()

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()
        return False


def _service(running: bool, job_id: str | None, last_job_id: str | None = None):
    controller = _Controller()
    service = SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW))
    controller.service = service
    service._running = running
    service._current_job_id = job_id
    service._last_job_id = last_job_id
    return service, controller


def test_routine_stop_does_not_stop_a_job_that_started_between_check_and_stop():
    service, controller = _service(True, "job-A")
    runner = RoutineRunner(RoutineStore(), service, FixedClock(NOW), poll_seconds=0, sleep=lambda s: None)
    run = RoutineRun(run_id="job-A", routine_id="rt-a", routine_name="저녁", scenario_id="s", started_at=NOW,
                     active=True, active_job_id="job-A")
    runner._runs.append(run)
    service._lock = _FlipOnFirstRelease(service)  # type: ignore[assignment]

    assert runner.stop("job-A") is True
    assert "job-B" not in controller.stopped_jobs
    assert controller.stopped_jobs in ([], ["job-A"])


def test_stop_if_owned_skips_other_jobs_and_idle():
    service, controller = _service(True, "job-B", last_job_id="job-A")
    assert service.stop_if_owned(expected_job_id="job-A") is None
    assert service.stop_if_owned(fence="job-0") is None
    assert service.stop_if_owned() is None
    assert controller.stopped_jobs == []
    assert service._stop_requested_this_run is False

    idle, idle_controller = _service(False, None, last_job_id="job-A")
    assert idle.stop_if_owned(fence="job-A") is None
    assert idle_controller.stopped_jobs == []


def test_stop_if_owned_stops_its_own_job_by_id_or_fence():
    service, controller = _service(True, "job-A", last_job_id="job-0")
    report = service.stop_if_owned(expected_job_id="job-A")
    assert report is not None and report.was_running and report.job_id == "job-A"
    assert controller.stopped_jobs == ["job-A"]

    fenced, fenced_controller = _service(True, "job-C", last_job_id=None)
    report = fenced.stop_if_owned(fence=None)  # 앞선 실행이 없을 때의 울타리(None)도 소유로 본다
    assert report is not None and report.job_id == "job-C"
    assert fenced_controller.stopped_jobs == ["job-C"]
