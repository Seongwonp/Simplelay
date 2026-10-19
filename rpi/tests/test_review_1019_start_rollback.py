"""검토 2026-10-19 (B): 시작 게이트(``_begin_run``)가 '실행 중'과 제어권을 잡은 뒤 실행 스레드 시작이 실패하면, 아무것도
누르지 않았는데 서비스가 영영 '바쁨'으로 남았다(모든 실행 거절). 이제 시작 실패는 게이트를 한 번에 되돌린다.

루틴 순서기는 첫 구간을 접수한 뒤 이어 갈 스레드를 띄운다 — 그 시작이 실패하면 예외가 제안 서비스까지 올라가 이미
접수한 승인을 되돌렸다(같은 카드를 다시 승인해 이중 실행). 이제 루틴을 멈춰 끝내고 접수한 실행 번호를 돌려준다.
"""

from __future__ import annotations

import threading

import pytest

from rpi.api import service as service_module
from rpi.api import service_commands as service_commands_module
from rpi.routines import RunStatus
from rpi.routines import runner as runner_module
from rpi.services.control_arbiter import ControlArbiter
from rpi.tests.test_routines import HEAT, _result, _runner_setup
from rpi.tests.test_safety_g3_routine_stop import _routine_setup


class _NoStartThread(threading.Thread):
    def start(self):  # noqa: D401 - 시험 대역
        raise RuntimeError("can't start new thread")


class _ThreadingWithoutStart:
    """그 모듈의 ``threading``만 바꾼다(전역 threading.Thread는 그대로) — 스레드 시작만 실패한다."""

    Thread = _NoStartThread

    def __getattr__(self, name):
        return getattr(threading, name)


def _break_thread_start(monkeypatch, module):
    monkeypatch.setattr(module, "threading", _ThreadingWithoutStart())


def test_button_job_thread_start_failure_rolls_back_the_start_gate(monkeypatch):
    controller, service, runner, routine, approved, care = _routine_setup(HEAT)
    buttons = tuple(approved[0].command.buttons)
    arbiter = ControlArbiter()
    service._control_arbiter = arbiter
    _break_thread_start(monkeypatch, service_module)
    with pytest.raises(RuntimeError, match="can't start"):
        service.submit_buttons(buttons, appliance_id="microwave")
    monkeypatch.undo()

    assert service.status().running is False
    arbiter.acquire(ControlArbiter.DEVELOPER)  # 제어권도 놓였다(아니면 ControlConflictError)
    arbiter.release(ControlArbiter.DEVELOPER)
    # 다음 실행이 바쁨으로 거절되지 않는다.
    job_id = service.submit_buttons(buttons, appliance_id="microwave")
    assert job_id


def test_command_plan_thread_start_failure_rolls_back_the_start_gate(monkeypatch):
    controller, service, runner, routine, approved, care = _routine_setup(HEAT)
    arbiter = ControlArbiter()
    service._control_arbiter = arbiter
    _break_thread_start(monkeypatch, service_commands_module)
    with pytest.raises(RuntimeError, match="can't start"):
        service.submit_approved(approved, scenario_id=routine.scenario_key())
    monkeypatch.undo()

    assert service.status().running is False
    arbiter.acquire(ControlArbiter.DEVELOPER)
    arbiter.release(ControlArbiter.DEVELOPER)
    record = service.execute_approved(approved, scenario_id=routine.scenario_key())
    assert record.job_id
    assert controller.calls == [tuple(approved[0].command.buttons)]  # 실패한 접수는 아무것도 누르지 않았다


def test_routine_continuation_start_failure_finishes_the_run_and_keeps_the_job(monkeypatch):
    runner, routine, approved, service, care = _runner_setup([lambda c: _result(c)], [HEAT])
    stops: list[dict] = []
    service.stop_if_owned = lambda **kw: stops.append(kw)
    _break_thread_start(monkeypatch, runner_module)

    # 첫 구간은 접수됐다 — 예외로 올리면 제안 서비스가 승인을 되돌린다. 접수한 실행 번호를 그대로 돌려줘야 한다.
    job_id = runner.submit_approved(approved, scenario_id=routine.scenario_key())
    assert job_id == "job-1"

    run = runner.get(job_id)
    assert run is not None and run.status is RunStatus.FAILED  # '진행 중'으로 영영 남지 않는다
    assert run.cancel.is_set()
    assert stops == [{"expected_job_id": "job-1"}]  # 지켜볼 수 없는 첫 구간은 멈춘다
    assert care.events[-1][0] == "routine_stopped"
