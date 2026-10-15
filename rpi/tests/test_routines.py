"""사용자 루틴(2026-09-30): 모델 검증 · 저장·이관 · 트리거 5종 · 승인/알림 · 승인 결속 ·
여러 단계 순서 · 템플릿 · 승인 없는 실행 불가.

실물 검증은 없다. 실행은 모의 전자레인지·모의 ThinQ 공기청정기로만 확인한다.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.service_commands import JobFinishedEvent, RunRecord
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.commands import (
    ApprovalMismatchError,
    ApprovedCommand,
    Command,
    CommandResult,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)
from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageSource
from rpi.routines import (
    RoutineEngine,
    RoutineRunner,
    RoutineStore,
    RoutineValidationError,
    RunStatus,
    build_routine,
    template_payloads,
)
from rpi.routines.model import routine_from_document
from rpi.routines.wiring import get_routine_engine, get_routine_store, reset_routines
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.services.persistence import SimpleLayDb

KST = timezone(timedelta(hours=9))
# 2026-10-01은 목요일(weekday 3).
THU_0730 = datetime(2026, 10, 1, 7, 30, tzinfo=KST)

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_control_arbiter, deps.get_presence_state_machine,
)


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", "pat-test-routines")
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.3")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


HEAT = {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["BT-08", "시작"]}
PURIFIER_ON = {"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_power",
               "args": {"power": "POWER_ON"}}


def _body(**kw):
    body = {"name": "아침 데우기", "steps": [HEAT], "trigger": {"kind": "manual"}}
    body.update(kw)
    return body


def _wait_run(client, run_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        run = client.get(f"/routines/runs/{run_id}")
        if run.status_code == 200 and run.json()["status"] != "running":
            return run.json()
        time.sleep(0.02)
    raise AssertionError("routine run did not finish")


def _executed_nothing(client):
    status = client.get("/status").json()
    purifier = deps.get_service().thinq_controller.client
    return status["last_job_id"] is None and not status["running"] and purifier.controls == []


# ── 1. 모델 검증 ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("body, needle", [
    ({"steps": [HEAT]}, "루틴 이름"),
    (_body(name="가" * 31), "30자"),
    (_body(steps=[]), "단계를 하나 이상"),
    (_body(steps=[{"kind": "teleport"}]), "종류를 알 수 없어요"),
    (_body(steps=[{"kind": "wait_until_done", "appliance_id": "microwave"}, HEAT]), "앞 단계에서 먼저"),
    (_body(steps=[HEAT, {"kind": "wait_until_done", "appliance_id": "microwave"}]), "마지막 단계"),
    (_body(steps=[{"kind": "announce", "text": "약 드실 시간이에요"}]), "알림만"),
    (_body(trigger={"kind": "time", "days": [], "time": "07:30"}), "요일"),
    (_body(trigger={"kind": "time", "days": [0], "time": "7시 반"}), "24시간 형식"),
    (_body(trigger={"kind": "approach", "zone": "kitchen"}), "다가오는 곳"),
    (_body(trigger={"kind": "after_done"}), "가전 하나 또는 루틴 하나"),
    (_body(conditions=[{"kind": "environment"}]), "온도나 습도"),
    (_body(mode="auto"), "실행 방식"),
    (_body(steps=[{**PURIFIER_ON, "action": "Set Power"}]), "동작 이름"),
])
def test_structural_validation_is_plain_korean(body, needle):
    with pytest.raises(RoutineValidationError) as exc:
        build_routine(body, routine_id="rt-x", now=THU_0730)
    assert needle in str(exc.value)


def test_announce_only_routine_is_allowed_as_notify():
    routine = build_routine(_body(steps=[{"kind": "announce", "text": "약 드실 시간이에요"}],
                                  mode="notify"), routine_id="rt-x", now=THU_0730)
    assert routine.device_steps == ()


def test_api_rejects_buttons_not_on_the_photo_panel(client):
    response = client.post("/routines", json=_body(steps=[
        {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["즉석밥", "순간이동"]}]))
    assert response.status_code == 422
    assert "조작부 사진에 없는 버튼" in response.json()["detail"]
    assert "순간이동" in response.json()["detail"]
    missing = client.post("/routines", json=_body(steps=[{**HEAT, "appliance_id": "toaster"}]))
    assert missing.status_code == 422 and "등록되어 있지 않아요" in missing.json()["detail"]
    wrong_route = client.post("/routines", json=_body(steps=[{**HEAT, "appliance_id": "air_purifier"}]))
    assert wrong_route.status_code == 422 and "ThinQ 명령 단계" in wrong_route.json()["detail"]
    out_of_range = client.post("/routines", json=_body(steps=[{**PURIFIER_ON, "args": {"power": "TURBO"}}]))
    assert out_of_range.status_code == 422 and "쓸 수 없는 명령" in out_of_range.json()["detail"]
    assert client.get("/routines").json() == []


def test_button_ids_and_names_both_compile_to_panel_labels(client):
    created = client.post("/routines", json=_body())
    assert created.status_code == 201, created.text
    card = client.post(f"/routines/{created.json()['id']}/trigger").json()["suggestion"]
    assert card["commands"][0]["buttons"] == ["즉석밥", "시작"]  # BT-08 → 즉석밥


# ── 2. 저장·이관 ─────────────────────────────────────────────────────────


def test_sqlite_round_trip(tmp_path):
    path = str(tmp_path / "routines.db")
    store = RoutineStore(SimpleLayDb(path))
    routine = build_routine(_body(trigger={"kind": "time", "days": [0, 2, 4], "time": "07:30"},
                                  conditions=[{"kind": "time_window", "start": "06:00", "end": "09:00"}],
                                  icon="sunrise"),
                            routine_id="rt-1", now=THU_0730)
    store.save(routine)
    reloaded = RoutineStore(SimpleLayDb(path)).get("rt-1")
    assert reloaded == routine
    assert reloaded.steps_fingerprint() == routine.steps_fingerprint()
    store.delete("rt-1")
    assert RoutineStore(SimpleLayDb(path)).list() == ()


def test_draft_table_and_schema0_document_are_migrated(tmp_path):
    path = str(tmp_path / "old.db")
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE routines (routine_id TEXT PRIMARY KEY, document TEXT)")
    legacy = {"id": "rt-old", "name": "옛 루틴",
              "steps": [{"type": "press_sequence", "appliance_id": "microwave", "buttons": ["즉석밥"]}],
              "trigger": {"kind": "time", "weekdays": [5, 6], "time": "09:00"},
              "created_at": "2026-09-29T09:00:00+09:00"}
    conn.execute("INSERT INTO routines VALUES (?, ?)", ("rt-old", json.dumps(legacy, ensure_ascii=False)))
    conn.execute("INSERT INTO routines VALUES (?, ?)", ("rt-bad", "{not json"))
    conn.commit()
    conn.close()

    db = SimpleLayDb(path)
    store = RoutineStore(db)
    routine = store.get("rt-old")
    assert routine is not None and store.get("rt-bad") is None  # 깨진 행 하나가 전체를 막지 않는다
    assert routine.mode == "approve" and routine.enabled and routine.conditions == ()
    assert routine.trigger.days == (5, 6)
    assert routine.steps[0].kind == "press_sequence"
    columns = {row[1] for row in sqlite3.connect(path).execute("PRAGMA table_info(routines)")}
    assert {"schema_version", "updated_at"} <= columns
    store.save(routine)
    assert RoutineStore(SimpleLayDb(path)).get("rt-old").to_dict()["schema_version"] == 1


# ── 3. 트리거(제어 가능한 시계) ─────────────────────────────────────────


class FixedClock:
    def __init__(self, now):
        self.value = now

    def now(self):
        return self.value


@dataclass
class Card:
    suggestion_id: str
    kwargs: dict


class FakeSuggestions:
    def __init__(self):
        self.cards: list[dict] = []
        self.absent = False

    def presence_absent(self):
        return self.absent

    def create_scenario_suggestion(self, **kw):
        self.cards.append(kw)
        return Card(f"s-{len(self.cards)}", kw)


class Readiness:
    can_execute = True
    reasons = ()


class FakeService:
    def __init__(self):
        self._appliance_registry = ApplianceRegistry()
        self.executed = []

    def summary_of(self, command):
        return f"{command.target_id} {' → '.join(command.buttons) or command.action}"

    def thinq_readiness(self, appliance_id):
        return Readiness()

    # 실행 진입점 -- 트리거 테스트에서는 한 번도 불리면 안 된다.
    def execute_approved(self, *a, **kw):
        self.executed.append(("execute_approved", a, kw))
        raise AssertionError("trigger must not execute")

    submit_approved = execute_approved
    execute_command = execute_approved
    submit_command = execute_approved
    execute_purpose = execute_approved
    submit_purpose = execute_approved


class FakeCare:
    def __init__(self):
        self.events = []

    on_append = None

    def append(self, kind, message, purpose=None, time_band=None):
        self.events.append((kind, message, purpose))
        if self.on_append is not None:
            self.on_append()


def _engine(clock=None, **kw):
    store = RoutineStore()
    suggestions, service, care = FakeSuggestions(), FakeService(), FakeCare()
    clock = clock or FixedClock(THU_0730)
    engine = RoutineEngine(store, suggestions, service, clock, care_events=care, **kw)
    return engine, store, suggestions, service, care, clock


def _save(store, clock, **kw):
    routine = build_routine(_body(**kw), routine_id=store.new_id(), now=clock.now())
    return store.save(routine)


def test_time_trigger_fires_once_inside_its_window():
    engine, store, suggestions, service, _, clock = _engine()
    _save(store, clock, trigger={"kind": "time", "days": [0, 1, 2, 3, 4], "time": "07:30"})
    clock.value = THU_0730 - timedelta(minutes=1)
    assert engine.tick() == []
    clock.value = THU_0730 + timedelta(minutes=2)
    assert len(engine.tick()) == 1
    assert engine.tick() == []  # 같은 날 같은 시각은 한 번
    clock.value = THU_0730 + timedelta(days=2)  # 토요일 -- 요일 밖
    assert engine.tick() == []
    clock.value = THU_0730 + timedelta(days=4)  # 월요일
    assert len(engine.tick()) == 1
    card = suggestions.cards[0]
    assert card["reason"].startswith("루틴 '아침 데우기' · 평일 07:30")
    assert card["is_demo"] is False and card["routine_name"] == "아침 데우기"
    assert service.executed == []


def test_time_trigger_outside_window_is_missed_not_late():
    engine, store, suggestions, *_ = _engine(FixedClock(THU_0730 + timedelta(minutes=11)))
    _save(store, engine._clock, trigger={"kind": "time", "days": [3], "time": "07:30"})
    assert engine.tick() == [] and suggestions.cards == []


def test_next_runs_orders_upcoming_time_routines():
    engine, store, _, _, _, clock = _engine()
    _save(store, clock, name="저녁", trigger={"kind": "time", "days": [3], "time": "19:00"})
    _save(store, clock, name="아침", trigger={"kind": "time", "days": [4], "time": "07:00"})
    _save(store, clock, name="직접", trigger={"kind": "manual"})
    off = _save(store, clock, name="꺼짐", trigger={"kind": "time", "days": [3], "time": "08:00"})
    from dataclasses import replace

    store.save(replace(off, enabled=False))
    upcoming = engine.next_runs()
    assert [u["name"] for u in upcoming] == ["저녁", "아침"]
    assert upcoming[0]["at"] == "2026-10-01T19:00:00+09:00"
    assert upcoming[0]["mode_label"] == "승인 후 실행"


def test_approach_trigger_uses_presence_transitions_once():
    from rpi.services.presence_state import PresenceStateMachine

    now = [0.0]
    machine = PresenceStateMachine(monotonic=lambda: now[0])
    engine, store, suggestions, service, *_ = _engine(presence_machine=machine)
    clock = engine._clock
    _save(store, clock, name="가까이", trigger={"kind": "approach", "zone": "near"})
    _save(store, clock, name="귀가", trigger={"kind": "approach", "zone": "arrival"})
    assert engine.tick() == []
    machine.observe(3.0)  # 방 안(먼 구역)
    assert engine.tick() == []
    now[0] = 1.0
    machine.observe(0.8)  # 가전 앞
    assert [c["routine_name"] for c in suggestions.cards] == []
    engine.tick()
    assert [c["routine_name"] for c in suggestions.cards] == ["가까이"]
    engine.tick()
    assert len(suggestions.cards) == 1  # 전이 한 번에 카드 한 번
    assert service.executed == []


def test_arrival_hint_triggers_arrival_routine():
    from rpi.services.presence_state import PresenceStateMachine

    machine = PresenceStateMachine(monotonic=lambda: 10.0)
    engine, store, suggestions, *_ = _engine(presence_machine=machine)
    _save(store, engine._clock, name="귀가", trigger={"kind": "approach", "zone": "arrival"})
    machine.phone_arriving()
    engine.tick()
    assert [c["routine_name"] for c in suggestions.cards] == ["귀가"]


def _event(mode, confirmation, appliance="microwave", scenario_id=None, status="succeeded"):
    return JobFinishedEvent("j", appliance, ControlRoute.PHYSICAL, status, Receipt.ACCEPTED,
                            confirmation, mode, UsageSource.DIRECT, scenario_id=scenario_id)


def test_after_done_appliance_needs_confirmed_evidence():
    engine, store, suggestions, service, *_ = _engine()
    routine = _save(store, engine._clock, name="데운 뒤",
                    trigger={"kind": "after_done", "appliance_id": "microwave"})
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.PRESS_CONFIRMED))
    engine.on_job_finished(_event(ExecutionMode.UNKNOWN, Confirmation.REPORTED))
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED, status="failed"))
    assert suggestions.cards == []
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED))
    assert suggestions.cards[-1]["is_demo"] is False
    engine.on_job_finished(_event(ExecutionMode.MOCK, Confirmation.PRESS_CONFIRMED))
    assert suggestions.cards[-1]["is_demo"] is True and "모의" in suggestions.cards[-1]["reason"]
    # 자기 루틴의 단계가 끝난 이벤트로는 다시 만들지 않는다.
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED,
                                  scenario_id=routine.scenario_key()))
    assert len(suggestions.cards) == 2
    assert service.executed == []


def test_after_done_routine_and_thinq_event_triggers():
    engine, store, suggestions, service, *_ = _engine()
    clock = engine._clock
    first = _save(store, clock, name="아침 데우기")
    _save(store, clock, name="이어서", trigger={"kind": "after_done", "routine_id": first.routine_id})
    _save(store, clock, name="세탁 끝", trigger={"kind": "event", "event": "wash_complete"})

    @dataclass
    class Run:
        routine_id: str
        routine_name: str
        status: RunStatus
        is_demo: bool = False

    engine.on_routine_finished(Run(first.routine_id, first.name, RunStatus.FAILED))
    assert suggestions.cards == []
    engine.on_routine_finished(Run(first.routine_id, first.name, RunStatus.SUCCEEDED, True))
    assert suggestions.cards[-1]["routine_name"] == "이어서" and suggestions.cards[-1]["is_demo"]
    engine.on_thinq_event({"event": "wash_start", "execution_mode": "mock"})
    assert len(suggestions.cards) == 1
    engine.on_thinq_event({"event": "wash_complete", "execution_mode": "real"})
    assert suggestions.cards[-1]["routine_name"] == "세탁 끝" and not suggestions.cards[-1]["is_demo"]
    assert service.executed == []


def test_conditions_gate_the_trigger():
    reading = [(24.0, 50.0)]
    engine, store, suggestions, *_ = _engine(environment_reader=lambda: reading[0])
    _save(store, engine._clock, name="귀가 냉방", trigger={"kind": "event", "event": "wash_complete"},
          conditions=[{"kind": "environment", "temperature_at_least": 28, "humidity_at_least": 70},
                      {"kind": "time_window", "start": "06:00", "end": "09:00"}])
    engine.on_thinq_event({"event": "wash_complete"})
    assert suggestions.cards == []
    assert engine.recent_log()[0]["outcome"] == "skipped"
    reading[0] = (24.0, 75.0)  # 습도만 넘어도 된다(또는)
    engine.on_thinq_event({"event": "wash_complete"})
    assert len(suggestions.cards) == 1
    engine._clock.value = THU_0730.replace(hour=12)
    engine.on_thinq_event({"event": "wash_complete"})
    assert len(suggestions.cards) == 1  # 시간대 밖
    reading[0] = None
    engine._clock.value = THU_0730
    engine.on_thinq_event({"event": "wash_complete"})
    assert "온습도를 읽지 못했어요" in engine.recent_log()[0]["detail"]


def test_disabled_routine_never_fires():
    engine, store, suggestions, *_ = _engine()
    from dataclasses import replace

    routine = _save(store, engine._clock, trigger={"kind": "time", "days": [3], "time": "07:30"})
    store.save(replace(routine, enabled=False))
    engine.tick()
    engine.on_thinq_event({"event": "wash_complete"})
    assert suggestions.cards == []


# ── 4. 승인 vs 알림 ──────────────────────────────────────────────────────


def test_notify_mode_only_records_a_notice():
    engine, store, suggestions, service, care, clock = _engine()
    _save(store, clock, name="복약 알림", mode="notify",
          trigger={"kind": "time", "days": [3], "time": "07:30"},
          steps=[HEAT, {"kind": "announce", "text": "약 드실 시간이에요"}])
    engine.tick()
    assert suggestions.cards == [] and service.executed == []
    assert care.events[0][0] == "routine_notice"
    assert "약 드실 시간이에요" in care.events[0][1]


def test_notify_routine_via_api_never_executes(client):
    rid = client.post("/routines", json=_body(mode="notify")).json()["id"]
    result = client.post(f"/routines/{rid}/trigger")
    assert result.status_code == 200 and result.json()["kind"] == "notice"
    assert client.get("/suggestions").json() == []
    assert _executed_nothing(client)


def test_approve_mode_card_then_approval_runs_it(client):
    rid = client.post("/routines", json=_body()).json()["id"]
    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    listed = client.get("/suggestions").json()
    assert [(s["id"], s["routine_name"]) for s in listed] == [(card["id"], "아침 데우기")]
    assert card["reason"] == "루틴 '아침 데우기' · 직접 실행을 눌렀어요"
    assert _executed_nothing(client)
    job = client.post(f"/suggestions/{card['id']}/approve")
    assert job.status_code == 200, job.text
    run = _wait_run(client, job.json()["job_id"])
    assert run["status"] == "succeeded" and run["is_demo"] is True
    assert run["steps"][0]["confirmation"] == "press_confirmed"


# ── 5. 승인 결속(편집하면 재승인) ─────────────────────────────────────────


@pytest.mark.parametrize("change", [
    {"steps": [{**HEAT, "buttons": ["BT-08"]}, ]},
    {"steps": [HEAT, {"kind": "announce", "text": "다른 안내"}]},
    {"mode": "notify"},
])
def test_editing_a_routine_invalidates_the_pending_approval(client, change):
    rid = client.post("/routines", json=_body()).json()["id"]
    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    edited = client.put(f"/routines/{rid}", json=_body(**change))
    assert edited.status_code == 200, edited.text
    response = client.post(f"/suggestions/{card['id']}/approve")
    assert response.status_code == 409
    assert "다시" in response.json()["detail"]
    assert _executed_nothing(client)
    assert all(s["id"] != card["id"] for s in client.get("/suggestions").json())


def test_disabling_or_deleting_invalidates_the_pending_approval(client):
    for action in ("disable", "delete"):
        rid = client.post("/routines", json=_body()).json()["id"]
        card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
        if action == "disable":
            assert client.post(f"/routines/{rid}/enable", json={"enabled": False}).status_code == 200
        else:
            assert client.delete(f"/routines/{rid}").status_code == 200
        assert client.post(f"/suggestions/{card['id']}/approve").status_code == 409
    assert _executed_nothing(client)


def test_rename_keeps_the_approval_valid(client):
    rid = client.post("/routines", json=_body()).json()["id"]
    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    client.put(f"/routines/{rid}", json=_body(name="밥 데우기", icon="rice"))
    job = client.post(f"/suggestions/{card['id']}/approve")
    assert job.status_code == 200
    assert _wait_run(client, job.json()["job_id"])["status"] == "succeeded"


# ── 6. 여러 단계 순서 ────────────────────────────────────────────────────


def test_multi_step_routine_runs_in_order_with_announce(client):
    rid = client.post("/routines", json=_body(steps=[
        HEAT, {"kind": "wait_until_done", "appliance_id": "microwave"},
        {"kind": "announce", "text": "약 드실 시간이에요"}, PURIFIER_ON])).json()["id"]
    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    assert [c["route"] for c in card["commands"]] == ["physical", "thinq"]
    job = client.post(f"/suggestions/{card['id']}/approve").json()["job_id"]
    run = _wait_run(client, job)
    assert [s["kind"] for s in run["steps"]] == ["command", "wait_until_done", "announce", "command"]
    assert run["steps"][1]["detail"].startswith("시연:")  # 모의 실행은 완료 확인이 아니다
    assert run["steps"][3]["confirmation"] == "state_confirmed"
    assert len(run["job_ids"]) == 2
    notices = [e for e in deps.get_care_events().recent(20) if e.kind == "routine_announce"]
    assert [e.message for e in notices] == ["약 드실 시간이에요"]


def _result(command, status=CommandStatus.SUCCEEDED, confirmation=Confirmation.PRESS_CONFIRMED,
            mode=ExecutionMode.REAL, stop=False):
    receipt = Receipt.ACCEPTED if status is not CommandStatus.STOPPED else Receipt.NOT_DISPATCHED
    if status is CommandStatus.STOPPED:
        confirmation = Confirmation.NONE
    return CommandResult(command=command, status=status, receipt=receipt, confirmation=confirmation,
                         execution_mode=mode, stop_requested=stop)


@dataclass
class _Status:
    running: bool = False
    last_job_id: str | None = None


class ScriptedService:
    """실행 서비스 흉내 — 구간마다 정해 둔 결과를 돌려준다."""

    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.calls: list[tuple] = []
        self._last = None
        self.stops = 0

    def _run(self, approved):
        self.calls.append(tuple(a.command for a in approved))
        results = tuple(self.outcomes.pop(0)(a.command) for a in approved)
        self._last = RunRecord(f"job-{len(self.calls)}", None, None, results,
                               tuple("s" for _ in approved))
        return self._last

    def execute_approved(self, approved, **kw):
        assert all(isinstance(a, ApprovedCommand) for a in approved)
        return self._run(approved)

    def submit_approved(self, approved, **kw):
        return self._run(approved).job_id

    def status(self):
        return _Status(False, self._last.job_id if self._last else None)

    def last_run(self):
        return self._last

    def emergency_stop_report(self):
        self.stops += 1


def _runner_setup(outcomes, steps):
    store = RoutineStore()
    clock = FixedClock(THU_0730)
    registry = ApplianceRegistry()
    routine = store.save(build_routine(_body(steps=steps), routine_id="rt-m", now=clock.now()))
    from rpi.routines import compile_commands

    commands = compile_commands(routine, registry)
    approved = tuple(ApprovedCommand(c, "card-1", clock.now(), "요약", clock.now() + timedelta(minutes=15))
                     for c in commands)
    service = ScriptedService(outcomes)
    care = FakeCare()
    runner = RoutineRunner(store, service, clock, care, poll_seconds=0, sleep=lambda s: None)
    return runner, routine, approved, service, care


INDUCTION = {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]}


def test_wait_until_done_blocks_next_step_without_l3():
    runner, routine, approved, service, care = _runner_setup(
        [lambda c: _result(c, confirmation=Confirmation.PRESS_CONFIRMED)],
        [HEAT, {"kind": "wait_until_done", "appliance_id": "microwave"}, INDUCTION])
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.UNCONFIRMED
    assert len(service.calls) == 1  # 인덕션 단계는 보내지 않았다
    assert care.events[-1][0] == "routine_stopped"


def test_wait_until_done_passes_on_operation_confirmed_and_expiry_does_not_cut_the_run():
    runner, routine, approved, service, _ = _runner_setup(
        [lambda c: _result(c, confirmation=Confirmation.OPERATION_CONFIRMED), lambda c: _result(c)],
        [HEAT, {"kind": "wait_until_done", "appliance_id": "microwave"}, INDUCTION])
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.SUCCEEDED and len(service.calls) == 2
    assert run.steps[1]["detail"] == "시작만 확인 — 끝남 판정 센서 없음"  # 끝 센서 없음(M2)


def _halted(command, status):
    if status is CommandStatus.FAILED:
        return CommandResult(command=command, status=status, receipt=Receipt.ACCEPTED,
                             confirmation=Confirmation.NONE, execution_mode=ExecutionMode.REAL)
    if status is CommandStatus.STOPPED:
        return CommandResult(command=command, status=status, receipt=Receipt.NOT_DISPATCHED,
                             confirmation=Confirmation.NONE, execution_mode=ExecutionMode.REAL,
                             stop_requested=True)
    return CommandResult(command=command, status=status, receipt=Receipt.UNKNOWN,
                         confirmation=Confirmation.NONE, execution_mode=ExecutionMode.REAL)


@pytest.mark.parametrize("status", [CommandStatus.FAILED, CommandStatus.STOPPED, CommandStatus.UNCONFIRMED])
def test_failed_or_stopped_segment_halts_the_routine(status):
    runner, routine, approved, service, _ = _runner_setup(
        [lambda c: _halted(c, status)], [HEAT, {"kind": "announce", "text": "안내"}, INDUCTION])
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status.value == status.value
    assert len(service.calls) == 1  # 뒤 단계는 보내지 않았다
    assert all(s["kind"] != "announce" for s in run.steps)


def test_routine_stop_between_segments_sends_nothing_more():
    runner, routine, approved, service, care = _runner_setup(
        [lambda c: _result(c), lambda c: _result(c)],
        [HEAT, {"kind": "announce", "text": "안내"}, INDUCTION])
    # 안내가 기록되는 순간(첫 구간과 둘째 구간 사이) 사용자가 루틴 정지를 누른다.
    care.on_append = lambda: runner.stop(runner.runs()[0].run_id)
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert run.status is RunStatus.STOPPED
    assert len(service.calls) == 1
    assert service.stops == 0  # 누르는 중이 아니었으므로 긴급 정지는 보내지 않는다


# ── 7. 템플릿 ────────────────────────────────────────────────────────────


def test_templates_are_listed_and_are_not_user_data(client):
    templates = client.get("/routines/templates").json()
    assert {t["template_id"] for t in templates} == {"morning", "outing", "visitor", "wash_done"}
    assert all(t["is_template"] is True for t in templates)
    morning = next(t for t in templates if t["template_id"] == "morning")
    assert [s["kind"] for s in morning["steps"]] == ["press_sequence", "wait_until_done", "announce"]
    assert "판단하지 않아요" in morning["caution"]
    assert client.get("/routines").json() == []
    assert client.get("/routines/next").json() == []


def test_every_template_passes_structural_validation():
    assert len(template_payloads()) == 4  # 시연 v3의 네 루틴(2026-10-06)


# ── 8. 습관 제안이 루틴 이름을 빌려 쓴다 ─────────────────────────────────


def _habit_service(namer):
    from datetime import time as dtime

    from rpi.intent import (
        InMemoryUsageLog,
        PatternConfig,
        PatternDetector,
        TimeBand,
        UsageOutcome,
        UsageRecord,
    )
    from rpi.intent.mock import FixedClock as IntentClock
    from rpi.intent.mock import MockPurposeExecutor
    from rpi.intent.rules import RuleBasedIntentResolver
    from rpi.intent.suggestions import ProactiveSuggestionService

    now = datetime(2026, 9, 21, 8, tzinfo=KST)
    clock = IntentClock(now)
    log = InMemoryUsageLog(tuple(
        UsageRecord(now - timedelta(days=d), "즉석밥 데워줘", UsageOutcome.SUCCEEDED, "microwave",
                    execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for d in (1, 2, 3)))
    detector = PatternDetector(log, clock, PatternConfig(3, (TimeBand("아침", dtime(6), dtime(10)),)))
    svc = ProactiveSuggestionService(detector, clock, MockPurposeExecutor(),
                                     intent_resolver=RuleBasedIntentResolver())
    if namer is not None:
        svc.set_routine_namer(namer)
    return svc


def test_habit_card_prefers_matching_routine_name():
    engine, store, *_ = _engine()
    _save(store, engine._clock, name="아침 데우기", steps=[{**HEAT, "buttons": ["즉석밥", "BT-05"]}])
    card, = _habit_service(engine.habit_routine).create_suggestions()
    assert card.reason.startswith("평소처럼 '아침 데우기' 할까요? ")
    assert "에 자주 하셔서 여쭤봐요 · 최근 " in card.reason
    assert card.routine_name == "아침 데우기"
    assert card.purpose == "즉석밥 데워줘"  # 실행 내용(버튼 순서)은 그대로
    assert card.commands == () and card.steps == ("즉석밥", "시작")


def test_habit_card_keeps_old_text_without_a_matching_routine():
    engine, store, *_ = _engine()
    # 같은 버튼이라도 여러 단계 루틴이면 이름을 빌리지 않는다(카드는 버튼만 실행한다).
    _save(store, engine._clock, name="아침 루틴",
          steps=[HEAT, {"kind": "announce", "text": "약 드실 시간이에요"}])
    _save(store, engine._clock, name="해동", steps=[{**HEAT, "buttons": ["해동", "시작"]}])
    card, = _habit_service(engine.habit_routine).create_suggestions()
    assert not card.reason.startswith("평소처럼") and card.routine_name is None
    assert "에 자주 하셔서 여쭤봐요 · 최근 " in card.reason
    plain, = _habit_service(None).create_suggestions()
    assert plain.reason == card.reason


# ── 9. 승인 없는 실행은 불가능하다 ────────────────────────────────────────


def test_no_trigger_path_executes_without_approval(client, monkeypatch):
    """트리거 다섯 종류를 모두 울려도 실행은 0건 — 카드만 쌓인다."""
    triggers = [
        {"kind": "time", "days": list(range(7)), "time": "07:30"},
        {"kind": "approach", "zone": "near"},
        {"kind": "after_done", "appliance_id": "microwave"},
        {"kind": "event", "event": "wash_complete"},
        {"kind": "manual"},
    ]
    ids = []
    for i, trigger in enumerate(triggers):
        body = _body(name=f"루틴{i}", trigger=trigger, steps=[PURIFIER_ON])
        ids.append(client.post("/routines", json=body).json()["id"])
    engine = get_routine_engine()
    engine.tick(datetime.now(KST).replace(hour=7, minute=31))
    client.post("/presence/distance", json={"distance_m": 3.0})
    client.post("/presence/distance", json={"distance_m": 0.8})
    engine.tick(datetime.now(KST).replace(hour=12))
    engine.on_job_finished(_event(ExecutionMode.REAL, Confirmation.OPERATION_CONFIRMED))
    deps.get_service().thinq_controller.client.inject_event("wash_complete")
    client.post(f"/routines/{ids[-1]}/trigger")

    cards = [s for s in client.get("/suggestions").json() if s.get("routine_id")]
    assert sorted(c["routine_id"] for c in cards) == sorted(ids)
    assert _executed_nothing(client)


def test_runner_refuses_anything_but_approved_commands():
    runner, routine, approved, service, _ = _runner_setup([lambda c: _result(c)], [HEAT])
    raw = tuple(a.command for a in approved)
    with pytest.raises(ApprovalMismatchError):
        runner.execute_approved(raw, scenario_id=routine.scenario_key())
    with pytest.raises(ApprovalMismatchError):  # 지문이 다른(위조·옛) 카드 ID
        runner.execute_approved(approved, scenario_id=f"routine:{routine.routine_id}@000000000000")
    assert service.calls == []


def test_routine_package_and_router_have_no_direct_execution_calls():
    """루틴 코드가 실행 서비스의 직접 실행 진입점을 부르지 않는다(승인 경로만)."""
    import pathlib

    root = pathlib.Path(__file__).resolve().parents[1]
    sources = [*sorted((root / "routines").glob("*.py")), root / "api" / "routines_router.py"]
    forbidden = ("execute_command(", "submit_command(", "execute_purpose(", "submit_purpose(",
                 "/execute", "execute(")
    for path in sources:
        text = path.read_text(encoding="utf-8")
        for word in forbidden:
            hits = [line for line in text.splitlines()
                    if word in line and "execute_approved(" not in line]
            assert hits == [], f"{path.name}: {word} {hits}"
    runner_text = (root / "routines" / "runner.py").read_text(encoding="utf-8")
    assert "isinstance(a, ApprovedCommand)" in runner_text
