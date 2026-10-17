"""G3(안전 계약 적용 보고 2026-10-15 §2, PS-1 S6) — 루틴 구간 사이 정지가 다음 구간으로 이어지지 않는다.

수리 전 세 군데가 비어 있었다(보고서 근거, 코드 기준):

1. ``POST /stop``이 루틴 취소를 **맨 마지막**에 세웠다 — 그 앞의 실행 정지가 RPi4 정지 보고를 기다리는 동안(최대 수 초)
   루틴 스레드는 취소 표시를 못 보고 다음 구간을 보냈다.
2. 루틴은 '다른 작업이 끝나기를' 기다린 **뒤에** 정지를 다시 보지 않고 다음 구간을 보냈다.
3. 다음 구간의 실행 시작(``_begin_run``)이 정지 기록을 지운다 — 쉬는 중에 온 정지는 실행 기록이 아니라 루틴 취소 표시에만
   남는데, 마지막 확인과 실행 시작 사이에 온 정지는 아무도 보지 않았다.

또 구간이 '정지 요청이 있었지만 버튼은 다 눌림'(``succeeded`` + ``stop_requested``)으로 끝나면 루틴은 ``succeeded``로 적혔고,
구간이 ``stopped``로 끝나도 문장은 '앞 단계가 확인되지 않아 멈췄어요'였다.

'구간'은 한 번의 실행(``execute_approved``)이다 — 안내·기다림 없이 이어진 장치 단계는 한 구간으로 묶이므로(그 안의 단계 사이
정지는 G2·실행 서비스가 막는다) 구간 사이 시험은 안내 단계를 끼운다.

수리 뒤: 정지 뒤에는 다음 구간·단계를 보내지 않고, 루틴은 ``stopped``·정지 문장(``STOP_DETAIL``)으로 끝난다.
실행 대상은 가짜 — **실물 미검증**(PS-1 S6은 보드에서 다시 본다).
"""

from __future__ import annotations

import asyncio
import threading
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from rpi.api import SimpleLayService
from rpi.api.router import emergency_stop
from rpi.commands import ApprovedCommand, CommandStatus
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.routines import RoutineRunner, RoutineStore, RunStatus, build_routine, compile_commands
from rpi.routines import wiring
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.tests.test_routines import ScriptedService, _result, _runner_setup

NOW = datetime(2026, 10, 16, 19, tzinfo=timezone(timedelta(hours=9)))
HEAT = {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["BT-08", "시작"]}
INDUCTION = {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]}
ANNOUNCE = {"kind": "announce", "text": "인덕션도 켤게요"}
#: ``POST /stop``으로 멈춘 루틴 문장(10/18 쉬운 말 — 사유는 ``stop_reason``에 남고 문장은 사람 말로).
STOP_DETAIL = "멈추기를 눌러서 남은 할 일을 하지 않았어요."
#: 루틴 취소 표시 없이 구간 결과로만 정지를 안 경우의 기존 기본 문장. 첫 구간 중에는 루틴이 아직 목록에 없어(첫 구간을
#: 접수한 뒤 등록) ``POST /stop``의 루틴 취소가 닿지 않는다 — 그 정지는 구간 결과(``stop_requested``)로 안다.
DEFAULT_STOP_DETAIL = "루틴을 멈춰서 남은 할 일을 하지 않았어요."


class _Recorder:
    """누른 버튼을 적고 다 눌렀다고 답한다. ``on_execute``가 있으면 누르는 동안 부른다(정지가 그때 온 경우)."""

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


class _Care:
    def __init__(self) -> None:
        self.events: list[tuple[str, str]] = []
        self.on_append = None

    def append(self, kind, message, purpose=None, time_band=None):
        self.events.append((kind, message))
        if self.on_append is not None:
            hook, self.on_append = self.on_append, None
            hook()


def _routine_setup(*steps, on_finished=None):
    controller = _Recorder()
    service = SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW))
    store = RoutineStore()
    routine = store.save(build_routine({"name": "저녁 두 가전", "steps": list(steps), "trigger": {"kind": "manual"}},
                                       routine_id="rt-g3", now=NOW))
    approved = tuple(ApprovedCommand(c, "card-g3", NOW, "요약", NOW + timedelta(minutes=15))
                     for c in compile_commands(routine, ApplianceRegistry()))
    care = _Care()
    runner = RoutineRunner(store, service, FixedClock(NOW), care, on_finished=on_finished,
                           poll_seconds=0, sleep=lambda s: None)
    return controller, service, runner, routine, approved, care


@pytest.fixture()
def wired(monkeypatch):
    """``POST /stop``이 이 시험의 루틴 러너를 찾게 한다(자동 실행 엔진은 없음)."""
    def wire(runner):
        monkeypatch.setattr(wiring, "_engine", SimpleNamespace(runner=runner))
        monkeypatch.setattr(wiring, "_auto_engine", None)
    return wire


