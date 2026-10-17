"""시연 v3 구현 갭 S1~S5(2026-10-06) — docs/시연-v3-구현-갭.md.

전부 모의 수준이다. 실물 콘센트 모듈·세탁기·키오스크 패널로 확인한 것이 아니다.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.routines.wiring import reset_routines

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_control_arbiter, deps.get_presence_state_machine,
)

WASHER = {
    "name": "세탁기", "category": "washing_machine", "rows": 1, "cols": 3,
    "buttons": [
        {"id": "W-01", "label": "전원", "x": 0, "y": 0},
        {"id": "W-02", "label": "표준", "x": 1, "y": 0},
        {"id": "W-03", "label": "시작", "x": 2, "y": 0},
    ],
}


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()


@pytest.fixture()
def thinq_mock(monkeypatch):
    """v3 리허설 구성(§3-1): ThinQ 모의(④ 세탁 완료 이벤트용), v2 시나리오 opt-in 없음."""
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    monkeypatch.delenv("SIMPLELAY_V2_SCENARIOS", raising=False)
    monkeypatch.delenv("SIMPLELAY_LOCAL_APPLIANCES", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.3")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _template(client, template_id):
    return next(t for t in client.get("/routines/templates").json()
                if t["template_id"] == template_id)


def _routine_body(template):
    keys = ("name", "trigger", "conditions", "mode", "steps")
    return {k: template[k] for k in keys if k in template}


# ── S1: v3에 없는 가전 시나리오 ────────────────────────────────────────────


def test_default_catalog_has_no_v2_scenarios(thinq_mock):
    # v4(2026-10-13): 기본 카탈로그는 조리 완료 → 공기청정기(cook_done_air), 2026-10-15부터 공기청정기 센서 공기질
    # (air_quality_high, 꺼져 있을 때 air_quality_power_on)도. v2 셋은 여전히 없다.
    assert [s["scenario_id"] for s in thinq_mock.get("/scenarios").json()] == [
        "cook_done_air", "air_quality_high", "air_quality_power_on"]


def test_wash_complete_makes_the_routine_notice_and_no_dehumidifier_card(thinq_mock):
    c = thinq_mock
    saved = c.post("/routines", json=_routine_body(_template(c, "wash_done")))
    assert saved.status_code == 201, saved.text
    assert c.post("/demo/thinq/event", json={"event": "wash_complete"}).status_code == 200
    deadline = time.monotonic() + 3
    while True:
        events = c.get("/care-events").json()
        if events and events[0]["kind"] == "routine_notice":
            break
        assert time.monotonic() < deadline, events
        time.sleep(0.02)
    assert "빨래를 꺼내" in events[0]["message"]
    assert "연습 알림이에요" in events[0]["message"]
    # 옛 v2 시나리오(wash_then_dry)의 제습기 카드가 끼어들지 않는다.
    assert c.get("/suggestions").json() == []


def test_v2_scenarios_come_back_only_with_explicit_opt_in(thinq_mock, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_V2_SCENARIOS", "1")
    _reset()
    ids = {s["scenario_id"] for s in thinq_mock.get("/scenarios").json()}
    assert ids == {"cook_then_air", "evening_rest", "wash_then_dry"}


# ── S4·S7: washer ID와 템플릿 ─────────────────────────────────────────────


def test_mock_thinq_washer_does_not_take_the_washer_id(thinq_mock):
    c = thinq_mock
    ids = {a["appliance_id"] for a in c.get("/thinq/devices").json()["appliances"]}
    assert ids == {"air_purifier", "thinq_washer", "dehumidifier"}
    res = c.put("/appliances/washer", json=WASHER)
    assert res.status_code == 200, res.text


def test_templates_are_the_four_v3_routines(thinq_mock):
    templates = thinq_mock.get("/routines/templates").json()
    assert [t["template_id"] for t in templates] == ["morning", "outing", "visitor", "wash_done"]
    steps = [s for t in templates for s in t["steps"]]
    assert all(s["kind"] != "thinq_command" for s in steps)
    outing = next(t for t in templates if t["template_id"] == "outing")
    assert outing["steps"][0]["appliance_id"] == "washer"


def test_outing_template_saves_against_a_registered_washer_with_thinq_mock_on(thinq_mock):
    c = thinq_mock
    assert c.put("/appliances/washer", json=WASHER).status_code == 200
    res = c.post("/routines", json=_routine_body(_template(c, "outing")))
    assert res.status_code == 201, res.text


# ── S2: 리허설 런처가 SIMPLELAY_LOCAL_APPLIANCES를 지우지 않는다 ─────────────


def test_simulator_launcher_keeps_local_appliances():
    from rpi.simulator_main import prepare_environment

    env = {"SIMPLELAY_LOCAL_APPLIANCES": "home_mw,washer,intercom",
           "SIMPLELAY_DB_PATH": "prod.db", "SIMPLELAY_DEV_MODE": "1"}
    prepare_environment(env)
    assert env["SIMPLELAY_LOCAL_APPLIANCES"] == "home_mw,washer,intercom"
    assert env["SIMPLELAY_ACT_MODE"] == "simulator"
    assert "SIMPLELAY_DB_PATH" not in env
    assert env["SIMPLELAY_DEV_MODE"] == "false"


@pytest.fixture()
def plain(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    monkeypatch.delenv("SIMPLELAY_LOCAL_APPLIANCES", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def test_register_response_says_not_executable_when_nothing_drives_it(plain):
    # 등록 응답이 '실행 가능'이라 말해 놓고 승인하면 412가 나던 어긋남(10/6).
    body = plain.put("/appliances/home_mw", json=WASHER).json()
    assert body["can_execute"] is False
    assert body["readiness"] != "operable"


def test_register_response_is_executable_for_a_declared_local_appliance(plain, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_LOCAL_APPLIANCES", "home_mw")
    _reset()
    body = plain.put("/appliances/home_mw", json=WASHER).json()
    assert body["can_execute"] is True
    assert body["readiness"] == "operable"


# ── S3: 리허설용 콘센트 모듈 비상 버튼 ──────────────────────────────────────


@pytest.fixture()
def sim(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "simulator")
    _reset()
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.link_tap import LinkFrameTap
    from rpi.services.simulator_controller import SimulatorController

    registry = deps.get_appliance_registry()
    controller = SimulatorController(step_seconds=0, tap=LinkFrameTap(None, transport="in_memory"),
                                     on_alert=deps.get_alert_store().record)
    service = SimpleLayService(RuleBasedIntentResolver(), controller, appliance_registry=registry,
                               care_events=deps.get_care_events())
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        controller.close()
        _reset()


def _until(c, pred, timeout=4.0):
    deadline = time.monotonic() + timeout
    while True:
        status = c.get("/status").json()
        if pred(status):
            return status
        assert time.monotonic() < deadline, status
        time.sleep(0.02)


def test_rehearsal_estop_latches_refuses_execute_and_ack_clears(sim):
    c = sim
    res = c.post("/demo/outlet-estop", json={})
    assert res.status_code == 200, res.text
    assert res.json()["detail"].startswith("연습용 비상 버튼")
    _until(c, lambda s: s["estop_latched"] is True)
    refused = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
    assert refused.status_code == 412 and "비상 버튼이 눌려 있어요" in refused.text
    body = c.post("/stop/ack").json()
    assert body["ok"] is True and body["latched"] is False
    assert c.get("/status").json()["estop_latched"] is False


def test_rehearsal_estop_with_button_held_refuses_ack_until_released(sim):
    c = sim
    assert c.post("/demo/outlet-estop", json={"hold_button": True}).status_code == 200
    _until(c, lambda s: s["estop_latched"] is True)
    held = c.post("/stop/ack").json()
    assert held["ok"] is False and held["reason"] == "estop_button_pressed"
    assert c.delete("/demo/outlet-estop").status_code == 200  # 버튼을 푼다
    released = c.post("/stop/ack").json()
    assert released["ok"] is True and released["latched"] is False


def test_outlet_estop_is_not_reported_as_a_danger_sound(sim):
    c = sim
    c.post("/demo/outlet-estop", json={})
    _until(c, lambda s: s["estop_latched"] is True)
    time.sleep(0.1)
    assert c.get("/alerts").json()["active"] is False
    assert all(e["kind"] != "danger_sound" for e in c.get("/care-events").json())


def test_rehearsal_estop_is_404_outside_mock_and_simulator(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    from rpi.main import app

    c = TestClient(app)
    assert c.post("/demo/outlet-estop", json={}).status_code == 404
    assert c.delete("/demo/outlet-estop").status_code == 404


def test_rehearsal_estop_in_plain_mock_mode_says_use_the_simulator(plain):
    res = plain.post("/demo/outlet-estop", json={})
    assert res.status_code == 409
    assert "simulator" in res.json()["detail"]


# ── S5: 루틴 안내를 키오스크 평소 화면 안내 한 줄(/ambient tip)로 ──────────────


def test_recent_routine_notice_is_the_kiosk_tip(plain):
    deps.get_care_events().append("routine_notice", "루틴 '세탁 끝 알림' — 세탁이 끝났어요", purpose="세탁 끝 알림")
    tip = plain.get("/ambient").json()["tip"]
    assert tip is not None and tip["kind"] == "routine"
    assert "세탁이 끝났어요" in tip["text"]


def test_kiosk_tip_shows_only_the_announcement_not_the_log_line(plain):
    """UI 평가 10/17(실패널): 안내 카드가 "루틴 '세탁 끝 알림' · 직접 실행을 눌렀어요 — 세탁이…" 기록 형식 그대로였다.
    키오스크에는 안내 문장만. 폰 알림함(care-events)에는 전체 문장이 그대로 남는다."""
    full = "루틴 '세탁 끝 알림' · 직접 실행을 눌렀어요 — 세탁이 끝났어요. 빨래를 꺼내 널어 주세요"
    deps.get_care_events().append("routine_notice", full, purpose="세탁 끝 알림")
    tip = plain.get("/ambient").json()["tip"]
    assert tip["text"] == "세탁이 끝났어요. 빨래를 꺼내 널어 주세요"
    assert any(e["message"] == full for e in plain.get("/care-events").json())


def test_kiosk_tip_without_announcement_keeps_the_reason_without_the_log_prefix(plain):
    deps.get_care_events().append("routine_notice", "루틴 '세탁 끝 알림' · 세탁기가 끝난 것 같아요 — 확인해 주세요",
                                  purpose="세탁 끝 알림")
    assert plain.get("/ambient").json()["tip"]["text"] == "확인해 주세요"
    deps.get_care_events().append("routine_notice", "루틴 '세탁 끝 알림' · 세탁기가 끝난 것 같아요", purpose="세탁 끝 알림")
    assert plain.get("/ambient").json()["tip"]["text"] == "세탁 끝 알림: 세탁기가 끝난 것 같아요"


def test_routine_announce_is_also_a_tip(plain):
    deps.get_care_events().append("routine_announce", "약 드실 시간이에요", purpose="아침 데우기")
    tip = plain.get("/ambient").json()["tip"]
    assert tip["kind"] == "routine" and "약 드실 시간이에요" in tip["text"]


def test_old_routine_notice_is_not_a_tip(plain):
    from rpi.main import app
    from rpi.services import CareEventStore

    class Past:
        def now(self):
            return datetime.now(timezone.utc) - timedelta(hours=2)

    old = CareEventStore(Past())
    old.append("routine_notice", "옛날 안내")
    app.dependency_overrides[deps.get_care_events] = lambda: old
    try:
        tip = plain.get("/ambient").json()["tip"]
    finally:
        app.dependency_overrides.pop(deps.get_care_events, None)
    assert tip is None or tip["kind"] != "routine"


def test_danger_alert_still_outranks_a_routine_notice(plain):
    from rpi.services.act_client import AlertEvent

    deps.get_care_events().append("routine_notice", "세탁이 끝났어요")
    deps.get_alert_store().record(AlertEvent(kind="danger_sound", raised=True))
    assert plain.get("/ambient").json()["tip"]["kind"] == "alert"
