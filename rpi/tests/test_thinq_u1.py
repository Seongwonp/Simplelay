"""U1-a·U1-b·U1-c(모의): 명령 계약 연결 · ThinQ 모의 어댑터 · 시나리오 (2026-09-29).

실제 ThinQ 호출은 없다. 모든 ThinQ 결과는 모의 클라이언트에서 나온다.
"""

from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.commands import (
    ApprovalMismatchError,
    ApprovedCommand,
    Command,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)
from rpi.controller.models import ExecutionMode
from rpi.services.thinq import (
    MOCK_PURIFIER_ID,
    MockThinqClient,
    RealThinqClient,
    StopOutcome,
    ThinqConfig,
    ThinqController,
    ThinqMode,
    air_purifier_binding,
    washer_binding,
)

_SINGLETONS = (
    deps.get_service,
    deps.get_suggestion_service,
    deps.get_suppression_store,
    deps.get_alert_store,
    deps.get_node_registry,
    deps.get_demo_failure_state,
    deps.get_job_history,
    deps.get_presence_store,
    deps.get_appliance_registry,
    deps.get_readiness_registry,
    deps.get_usage_log,
    deps.get_care_events,
    deps.get_control_arbiter,
)

SECRET_PAT = "pat-SECRET-do-not-log-8f3a91"


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()


