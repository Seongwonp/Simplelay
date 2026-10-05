"""시연 v3 갭 M2 — 루틴 ``wait_until_done``이 '시작 확인'이 아니라 가전 **사이클 끝**을 기다린다(2026-10-06).

끝 판정은 RPi4가 그 가전의 CT 채널 전력 하강(`rpi/verifier/cycle_end.py`)으로 보내는 ``appliance_done``이다.
RPi5는 끝 센서가 있는 가전(``SIMPLELAY_ROUTINE_DONE_SENSORS``)이면 정해 둔 시간까지 기다리고, 없거나 모의 실행이면
지금처럼 넘어가되 단계에 "시작만 확인 — 끝남 판정 센서 없음"이라고 적는다. 실물 미검증(합성 기록만).
"""

from __future__ import annotations

import threading
import time

import pytest

from rpi.commands import Confirmation
from rpi.controller.models import ExecutionMode
from rpi.routines import RunStatus
from rpi.routines.runner import routine_done_settings_from_env
from rpi.services.appliance_done import ApplianceDoneLog, parse_appliance_done
from rpi.tests.test_routines import (
    HEAT,
    INDUCTION,
    _engine,
    _event,
    _result,
    _runner_setup,
    _save,
)

WAIT_MW = {"kind": "wait_until_done", "appliance_id": "microwave"}


def _done(appliance="microwave", source="real", inputs=("power",)):
    state = "done_confirmed" if len(inputs) == 2 else f"done_{inputs[0]}_only"
    record = parse_appliance_done({"type": "appliance_done", "appliance_id": appliance,
                                   "event": "heat_complete", "state": state, "inputs": list(inputs),
                                   "source": source, "evidence": {"power": {"run_s": 120.0}}})
    assert record is not None
    return record


def _confirmed(c):
    return _result(c, confirmation=Confirmation.OPERATION_CONFIRMED)


def _setup(outcomes, steps, **runner_kw):
    runner, routine, approved, service, care = _runner_setup(outcomes, steps)
    for name, value in runner_kw.items():
        setattr(runner, name, value)
    return runner, routine, approved, service, care


def _later(fn, delay=0.05):
    timer = threading.Timer(delay, fn)
    timer.start()
    return timer


def test_waits_for_cycle_end_before_the_next_step():
    log = ApplianceDoneLog()
    runner, routine, approved, service, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    seen_calls = []
    _later(lambda: (seen_calls.append(len(service.calls)), log.append(_done())))
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert seen_calls == [1]  # 끝이 오기 전에는 인덕션 단계를 보내지 않았다
    assert run.status is RunStatus.SUCCEEDED and len(service.calls) == 2
    wait = run.steps[1]
    assert wait["kind"] == "wait_until_done" and wait["status"] == "passed"
    assert wait["basis"] == "cycle_end"
    assert "끝" in wait["detail"] and "전력" in wait["detail"]


def test_cycle_end_timeout_stops_the_routine_unconfirmed():
    log = ApplianceDoneLog()
    runner, routine, approved, service, care = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=0.1)
    log.append(_done(appliance="washer"))  # 다른 가전의 끝은 세지 않는다
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.UNCONFIRMED and len(service.calls) == 1
    assert run.steps[1]["status"] == "not_confirmed" and run.steps[1]["basis"] == "cycle_end"
    assert care.events[-1][0] == "routine_stopped"


def test_done_record_from_before_the_segment_does_not_count():
    log = ApplianceDoneLog()
    log.append(_done())  # 지난 가열의 끝(구간 제출 전)
    runner, routine, approved, service, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=0.1)
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.UNCONFIRMED and len(service.calls) == 1


def test_stop_while_waiting_ends_the_run_stopped():
    log = ApplianceDoneLog()
    runner, routine, approved, service, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    _later(lambda: runner.stop(runner.runs()[0].run_id), delay=0.1)
    started = time.monotonic()
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert time.monotonic() - started < 3.0
    assert run.status is RunStatus.STOPPED and len(service.calls) == 1


def test_injected_or_mock_done_marks_the_run_as_demo():
    log = ApplianceDoneLog()
    runner, routine, approved, _, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    _later(lambda: log.append(_done(source="injected")))
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.SUCCEEDED and run.is_demo
    assert "시연 주입" in run.steps[1]["detail"]


def test_without_an_end_sensor_start_confirmation_passes_but_says_so():
    runner, routine, approved, service, _ = _runner_setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION])
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.SUCCEEDED and len(service.calls) == 2
    assert run.steps[1]["basis"] == "start_only"
    assert run.steps[1]["detail"] == "시작만 확인 — 끝남 판정 센서 없음"


def test_mock_run_passes_immediately_even_with_a_sensor_and_says_so():
    log = ApplianceDoneLog()
    runner, routine, approved, _, _ = _setup(
        [lambda c: _result(c, mode=ExecutionMode.MOCK), lambda c: _result(c, mode=ExecutionMode.MOCK)],
        [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    started = time.monotonic()
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert time.monotonic() - started < 1.0
    assert run.status is RunStatus.SUCCEEDED and run.is_demo
    assert run.steps[1]["basis"] == "mock"
    assert run.steps[1]["detail"].startswith("시연:") and "시작만 확인 — 끝남 판정 센서 없음" in run.steps[1]["detail"]


def test_settings_from_env():
    assert routine_done_settings_from_env({}) == (frozenset(), 1200.0)
    assert routine_done_settings_from_env({"SIMPLELAY_ROUTINE_DONE_SENSORS": " microwave , washer ",
                                           "SIMPLELAY_ROUTINE_DONE_TIMEOUT_S": "600"}) == (
        frozenset({"microwave", "washer"}), 600.0)
    for bad in ({"SIMPLELAY_ROUTINE_DONE_TIMEOUT_S": "0"}, {"SIMPLELAY_ROUTINE_DONE_TIMEOUT_S": "x"},
                {"SIMPLELAY_ROUTINE_DONE_SENSORS": "micro wave"}):
        with pytest.raises(RuntimeError):
            routine_done_settings_from_env(bad)


def test_after_done_waits_for_the_cycle_end_when_the_appliance_has_an_end_sensor():
    """끝 센서가 있는 가전의 after_done은 시작 확인(L3)이 아니라 appliance_done에서 한 번만 깨어난다."""
    engine, store, suggestions, *_ = _engine(done_sensors=frozenset({"microwave"}))
    _save(store, engine._clock, name="데운 뒤", trigger={"kind": "after_done", "appliance_id": "microwave"})
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED))
    assert suggestions.cards == []
    engine.on_appliance_done(_done())
    assert len(suggestions.cards) == 1


def test_rehearsal_done_event_uses_the_appliance_event_name():
    """전자레인지 끝 주입이 '세탁 끝 알림'(wash_complete) 루틴을 깨우지 않게 가전마다 이벤트 이름을 나눈다."""
    from rpi.verifier.done_fusion import done_event_for, rehearsal_done_event

    assert rehearsal_done_event("microwave", ["power"], now_s=1.0).event == "heat_complete"
    assert rehearsal_done_event("washer", ["power"], now_s=1.0).event == "wash_complete"
    assert done_event_for("Rice-Cooker") == "rice_cooker_done"
    assert done_event_for("9x") == "a_9x_done"
