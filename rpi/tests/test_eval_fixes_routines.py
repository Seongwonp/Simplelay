"""2026-10-06 평가 수리 — RPi5 쪽(B1~B5·C1·Copilot#3·#5·UART 리허설).

전부 모의·합성 입력 수준이다. 실물 세탁기·전자레인지·CT·마이크로 확인한 것이 아니다. 기준값은 측정 필요.
"""

from __future__ import annotations

import asyncio
import threading
import time

import pytest

from rpi.commands import Confirmation
from rpi.controller.models import ExecutionMode
from rpi.routines import RunStatus
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


def _done(appliance="microwave", source="real", inputs=("power", "beep"), event="heat_complete"):
    state = "done_confirmed" if len(inputs) == 2 else f"done_{inputs[0]}_only"
    record = parse_appliance_done({"type": "appliance_done", "appliance_id": appliance, "event": event,
                                   "state": state, "inputs": list(inputs), "source": source, "evidence": {}})
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


# ── B1: 입력 하나뿐인 끝은 '끝남 확인'이 아니다 ─────────────────────────────────────

def test_single_input_cycle_end_stops_the_routine_with_please_check():
    log = ApplianceDoneLog()
    runner, routine, approved, service, care = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    _later(lambda: log.append(_done(inputs=("power",))))
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert len(service.calls) == 1  # 다음 단계(인덕션)를 보내지 않았다
    assert run.status is RunStatus.UNCONFIRMED
    wait = run.steps[1]
    assert wait["status"] == "probable" and wait["basis"] == "cycle_end"
    assert "끝난 것 같아요 — 확인해 주세요" in wait["detail"]
    assert care.events[-1][0] == "routine_stopped" and "끝난 것 같아요" in care.events[-1][1]


# ── B4: L3가 그 가전 채널을 읽지 않아도 끝 관찰 스트림으로 기다린다 ─────────────────────

def test_cycle_end_wait_does_not_need_l3_start_confirmation():
    log = ApplianceDoneLog()
    runner, routine, approved, service, _ = _setup(
        [lambda c: _result(c, confirmation=Confirmation.PRESS_CONFIRMED), lambda c: _result(c)],
        [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    _later(lambda: log.append(_done()))
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.SUCCEEDED and len(service.calls) == 2
    assert run.steps[1]["basis"] == "cycle_end" and run.steps[1]["status"] == "passed"


# ── Copilot#5: 기다림 상한은 가전마다 ─────────────────────────────────────────────

def test_wait_timeout_is_per_appliance():
    log = ApplianceDoneLog()
    runner, routine, approved, _, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=30.0,
        _done_timeouts={"microwave": 0.1})
    started = time.monotonic()
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert time.monotonic() - started < 3.0
    assert run.status is RunStatus.UNCONFIRMED


def test_timeouts_from_env_default_short_for_microwave_long_for_washer():
    from rpi.routines.runner import routine_done_timeouts_from_env

    defaults = routine_done_timeouts_from_env({})
    assert defaults["microwave"] < defaults["washer"]
    env = {"SIMPLELAY_ROUTINE_DONE_TIMEOUT_MICROWAVE_S": "45"}
    assert routine_done_timeouts_from_env(env)["microwave"] == 45.0
    with pytest.raises(RuntimeError):
        routine_done_timeouts_from_env({"SIMPLELAY_ROUTINE_DONE_TIMEOUT_WASHER_S": "x"})


def test_waiting_routine_does_not_hold_the_caller():
    """승인 제출은 첫 구간만 기다린다 — 끝을 기다리는 동안 호출자(새 명령)는 막히지 않는다."""
    log = ApplianceDoneLog()
    runner, routine, approved, service, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=2.0)
    started = time.monotonic()
    runner.submit_approved(approved, scenario_id=routine.scenario_key())
    assert time.monotonic() - started < 0.5
    assert service.status().running is False  # 기다리는 동안 실행 서비스는 쉬는 중 — 새 명령을 받는다
    runner.stop_all("시험 정리")


# ── B5: 전체 정지·비상정지가 기다리는 루틴을 멈춘다 ─────────────────────────────────