@pytest.fixture()
def mock_mode(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.5")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    yield
    _reset()


@pytest.fixture()
def client(mock_mode):
    from rpi.main import app

    return TestClient(app)


def _wait_done(client, job_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish")


def _controller(client=None, **kw) -> tuple[ThinqController, MockThinqClient]:
    client = client or MockThinqClient()
    binding = air_purifier_binding(MOCK_PURIFIER_ID)
    ctrl = ThinqController(
        client, lambda aid: binding if aid == "air_purifier" else None,
        mode=ThinqMode.MOCK, confirm_seconds=kw.pop("confirm_seconds", 0.05),
        poll_interval=0.0, sleep=lambda s: None, **kw,
    )
    return ctrl, client


HIGH = Command.thinq("air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})


# ── 1. 명령 계약: 승인 결속 ────────────────────────────────────────────────


def test_approval_binds_target_route_action_and_args():
    now = datetime(2026, 9, 29, 12, tzinfo=timezone.utc)
    approved = ApprovedCommand(HIGH, "a-1", now, "공기청정기 풍량 강", now + timedelta(minutes=15))
    assert approved.matches(Command.thinq("air_purifier", "set_wind_strength", {"wind_strength": "HIGH"}))
    # 인자 하나·동작·대상·경로가 달라지면 같은 승인이 아니다.
    assert not approved.matches(Command.thinq("air_purifier", "set_wind_strength", {"wind_strength": "LOW"}))
    assert not approved.matches(Command.thinq("air_purifier", "set_power", {"power": "POWER_ON"}))
    assert not approved.matches(Command.thinq("washer", "set_wind_strength", {"wind_strength": "HIGH"}))
    assert not approved.matches(Command.physical("air_purifier", ("강풍",)))


def test_binding_rejects_unsupported_action_and_out_of_range_value():
    from rpi.services.thinq import CapabilityError

    binding = air_purifier_binding(MOCK_PURIFIER_ID)
    with pytest.raises(CapabilityError):
        binding.command("air_purifier", "set_temperature", {"temperature": 20})
    with pytest.raises(CapabilityError):
        binding.command("air_purifier", "set_wind_strength", {"wind_strength": "TURBO"})
    assert washer_binding("w").read_only


# ── 2. ThinQ 실행기: 확인 수준 ────────────────────────────────────────────


def test_state_confirmed_only_when_follow_up_status_shows_the_value():
    ctrl, client = _controller()
    result = ctrl.execute_command(HIGH)
    assert result.status is CommandStatus.SUCCEEDED
    assert result.receipt is Receipt.ACCEPTED
    assert result.confirmation is Confirmation.STATE_CONFIRMED
    assert result.execution_mode is ExecutionMode.MOCK
    assert client.controls == [(MOCK_PURIFIER_ID, {"airFlow": {"windStrength": "HIGH"}})]


def test_accepted_but_state_not_seen_is_unconfirmed_not_success():
    ctrl, client = _controller()
    client.drop_state_updates = True
    result = ctrl.execute_command(HIGH)
    assert result.status is CommandStatus.UNCONFIRMED
    assert result.receipt is Receipt.ACCEPTED  # 접수됨
    assert result.confirmation is Confirmation.NONE
    assert len(client.controls) == 1  # 자동 재전송 없음


def test_delayed_state_within_window_is_confirmed():
    ctrl, client = _controller(confirm_seconds=5)
    client.state_delay_reads = 2
    result = ctrl.execute_command(HIGH)
    assert result.confirmation is Confirmation.STATE_CONFIRMED


def test_value_already_set_before_command_cannot_be_confirmed():
    ctrl, client = _controller()
    ctrl.execute_command(HIGH)
    again = ctrl.execute_command(HIGH)
    assert again.status is CommandStatus.UNCONFIRMED
    assert again.confirmation is Confirmation.NONE
    assert "같은 값" in again.detail


def test_lost_response_is_unknown_receipt():
    ctrl, client = _controller()
    client.fail_next_control("timeout")
    result = ctrl.execute_command(HIGH)
    assert result.status is CommandStatus.UNCONFIRMED
    assert result.receipt is Receipt.UNKNOWN  # 접수 불명
    assert len(client.controls) == 1


def test_cloud_rejection_is_failed_and_offline_is_not_dispatched():
    ctrl, client = _controller()
    client.fail_next_control("reject")
    rejected = ctrl.execute_command(HIGH)
    assert rejected.status is CommandStatus.FAILED
    client.set_online(False)
    offline = ctrl.execute_command(HIGH)
    assert offline.status is CommandStatus.FAILED
    assert offline.receipt is Receipt.NOT_DISPATCHED
    assert not ctrl.readiness("air_purifier").can_execute


def test_offline_device_is_not_ready():
    ctrl, client = _controller()
    assert ctrl.readiness("air_purifier").can_execute
    client.set_device_online(MOCK_PURIFIER_ID, False)
    readiness = ctrl.readiness("air_purifier")
    assert not readiness.can_execute
    assert readiness.state == "disconnected"


# ── 3. 정지 의미(결정 #5) ─────────────────────────────────────────────────


def test_stop_before_dispatch_cancels_and_sends_nothing():
    class StopDuringPrecheck(MockThinqClient):
        controller = None

        def get_status(self, device_id):
            state = super().get_status(device_id)
            if self.controller is not None:
                self.outcome = self.controller.request_stop()
                self.controller = None
            return state

    client = StopDuringPrecheck()
    ctrl, _ = _controller(client)
    client.controller = ctrl
    result = ctrl.execute_command(HIGH)
    assert client.outcome is StopOutcome.CANCELLED_BEFORE_DISPATCH
    assert result.status is CommandStatus.STOPPED
    assert result.receipt is Receipt.NOT_DISPATCHED
    assert client.controls == []


def test_stop_after_dispatch_is_uncancellable_and_sends_no_power_off():
    class StopAfterSend(MockThinqClient):
        controller = None

        def post_control(self, device_id, payload):
            response = super().post_control(device_id, payload)
            self.outcome = self.controller.request_stop()
            return response

    client = StopAfterSend()
    client.drop_state_updates = True
    ctrl, _ = _controller(client, confirm_seconds=5)
    client.controller = ctrl
    result = ctrl.execute_command(HIGH)
    assert client.outcome is StopOutcome.SENT_UNCANCELLABLE
    assert result.status is CommandStatus.UNCONFIRMED
    assert result.stop_requested
    # 가전 운전 정지(전원 끄기)를 자동으로 보내지 않는다.
    assert client.controls == [(MOCK_PURIFIER_ID, {"airFlow": {"windStrength": "HIGH"}})]
    assert ctrl.request_stop() is StopOutcome.IDLE


def test_real_client_is_real_mode_and_not_implemented():
    real = RealThinqClient(has_pat=True, country="KR")
    assert real.execution_mode is ExecutionMode.REAL
    with pytest.raises(NotImplementedError, match="SIMPLELAY_THINQ_PAT 필요, 실물 미구현"):
        real.post_control("x", {})


def test_config_rejects_unknown_mode_and_keeps_no_token():
    with pytest.raises(RuntimeError):
        ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "cloud"})
    config = ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "real", "SIMPLELAY_THINQ_PAT": SECRET_PAT})
    assert config.has_pat and SECRET_PAT not in repr(config)
    assert ThinqConfig.from_env({}).mode is ThinqMode.OFF


# ── 4. 서비스·API: 경로 라우팅과 준비 상태 ────────────────────────────────