def test_stop_endpoint_cancels_the_routine_before_waiting_for_the_stop_report(wired):
    """S6 모양: 첫 구간이 끝나고 다음 구간 전(안내 기록 중)에 ``POST /stop``. 실행 정지 쪽은 RPi4 정지 보고를 기다리느라
    늦다 — 그 사이 루틴이 다음 구간을 보내면 안 된다. 수리 전에는 루틴 취소가 그 기다림 **뒤**라 인덕션을 눌렀다."""
    finished = threading.Event()
    controller, service, runner, routine, approved, care = _routine_setup(
        HEAT, ANNOUNCE, INDUCTION, on_finished=lambda run: finished.set())
    wired(runner)
    entered = threading.Event()
    original_report = service.emergency_stop_report

    def slow_report():
        # 실행 정지(RPi4 정지 보고 기다림)가 늦는 경우 — 루틴이 끝나거나 2초가 지날 때까지 붙든다.
        entered.set()
        finished.wait(2.0)
        return original_report()

    service.emergency_stop_report = slow_report  # type: ignore[method-assign]
    stop_thread = threading.Thread(target=lambda: asyncio.run(emergency_stop(service=service)), daemon=True)

    def stop_between_segments():
        stop_thread.start()
        assert entered.wait(2.0)  # /stop이 실행 정지에 들어갔다(루틴 쪽은 이때 무엇을 보느냐가 시험)

    care.on_append = stop_between_segments
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    stop_thread.join(5.0)

    assert controller.calls == [tuple(approved[0].command.buttons)]  # 인덕션은 보내지 않았다
    assert run.status is RunStatus.STOPPED
    assert run.detail == STOP_DETAIL


def test_stop_while_waiting_for_another_command_sends_nothing_more():
    """다음 구간 전에 다른 명령이 끝나기를 기다리는 동안 정지 — 기다림이 끝나도 다음 구간을 보내지 않는다."""
    runner, routine, approved, service, _care = _runner_setup(
        [lambda c: _result(c), lambda c: _result(c)], [HEAT, ANNOUNCE, INDUCTION])
    busy = {"polls": 2}
    plain_status = service.status

    def status():
        snap = plain_status()
        if service.calls and busy["polls"] > 0:  # 첫 구간 뒤 잠깐 다른 사용자 명령이 돈다
            busy["polls"] -= 1
            snap.running = True
        return snap

    service.status = status  # type: ignore[method-assign]
    runner._sleep = lambda s: runner.stop_all("긴급 정지 요청")  # 기다리는 사이에 POST /stop

    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())

    assert len(service.calls) == 1
    assert run.status is RunStatus.STOPPED and run.detail == STOP_DETAIL


def test_stop_right_before_the_next_segment_starts_is_not_erased_by_the_run_start():
    """마지막 확인 뒤·다음 구간 실행 시작 전에 온 정지. 서비스는 쉬는 중이라 실행 정지 기록이 없고(``was_running`` 거짓),
    실행 시작이 정지 표시를 지운다 — 루틴 취소 표시를 실행 시작이 같은 잠금 안에서 봐야 한다."""
    controller, service, runner, routine, approved, _care = _routine_setup(HEAT, ANNOUNCE, INDUCTION)
    original_begin = service._begin_run
    begins = {"n": 0}

    def begin_run(*args, **kwargs):
        begins["n"] += 1
        if begins["n"] == 2:  # 인덕션 구간의 실행 시작 — 바로 앞에서 POST /stop(루틴 취소 → 실행 정지 순서)
            runner.stop_all("긴급 정지 요청")
            service.emergency_stop_report()
        return original_begin(*args, **kwargs)

    service._begin_run = begin_run  # type: ignore[method-assign]
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())

    assert controller.calls == [tuple(approved[0].command.buttons)]
    assert run.status is RunStatus.STOPPED and run.detail == STOP_DETAIL
    assert service.status().running is False  # 막힌 실행 시작이 실행 중 표시·제어권을 남기지 않는다


def test_segment_that_ends_with_a_stop_is_recorded_as_stopped_not_success(wired):
    """정지가 첫 구간의 마지막 누름 중에 와서 버튼은 다 눌렸다(``succeeded`` + ``stop_requested``). 루틴은 성공이 아니다."""
    controller, service, runner, routine, approved, _care = _routine_setup(HEAT, ANNOUNCE, INDUCTION)
    wired(runner)
    controller.on_execute = lambda: asyncio.run(emergency_stop(service=service))

    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())

    assert controller.calls == [tuple(approved[0].command.buttons)]
    record_status = run.steps[0]["status"]
    assert record_status == CommandStatus.SUCCEEDED.value  # 구간 자체는 다 눌렀다(사실 그대로)
    assert run.status is RunStatus.STOPPED
    assert run.detail == DEFAULT_STOP_DETAIL


def test_stop_inside_a_two_device_segment_says_it_was_a_stop():
    """안내 없이 이어진 두 장치는 한 구간(한 번의 실행)이다 — 전자레인지 누름 중 정지면 인덕션은 실행 안에서 보내지 않는다
    (G2·단계 사이 정지 기록). 루틴 문장도 '앞 단계 미확인'이 아니라 정지 문장이어야 한다."""
    controller, service, runner, routine, approved, _care = _routine_setup(HEAT, INDUCTION)
    controller.on_execute = lambda: (runner.stop_all("긴급 정지 요청"), service.emergency_stop_report())

    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())

    assert controller.calls == [tuple(approved[0].command.buttons)]
    assert [s["status"] for s in run.steps] == ["succeeded", "stopped"]
    assert run.status is RunStatus.STOPPED
    assert run.detail == DEFAULT_STOP_DETAIL


def test_scripted_segment_with_stop_flag_does_not_make_the_routine_succeed():
    """같은 규칙을 서비스 흉내로 — 루틴 취소 표시 없이 구간 결과의 정지 표시만 있어도 ``stopped``(기본 정지 문장)."""
    runner, routine, approved, service, _ = _runner_setup(
        [lambda c: _result(c, stop=True), lambda c: _result(c)], [HEAT, ANNOUNCE, INDUCTION])
    assert isinstance(service, ScriptedService)
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert len(service.calls) == 1
    assert run.status is RunStatus.STOPPED
    assert run.detail == DEFAULT_STOP_DETAIL