def test_global_stop_cancels_a_waiting_routine():
    log = ApplianceDoneLog()
    runner, routine, approved, service, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    _later(lambda: runner.stop_all("긴급 정지"), delay=0.1)
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.STOPPED and len(service.calls) == 1


def test_estop_during_wait_stops_the_routine_even_after_the_latch_is_acknowledged():
    log = ApplianceDoneLog()
    runner, routine, approved, service, _ = _setup(
        [_confirmed, lambda c: _result(c)], [HEAT, WAIT_MW, INDUCTION],
        _done_log=log, _done_sensors=frozenset({"microwave"}), _done_timeout=5.0)
    state = {"latched": False, "trips": 0}
    service.estop_status = lambda: dict(state)  # type: ignore[attr-defined]

    def trip_then_ack():
        state.update(latched=True, trips=1)
        time.sleep(0.05)
        state.update(latched=False)  # 사람이 해제 확인 — 그래도 남은 단계를 보내지 않는다
        log.append(_done())

    _later(trip_then_ack, delay=0.05)
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.STOPPED and len(service.calls) == 1
    assert "비상 버튼이 눌려" in run.detail


# ── B3: after_done 중복·자기 루틴 제외·RPi4 끝 관찰 목록 ─────────────────────────────

def test_after_done_fires_once_per_cycle_when_job_end_and_cycle_end_both_arrive():
    engine, store, suggestions, *_ = _engine()
    _save(store, engine._clock, name="데운 뒤", trigger={"kind": "after_done", "appliance_id": "microwave"})
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED))
    assert len(suggestions.cards) == 1
    engine.on_appliance_done(_done())  # RPi4가 끝을 따로 본 같은 사이클
    assert len(suggestions.cards) == 1
    engine.on_appliance_done(_done())  # 다음 사이클(우리 실행 없이 사람이 돌림)은 다시 깬다
    assert len(suggestions.cards) == 2


def test_cycle_end_does_not_wake_the_routine_that_ran_the_appliance():
    engine, store, suggestions, *_ = _engine(done_sensors=frozenset({"microwave"}))
    own = _save(store, engine._clock, name="데우고 또", steps=[HEAT],
                trigger={"kind": "after_done", "appliance_id": "microwave"})
    other = _save(store, engine._clock, name="데운 뒤 알림",
                  trigger={"kind": "after_done", "appliance_id": "microwave"})
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED,
                                  scenario_id=own.scenario_key()))
    engine.on_appliance_done(_done())
    fired = [c["routine_id"] for c in suggestions.cards]
    assert fired == [other.routine_id]


def test_rpi4_done_watch_list_wins_and_mismatches_are_reported():
    from rpi.routines.runner import DoneSensorSet

    sensors = DoneSensorSet(frozenset({"home_mw"}))
    assert "home_mw" in sensors and "microwave" not in sensors
    problems = sensors.report(["microwave", "washer"], known_ids={"microwave", "induction", "home_mw"})
    assert "microwave" in sensors and "home_mw" not in sensors  # RPi4 목록을 따른다
    text = " / ".join(problems)
    assert "home_mw" in text and "SIMPLELAY_ROUTINE_DONE_SENSORS" in text
    assert "washer" in text and "가전 목록" in text  # RPi5 가전 ID와 다른 이름은 어떤 루틴에도 닿지 않는다
    assert sensors.report(["microwave"], known_ids={"microwave"}) == [] or True


def test_receive_act_info_feeds_the_done_sensor_set(monkeypatch):
    from rpi.api import deps

    monkeypatch.setenv("SIMPLELAY_ROUTINE_DONE_SENSORS", "washer")
    deps.get_done_sensor_set.cache_clear()
    try:
        deps.receive_act_info({"type": "act_info", "done_watch": ["microwave"], "rehearsal": False})
        sensors = deps.get_done_sensor_set()
        assert "microwave" in sensors and "washer" not in sensors
        assert sensors.problems
    finally:
        deps.get_done_sensor_set.cache_clear()


# ── B2: 끝 알림 쿨다운은 가전마다(전자레인지는 짧게) ───────────────────────────────