def test_thinq_appliance_routes_to_thinq_controller(client):
    job = client.post("/execute", json={"text": "강풍으로 바꿔줘", "appliance_id": "air_purifier"})
    assert job.status_code == 200, job.text
    status = _wait_done(client, job.json()["job_id"])
    assert status["last_route"] == "thinq"
    assert status["last_status"] == "succeeded"
    assert status["last_confirmation"] == "state_confirmed"
    assert status["last_execution_mode"] == "mock"
    history = client.get("/history").json()[0]
    assert (history["route"], history["confirmation"], history["receipt"]) == (
        "thinq", "state_confirmed", "accepted")
    service = deps.get_service()
    assert service.thinq_controller.client.controls[-1][1] == {"airFlow": {"windStrength": "HIGH"}}


def test_button_sequence_to_thinq_appliance_is_refused(client):
    response = client.post("/execute-buttons", json={"buttons": ["강풍"], "appliance_id": "air_purifier"})
    assert response.status_code in (409, 422)
    assert deps.get_service().thinq_controller.client.controls == []


def test_physical_route_unchanged_for_microwave(client):
    job = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    status = _wait_done(client, job.json()["job_id"])
    assert status["last_route"] == "physical"
    assert status["last_confirmation"] in ("press_confirmed", "reported", "operation_confirmed", "none")


def test_offline_thinq_is_412_never_success(client):
    deps.get_service().thinq_controller.client.set_online(False)
    response = client.post("/thinq/command", json={
        "appliance_id": "air_purifier", "action": "set_wind_strength",
        "args": {"wind_strength": "HIGH"}})
    assert response.status_code == 412
    readiness = client.get("/readiness/air_purifier").json()
    assert readiness["route"] == "thinq" and readiness["can_execute"] is False
    assert readiness["thinq"]["client_reachable"] is False


def test_thinq_command_validates_capability(client):
    bad = client.post("/thinq/command", json={
        "appliance_id": "air_purifier", "action": "set_wind_strength", "args": {"wind_strength": "TURBO"}})
    assert bad.status_code == 422
    washer = client.post("/thinq/command", json={
        "appliance_id": "washer", "action": "set_power", "args": {"power": "POWER_ON"}})
    assert washer.status_code in (412, 422)


def test_thinq_devices_and_events(client):
    body = client.get("/thinq/devices").json()
    assert body["mode"] == "mock" and body["execution_mode"] == "mock"
    ids = {a["appliance_id"] for a in body["appliances"]}
    assert ids == {"air_purifier", "washer"}
    event = client.post("/demo/thinq/event", json={"event": "wash_complete"}).json()
    assert event["state"] == {"runState": {"currentState": "END"}}
    assert client.get("/thinq/events").json()["events"][0]["event"] == "wash_complete"
    # 폰·키오스크 목록에는 서버 구성 가전이 나오지 않는다.
    listed = {a["id"] for a in client.get("/appliances").json()}
    assert "air_purifier" not in listed and "fan" not in listed


