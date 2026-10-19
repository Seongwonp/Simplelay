"""검토 10/19(클라우드) #6 — 여러 단계 실행에서 보내지 않은 뒷단계(연습·모의)가 ``/status`` 실행 환경을 덮어써, 실제로
보냈을 수 있는 앞단계 실행이 '연습'으로 보이던 것. 실행 환경은 보낸 단계로만 정하고, 실제로 보낸 단계가 있으면 real이다.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from rpi.api import SimpleLayService
from rpi.api.service_commands import _Step
from rpi.commands import CommandStatus
from rpi.controller import ButtonResult, ButtonStatus, ExecutionMode, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.routines import RoutineStore, build_routine, compile_commands
from rpi.services.act_client import ActLinkTimeoutError
from rpi.services.appliance_registry import ApplianceRegistry

NOW = datetime(2026, 10, 19, 19, tzinfo=timezone(timedelta(hours=9)))


# ── #6 보내지 않은 뒷단계가 실행 환경을 덮어쓰지 않는다 ─────────────────────────────


class _Controller:
    def __init__(self, mode: ExecutionMode, *, drops: bool) -> None:
        self.execution_mode = mode
        self.drops = drops
        self.calls: list[tuple[str, ...]] = []

    def execute(self, buttons, targets=None):
        self.calls.append(tuple(buttons))
        if self.drops:
            raise ActLinkTimeoutError("no response within 9.0s")
        return ExecutionResult(ExecutionStatus.SUCCEEDED,
                               tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons))


def _commands():
    routine = RoutineStore().save(build_routine(
        {"name": "묶음", "trigger": {"kind": "manual"}, "steps": [
            {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["BT-08", "시작"]},
            {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]},
        ]}, routine_id="rt-1019", now=NOW))
    return compile_commands(routine, ApplianceRegistry())


def _run(main, first_controller, second_controller):
    service = SimpleLayService(RuleBasedIntentResolver(), main, clock=FixedClock(NOW))
    first, second = _commands()
    steps = [_Step(first, "데우기", first_controller), _Step(second, "인덕션", second_controller)]
    record = service._start_plan(steps, "묶음", "manual", None, None, background=False)
    return service, record


def test_unsent_practice_step_does_not_turn_a_real_run_into_practice():
    real = _Controller(ExecutionMode.REAL, drops=True)      # 실제 — 보냈지만 눌렸는지 모름
    practice = _Controller(ExecutionMode.MOCK, drops=False)  # 모의 — 앞단계 때문에 보내지 않음

    service, record = _run(real, real, practice)

    assert [r.status for r in record.results] == [CommandStatus.UNCONFIRMED, CommandStatus.FAILED]
    assert practice.calls == []
    assert service.status().last_execution_mode is ExecutionMode.REAL


def test_sent_practice_step_after_a_real_step_still_reports_real():
    real = _Controller(ExecutionMode.REAL, drops=False)
    practice = _Controller(ExecutionMode.MOCK, drops=False)

    service, _ = _run(real, real, practice)

    assert practice.calls  # 둘 다 보냈다 — 실제 가전이 바뀌었을 수 있으니 '연습'으로 보이지 않는다
    assert service.status().last_execution_mode is ExecutionMode.REAL


def test_all_practice_steps_still_report_mock():
    practice = _Controller(ExecutionMode.MOCK, drops=False)

    service, _ = _run(practice, practice, practice)

    assert service.status().last_execution_mode is ExecutionMode.MOCK