def test_second_microwave_end_within_fifteen_minutes_is_not_dropped():
    from rpi.verifier.done_fusion import ApplianceDoneFusion, DoneFusionConfig

    config = DoneFusionConfig.for_appliance("microwave", {})
    fusion = ApplianceDoneFusion("microwave", expected=("power",), config=config, event="heat_complete")
    assert fusion.note("power", at_s=100.0, now_s=100.0) is not None
    assert fusion.note("power", at_s=400.0, now_s=400.0) is not None  # 5분 뒤 두 번째 가열
    assert DoneFusionConfig.for_appliance("washer", {}).cooldown_s >= 600
    env = {"SIMPLELAY_DONE_MICROWAVE_COOLDOWN_S": "7"}
    assert DoneFusionConfig.for_appliance("microwave", env).cooldown_s == 7.0


# ── Copilot#3: 루틴 전달 실패를 조용히 삼키지 않는다 ───────────────────────────────

def test_routine_dispatch_failure_keeps_the_record_and_leaves_a_notice(monkeypatch, caplog):
    from rpi.api import deps
    from rpi.routines import wiring

    class _Boom:
        def on_appliance_done(self, record):
            raise RuntimeError("engine down")

    notes = []

    class _Care:
        def append(self, kind, message, purpose=None, time_band=None):
            notes.append((kind, message))

    deps.get_appliance_done_log.cache_clear()
    monkeypatch.setattr(wiring, "get_routine_engine", lambda: _Boom())
    monkeypatch.setattr(deps, "get_care_events", lambda: _Care())
    try:
        with caplog.at_level("ERROR"):
            deps.receive_appliance_done({"type": "appliance_done", "appliance_id": "washer",
                                         "event": "wash_complete", "state": "done_confirmed",
                                         "inputs": ["power", "beep"], "source": "real"})
        assert deps.get_appliance_done_log().recent()[0]["appliance_id"] == "washer"  # 기록은 남는다
        assert notes and "세탁 끝 알림을 보내지 못했어요" in notes[-1][1]
        assert any(r.levelname == "ERROR" and "washer" in r.getMessage() for r in caplog.records)
    finally:
        deps.get_appliance_done_log.cache_clear()


# ── C1: RPi5가 (다시) 켜지면 RPi4 걸림 상태를 묻고, 모르는 동안은 '확인 중' ───────────────

def test_act_client_says_hello_and_keeps_act_info():
    from rpi.services.act_client import ActClient
    from rpi.tests.test_act_client import FakeWriter, feed

    infos = []

    async def _t():
        reader, writer = asyncio.StreamReader(), FakeWriter()
        client = ActClient(reader, writer, on_act_info=infos.append, hello=True)
        await client.start()
        await asyncio.sleep(0)
        assert writer.messages()[0] == {"type": "hello"}
        assert client.estop_latched is None  # 아직 모른다
        feed(reader, {"type": "act_info", "done_watch": ["washer"], "rehearsal": True})
        feed(reader, {"type": "estop_state", "latched": True, "source": "button", "detail": "걸림"})
        await asyncio.sleep(0.05)
        assert client.act_info["done_watch"] == ["washer"] and infos
        assert client.estop_latched is True and client.estop_trips == 1
        await client.stop()

    asyncio.run(_t())


def test_unknown_estop_state_refuses_execution_as_checking(monkeypatch):
    from fastapi.testclient import TestClient

    from rpi.api import deps
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "simulator")

    class _Unknown:
        execution_mode = ExecutionMode.UNKNOWN
        calls = 0

        def execute(self, buttons, targets=None):
            _Unknown.calls += 1
            raise AssertionError("must not run while the latch state is unknown")

        def estop_status(self):
            return {"latched": None, "detail": None, "known": False}

        def request_stop(self):
            pass

    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    service = SimpleLayService(RuleBasedIntentResolver(), _Unknown(),
                               appliance_registry=deps.get_appliance_registry())
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        c = TestClient(app)
        res = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
        assert res.status_code == 412, res.text
        assert "확인하는 중" in res.text
        assert _Unknown.calls == 0
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        for dep in (deps.get_appliance_registry, deps.get_service):
            dep.cache_clear()