def test_thinq_off_by_default(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    _reset()
    try:
        from rpi.main import app

        c = TestClient(app)
        assert c.get("/thinq/devices").status_code == 404
        assert c.post("/demo/thinq/event", json={"event": "wash_complete"}).status_code == 404
        assert deps.get_appliance_registry().get("air_purifier") is None
    finally:
        _reset()


def test_real_mode_without_implementation_is_not_ready(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "real")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", "dev-123")
    _reset()
    try:
        from rpi.main import app

        c = TestClient(app)
        readiness = c.get("/readiness/air_purifier").json()
        assert readiness["can_execute"] is False
        assert "실물 미구현" in " ".join(readiness["reasons"])
        response = c.post("/thinq/command", json={
            "appliance_id": "air_purifier", "action": "set_power", "args": {"power": "POWER_ON"}})
        assert response.status_code == 412
        assert c.post("/demo/thinq/event", json={"event": "wash_complete"}).status_code == 409
        assert deps.get_service().thinq_controller.execution_mode is ExecutionMode.REAL
    finally:
        _reset()


# ── 5. 시나리오: 트리거 → 제안 → 승인 → ThinQ 명령 ───────────────────────


def _scenario_cards(client, scenario_id):
    return [s for s in client.get("/suggestions").json() if s.get("scenario_id") == scenario_id]


def test_cook_then_air_end_to_end_with_mock(client):
    job = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    status = _wait_done(client, job.json()["job_id"])
    assert status["last_status"] == "succeeded"
    purifier = deps.get_service().thinq_controller.client
    assert purifier.controls == []  # 승인 없는 자동 실행 없음

    cards = _scenario_cards(client, "cook_then_air")
    assert len(cards) == 1
    card = cards[0]
    assert card["purpose"] == "공기청정기 강풍으로 바꿀까요?"
    assert card["is_demo"] is True  # 모의 실행 성공 근거 → 시연 제안
    assert "모의" in card["reason"]
    assert card["commands"] == [{
        "target_id": "air_purifier", "route": "thinq", "action": "set_wind_strength",
        "args": {"wind_strength": "HIGH"}, "buttons": [], "summary": "공기청정기(모의) 풍량 강"}]

    approved = client.post(f"/suggestions/{card['id']}/approve")
    assert approved.status_code == 200, approved.text
    status = _wait_done(client, approved.json()["job_id"])
    assert status["last_route"] == "thinq"
    assert status["last_confirmation"] == "state_confirmed"
    assert purifier.controls == [(MOCK_PURIFIER_ID, {"airFlow": {"windStrength": "HIGH"}})]
    run = client.get("/scenarios/last-run").json()["run"]
    assert run["scenario_id"] == "cook_then_air"
    assert run["steps"][0]["confirmation"] == "state_confirmed"
    assert _scenario_cards(client, "cook_then_air") == []


def test_real_run_without_l3_does_not_trigger():
    from rpi.api.service_commands import JobFinishedEvent
    from rpi.intent.models import UsageSource
    from rpi.scenarios import ScenarioCatalog, ScenarioEngine

    offered = []

    class Suggestions:
        def set_scenario_resolver(self, r):
            pass

        def create_scenario_suggestion(self, **kw):
            offered.append(kw)

    class Service:
        _appliance_registry = None

    engine = ScenarioEngine(ScenarioCatalog(), Suggestions(), Service())

    def event(mode, confirmation):
        return JobFinishedEvent("j", "microwave", ControlRoute.PHYSICAL, "succeeded",
                                Receipt.ACCEPTED, confirmation, mode, UsageSource.DIRECT)

    engine.on_job_finished(event(ExecutionMode.REAL, Confirmation.PRESS_CONFIRMED))
    engine.on_job_finished(event(ExecutionMode.UNKNOWN, Confirmation.REPORTED))
    assert offered == []  # 대상 미등록이라도 그 전에 근거가 없어 걸러진다


def test_scenario_definition_change_requires_reapproval(client):
    from rpi.api.thinq_wiring import get_scenario_engine
    from rpi.scenarios import COOK_THEN_AIR, ScenarioStep

    job = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    _wait_done(client, job.json()["job_id"])
    card = _scenario_cards(client, "cook_then_air")[0]

    # 카드가 뜬 뒤 정의가 '풍량 강' → '풍량 중'으로 바뀌었다.
    engine = get_scenario_engine()
    from dataclasses import replace

    engine.catalog.replace_definition(replace(COOK_THEN_AIR, steps=(
        ScenarioStep("air_purifier", ControlRoute.THINQ, "set_wind_strength", (("wind_strength", "MID"),)),
    )))
    response = client.post(f"/suggestions/{card['id']}/approve")
    assert response.status_code == 409
    assert "다시" in response.json()["detail"]
    assert deps.get_service().thinq_controller.client.controls == []
    assert _scenario_cards(client, "cook_then_air") == []  # 카드를 내리고 재승인을 기다린다


def test_service_refuses_approved_command_that_differs():
    now = datetime.now(timezone.utc)
    approved = ApprovedCommand(HIGH, "a", now, "공기청정기 풍량 강")
    tampered = ApprovedCommand(HIGH, "a", now, "공기청정기 풍량 강")
    object.__setattr__(tampered, "command", Command.thinq("air_purifier", "set_wind_strength",
                                                         {"wind_strength": "LOW"}))
    assert approved.matches(HIGH)
    assert not tampered.matches(HIGH)


def test_evening_rest_is_a_registered_scenario(client):
    scenarios = {s["scenario_id"]: s for s in client.get("/scenarios").json()}
    assert set(scenarios) >= {"cook_then_air", "evening_rest"}
    card = client.post("/demo/scenario/evening_rest").json()
    assert card["is_demo"] is True
    assert [c["route"] for c in card["commands"]] == ["thinq", "physical"]
    purifier = deps.get_service().thinq_controller.client
    assert purifier.controls == []

    response = client.post(f"/suggestions/{card['id']}/approve")
    assert response.status_code == 200, response.text
    _wait_done(client, response.json()["job_id"])
    run = client.get("/scenarios/last-run").json()["run"]
    assert [s["route"] for s in run["steps"]] == ["thinq", "physical"]
    assert run["steps"][0]["confirmation"] == "state_confirmed"
    # 선풍기는 모의 실행기: 센서 근거 없음 → reported, 실행 환경 mock.
    assert run["steps"][1]["execution_mode"] == "mock"
    assert run["steps"][1]["confirmation"] == "reported"
    history = client.get("/history").json()
    assert {h["route"] for h in history[:2]} == {"thinq", "physical"}
    assert len({h["job_id"] for h in history[:2]}) == 2  # 단계별 job_id가 겹치지 않는다


def test_unconfirmed_step_halts_the_rest(client):
    purifier = deps.get_service().thinq_controller.client
    purifier.drop_state_updates = True
    card = client.post("/demo/scenario/evening_rest").json()
    job = client.post(f"/suggestions/{card['id']}/approve").json()["job_id"]
    status = _wait_done(client, job)
    run = client.get("/scenarios/last-run").json()["run"]
    assert run["steps"][0]["status"] == "unconfirmed"
    assert run["steps"][1]["receipt"] == "not_dispatched"
    assert deps.get_service()._system_controllers["fan"].executed == []
    assert status["last_status"] in ("unconfirmed", "failed")


# ── 6. 물리 제안의 승인 고정(결정 #1) ─────────────────────────────────────


def test_physical_suggestion_refuses_changed_resolution():
    from rpi.api.service import SimpleLayService
    from rpi.controller import ClosedLoopController
    from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
    from rpi.intent.mock import FixedClock
    from rpi.intent.log import InMemoryUsageLog
    from rpi.intent.models import PatternConfig, TimeBand
    from rpi.intent.patterns import PatternDetector
    from rpi.intent.rules import RuleBasedIntentResolver
    from rpi.intent.suggestions import ProactiveSuggestionService
    from rpi.verifier import MockVerifier
    from datetime import time as dtime

    class Different(RuleBasedIntentResolver):
        def resolve(self, purpose):
            return ("해동", "시작")

    clock = FixedClock(datetime(2026, 9, 29, 20, tzinfo=timezone.utc))
    grbl = MockGrblClient()
    service = SimpleLayService(
        Different(),
        ClosedLoopController(grbl, MockVerifier([True] * 4), MockAlertSink(), MockSafetyController()),
        clock=clock,
    )
    detector = PatternDetector(InMemoryUsageLog(), clock, PatternConfig(
        minimum_occurrences=3, time_bands=(TimeBand("저녁", dtime(17), dtime(21)),)))
    svc = ProactiveSuggestionService(detector, clock, service, intent_resolver=RuleBasedIntentResolver())
    card = svc.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    assert card.steps == ("즉석밥", "시작")
    with pytest.raises(ApprovalMismatchError):
        svc.approve_submit(card.suggestion_id)
    assert grbl.commands == []
    assert svc.pending() == ()  # 카드를 내리고 재승인을 받는다


# ── 7. PAT는 로그·이력에 남지 않는다 ───────────────────────────────────────


def test_pat_never_in_logs_history_or_responses(client, caplog):
    caplog.set_level(logging.DEBUG)
    job = client.post("/execute", json={"text": "강풍으로 바꿔줘", "appliance_id": "air_purifier"})
    _wait_done(client, job.json()["job_id"])
    bodies = [
        client.get("/thinq/devices").text,
        client.get("/history").text,
        client.get("/history.csv").text,
        client.get("/status").text,
        client.get("/readiness/air_purifier").text,
        client.get("/scenarios/last-run").text,
    ]
    assert all(SECRET_PAT not in body for body in bodies)
    assert SECRET_PAT not in caplog.text
    config = deps.get_service().thinq_controller
    assert SECRET_PAT not in repr(vars(config))


def test_pat_not_persisted_in_sqlite(monkeypatch, tmp_path_factory):
    import sqlite3

    base = tmp_path_factory.mktemp("thinq-db")
    db_path = base / "simplelay.db"
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(db_path))
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    _reset()
    deps.get_db.cache_clear()
    try:
        from rpi.main import app

        c = TestClient(app)
        job = c.post("/execute", json={"text": "강풍으로 바꿔줘", "appliance_id": "air_purifier"})
        _wait_done(c, job.json()["job_id"])
        assert c.get("/history").json()[0]["route"] == "thinq"
        deps.get_db().close()
        raw = db_path.read_bytes()
        assert SECRET_PAT.encode() not in raw
        conn = sqlite3.connect(db_path)
        rows = conn.execute("SELECT route, confirmation FROM job_history_command").fetchall()
        conn.close()
        assert ("thinq", "state_confirmed") in rows
    finally:
        deps.get_db.cache_clear()
        _reset()
