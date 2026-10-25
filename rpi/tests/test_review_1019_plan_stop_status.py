"""외부 검토 2026-10-19: 여러 단계 실행에서 정지로 보내지 않은 단계가 /status·이력에 이 실행의 결과로 보인다.

예전에는 단계 사이 정지(또는 보내기 전 정지)로 만든 '멈춤·보내지 않음' 결과를 실행 기록(RunRecord)에만 넣었다.
/status의 ``last_status``·수신·문장·이력은 첫 단계 성공(또는 직전 실행)을 그대로 보였고, 보내지 않은 단계가 표시 대상·경로를
덮어써 누르지 않은 가전이 '마지막 실행 가전'으로 보였다. 실행 대상은 가짜 — 실물 미검증.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from rpi.api import SimpleLayService
from rpi.api.router import command_status_fields, status_event_payload
from rpi.commands import ApprovedCommand, CommandStatus
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.routines import build_routine, compile_commands
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.services.history import InMemoryJobHistory

NOW = datetime(2026, 10, 19, 19, tzinfo=timezone(timedelta(hours=9)))
HEAT = {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["BT-08", "시작"]}
INDUCTION = {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]}


class _Recorder:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.on_execute = None

    def execute(self, buttons, targets=None):
        self.calls.append(tuple(buttons))
        if self.on_execute is not None:
            hook, self.on_execute = self.on_execute, None
            hook()
        return ExecutionResult(ExecutionStatus.SUCCEEDED,
                               tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons))


def _setup():
    controller = _Recorder()
    history = InMemoryJobHistory()
    service = SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW), history_store=history)
    routine = build_routine({"name": "두 가전", "steps": [HEAT, INDUCTION], "trigger": {"kind": "manual"}},
                            routine_id="rt-x", now=NOW)
    approved = tuple(ApprovedCommand(c, "card-x", NOW, "요약", NOW + timedelta(minutes=15))
                     for c in compile_commands(routine, ApplianceRegistry()))
    return controller, service, history, approved


def test_stop_between_steps_is_this_jobs_public_status_and_keeps_dispatched_target():
    controller, service, history, approved = _setup()
    controller.on_execute = service.emergency_stop_report  # 첫 단계를 누르는 중 /stop

    record = service.execute_approved(approved)

    assert controller.calls == [tuple(approved[0].command.buttons)]
    assert [r.status for r in record.results] == [CommandStatus.SUCCEEDED, CommandStatus.STOPPED]
    snap = service.status()
    assert snap.last_job_id == record.job_id
    # 보내지 않은 인덕션 단계가 표시 대상을 덮어쓰지 않는다
    assert snap.last_appliance_id == "microwave"
    payload = status_event_payload(service)
    assert payload["last_outcome"] == "stopped", payload
    assert payload["last_receipt"] == "not_dispatched"
    assert payload["last_detail"] == "정지를 눌러서 보내지 않았어요."
    entries = history.recent()
    assert any(e.status == CommandStatus.STOPPED.value and e.appliance_id == "induction" for e in entries), entries


def test_stop_before_the_first_step_is_dispatched_replaces_the_previous_jobs_status():
    controller, service, history, approved = _setup()
    service.execute_approved(approved[:1])  # 직전 실행: 성공
    original_begin = service._begin_run

    def begin_then_stop(*args, **kwargs):
        job_id = original_begin(*args, **kwargs)
        service.emergency_stop_report()  # 접수 직후·보내기 전 /stop
        return job_id

    service._begin_run = begin_then_stop  # type: ignore[method-assign]
    record = service.execute_approved(approved[1:])

    assert [r.status for r in record.results] == [CommandStatus.STOPPED]
    assert controller.calls == [tuple(approved[0].command.buttons)]
    snap = service.status()
    assert snap.last_job_id == record.job_id
    payload = status_event_payload(service)
    assert payload["last_outcome"] == "stopped", payload
    assert payload["last_receipt"] == "not_dispatched"
    assert command_status_fields(snap)["last_detail"] == "정지를 눌러서 보내지 않았어요."