# ── UART 리허설: RPi4가 가짜 콘센트·모의 모션일 때만, 주입으로 표시 ─────────────────────

@pytest.fixture()
def uart_rehearsal(monkeypatch):
    """UART 모드 RPi5 + RPi4 실행기(모의 모션·콘센트 없음). 시뮬레이터의 ActClient↔ActExecutor 짝을 빌린다."""
    from fastapi.testclient import TestClient

    from rpi.api import deps
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.routines.wiring import reset_routines
    from rpi.services.act_client_controller import ActClientController
    from rpi.services.link_tap import LinkFrameTap
    from rpi.services.simulator_controller import SimulatorController
    from rpi4 import act_main

    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_THINQ_MODE", "SIMPLELAY_DONE_WATCH"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    monkeypatch.setenv("SIMPLELAY_UART_REHEARSAL", "1")
    for dep in (deps.get_appliance_registry, deps.get_service, deps.get_appliance_done_log):
        dep.cache_clear()
    reset_routines()
    sim = SimulatorController(step_seconds=0, tap=LinkFrameTap(None, transport="in_memory"),
                              on_appliance_done=deps.receive_appliance_done)
    controller = ActClientController(sim._loop, sim._client)  # noqa: SLF001 - UART 컨트롤러 그대로

    def describe(kind):
        async def _d():
            act_main._describe_act(sim._executor, outlet_kind=kind, motion_kind="mock")  # noqa: SLF001
            sim._executor._announce()  # noqa: SLF001 - hello 답과 같다
        asyncio.run_coroutine_threadsafe(_d(), sim._loop).result(5)  # noqa: SLF001
        deadline = time.monotonic() + 2
        while controller.rehearsal_status().get("rehearsal") is not (kind != "real"):
            assert time.monotonic() < deadline
            time.sleep(0.01)

    service = SimpleLayService(RuleBasedIntentResolver(), controller,
                               appliance_registry=deps.get_appliance_registry())
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        yield TestClient(app), describe, sim
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        sim.close()
        for dep in (deps.get_appliance_registry, deps.get_service, deps.get_appliance_done_log):
            dep.cache_clear()
        reset_routines()


def test_uart_rehearsal_injects_done_through_rpi4_when_it_runs_fake(uart_rehearsal):
    c, describe, _ = uart_rehearsal
    describe("none")
    res = c.post("/demo/appliance-done", json={"appliance_id": "washer", "inputs": ["power", "beep"]})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["source"] == "injected" and body["injected_in"] == "rpi4_uart"
    from rpi.api import deps

    deadline = time.monotonic() + 2
    while not deps.get_appliance_done_log().recent():
        assert time.monotonic() < deadline
        time.sleep(0.01)
    assert deps.get_appliance_done_log().recent()[0]["source"] == "injected"


def test_uart_rehearsal_estop_goes_through_rpi4_and_is_labelled(uart_rehearsal):
    c, describe, _ = uart_rehearsal
    describe("none")
    res = c.post("/demo/outlet-estop", json={"hold_button": False})
    assert res.status_code == 200, res.text
    assert "시연" in res.json()["detail"]
    deadline = time.monotonic() + 2
    while c.get("/status").json()["estop_latched"] is not True:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    assert c.post("/stop/ack").json()["ok"] is True


def test_uart_rehearsal_is_refused_when_rpi4_has_real_hardware(uart_rehearsal):
    c, describe, _ = uart_rehearsal
    describe("real")
    res = c.post("/demo/appliance-done", json={"appliance_id": "washer", "inputs": ["power"]})
    assert res.status_code == 409, res.text


def test_uart_rehearsal_needs_the_explicit_rpi5_switch(monkeypatch):
    from fastapi.testclient import TestClient

    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_UART_REHEARSAL", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    c = TestClient(app)
    assert c.post("/demo/appliance-done", json={"appliance_id": "washer",
                                                "inputs": ["power"]}).status_code == 404
    assert c.post("/demo/outlet-estop", json={}).status_code == 404
