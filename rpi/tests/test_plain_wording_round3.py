"""쉬운 말 3차(2026-10-18, 평가 3차 지적) — '풍량'을 서버 뿌리에서 '바람 세기'로, 규칙 이름은 시나리오 ID로, 기록 제목 문체.

- 공기청정기 바람 세기 기능 이름(라벨)·카드 질문·카드 요약·결과 문장에 '풍량'·'강풍'이 없다.
- 카드 질문 문장은 '다시 받지 않기' 목록·승인 횟수의 열쇠다 — 문장을 바꿔도 옛 문장으로 남은 기록이 이어진다.
- 자동 실행 규칙 이름은 저장값이 아니라 시나리오 ID로 정한다(지금 카탈로그에 없어도 화살표 없는 이름).
- 기록(``/history``) 제목: 옛 자동 실행 동작 문장·옛 질문은 보여 줄 때만 지금 문체로, 화면에서 누른 LG 가전 조작은
  '공기청정기 조작'·'강풍으로 바꿔줘' 대신 한 일 문장으로. 사용 기록(습관 근거)의 목적 문장은 그대로.
"""

from __future__ import annotations

import time
from datetime import datetime, time as dtime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.air_quality_wiring import reset_air_quality
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, ProactiveSuggestionService, TimeBand
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.suppression import InMemorySuppressionStore
from rpi.routines.wiring import reset_routines
from rpi.scenarios import catalog
from rpi.scenarios.catalog import COOK_DONE_AIR
from rpi.services.thinq.bindings import AIR_PURIFIER_CAPABILITIES
from rpi.services.thinq import wording

OLD_QUESTION = "공기청정기 풍량을 강으로 바꿀까요?"
NEW_QUESTION = "공기청정기 바람을 세게 할까요?"
KST = timezone(timedelta(hours=9))


def _wind():
    return next(c for c in AIR_PURIFIER_CAPABILITIES if c.action == "set_wind_strength")


# ── 1. '풍량' → '바람 세기' ────────────────────────────────────────────────────────────────


def test_wind_strength_is_named_like_the_phone_and_kiosk_buttons():
    cap = _wind()
    assert cap.label == "바람 세기"
    assert [cap.value_label(v) for v in ("LOW", "MID", "HIGH", "AUTO")] == ["약", "중", "강", "자동"]
    assert cap.setting_phrase("HIGH") == "바람 세기 강"
    assert wording.changed_sentence(cap.setting_phrase("HIGH")) == "바람 세기 강으로 바꿨어요."
    assert wording.already_sentence(cap.setting_phrase("HIGH")) == (
        "이미 바람 세기 강으로 설정돼 있어요. 그래서 보내지 않았어요.")
    assert wording.target_seen_sentence(cap.setting_phrase("LOW")) == "바람 세기 약으로 설정된 것을 확인했어요."


def test_no_scenario_card_or_capability_says_pungryang():
    known = (*catalog.DEFAULT_SCENARIOS, *catalog.V2_SCENARIOS)
    texts = [d.question for d in known] + [d.name for d in known]
    texts += [c.label for c in AIR_PURIFIER_CAPABILITIES]
    texts += [c.setting_phrase(v) for c in AIR_PURIFIER_CAPABILITIES for v in c.allowed]
    for text in texts:
        assert "풍량" not in text, text
        assert "→" not in text and "가열 종료" not in text, text
    for value in ("LOW", "HIGH"):
        assert "풍" not in _wind().setting_phrase(value)
    assert COOK_DONE_AIR.question == NEW_QUESTION


# ── 1-호환. 질문 문장이 열쇠인 기록 ─────────────────────────────────────────────────────────


def _suggestions(store):
    clock = FixedClock(datetime(2026, 10, 18, 12, 0, tzinfo=KST))
    detector = PatternDetector(InMemoryUsageLog(()), clock, PatternConfig(minimum_occurrences=3, time_bands=(TimeBand("낮", dtime(10, 0), dtime(14, 0)),)))
    return ProactiveSuggestionService(detector, clock, MockPurposeExecutor(result="executed"),
                                      suppression_store=store)


def _offer(svc):
    command = COOK_DONE_AIR.commands()[0]
    return svc.create_scenario_suggestion(
        scenario_id=COOK_DONE_AIR.scenario_id, purpose=COOK_DONE_AIR.question, commands=(command,),
        summaries=("공기청정기 바람 세기 강",), reason="전자레인지가 멈춘 것 같아요.", is_demo=False)


def test_old_question_maps_to_the_new_one_and_nothing_else_changes():
    current_question = catalog.current_question
    assert current_question(OLD_QUESTION) == NEW_QUESTION
    assert current_question(f"  {OLD_QUESTION} ") == NEW_QUESTION
    assert current_question("공기청정기를 강풍으로 바꿀까요?") == "공기청정기를 강풍으로 바꿀까요?"
    assert current_question("공기청정기 켜줘") == "공기청정기 켜줘"
    assert current_question(None) is None


def test_mute_saved_with_the_old_question_still_blocks_the_card():
    """옛 서버에서 '다시 받지 않기'한 기록(DB에 옛 문장)이 새 문장 카드도 막는다."""
    store = InMemorySuppressionStore()
    store.mute(OLD_QUESTION)
    svc = _suggestions(store)
    assert _offer(svc) is None
    # 설정 화면 목록은 지금 문장 한 줄로.
    assert svc.muted_purposes() == (NEW_QUESTION,)
    # 새 문장으로 풀면 옛 문장 기록도 풀린다 — 다시 받는다.
    svc.unmute(NEW_QUESTION)
    assert store.muted() == frozenset()
    assert _offer(svc) is not None


def test_mute_with_the_new_question_is_listed_once():
    store = InMemorySuppressionStore()
    store.mute(OLD_QUESTION)
    store.mute(NEW_QUESTION)
    svc = _suggestions(store)
    assert svc.muted_purposes() == (NEW_QUESTION,)
    svc.unmute(OLD_QUESTION)
    assert store.muted() == frozenset()


def test_approvals_saved_with_the_old_question_are_still_counted():
    from rpi.scenarios.engine import ScenarioEngine

    events = [{"purpose": OLD_QUESTION, "action": "submitted"},
              {"purpose": NEW_QUESTION, "action": "execution_returned"},
              {"purpose": OLD_QUESTION, "action": "dismissed"},
              {"purpose": "공기청정기를 강풍으로 바꿀까요?", "action": "submitted"}]
    fake = SimpleNamespace(_suggestions=SimpleNamespace(feedback_events=lambda limit: {"events": events}))
    assert ScenarioEngine._approval_count(fake, COOK_DONE_AIR) == 2


# ── 2. 규칙 이름 ────────────────────────────────────────────────────────────────────────


def test_rule_name_comes_from_the_scenario_id_not_a_stored_name():
    scenario_name = catalog.scenario_name
    assert scenario_name("cook_done_air") == "전자레인지가 멈추면 공기청정기 세게"
    assert scenario_name("cook_then_air") == "조리 뒤 공기청정기"
    assert scenario_name("wash_then_dry") == "세탁 끝나면 제습기"
    assert scenario_name("unknown") == "자동 실행"
    assert scenario_name(None) == "자동 실행"


def test_rule_payload_name_without_the_scenario_engine_is_still_the_new_name():
    """시나리오 엔진·카탈로그를 못 읽어도(다른 구성으로 켠 허브) 규칙 이름은 ID로 — '자동 실행'·옛 이름이 아니다."""
    from rpi.routines.auto_rules import AutoRule, AutoRuleEngine, AutoRuleStore, SeenEvents

    clock = FixedClock(datetime(2026, 10, 18, 12, 0, tzinfo=KST))
    engine = AutoRuleEngine(AutoRuleStore(), SeenEvents(), SimpleNamespace(_appliance_registry=None), clock,
                            scenarios=lambda: None)
    rule = AutoRule("ar-1", "cook_done_air", "microwave", "heat_complete", "air_purifier", "k",
                    "DEVICE_AIR_PURIFIER", "set_wind_strength", "wind_strength", "HIGH")
    assert engine.payload(rule)["name"] == "전자레인지가 멈추면 공기청정기 세게"


# ── 4. 기록 제목 문체 ─────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(("stored", "shown"), [
    ("자동 실행 · 공기청정기 전원 끄기", "자동 실행 · 공기청정기를 꺼요"),
    ("자동 실행 · 공기청정기 전원 켜기", "자동 실행 · 공기청정기를 켜요"),
    ("자동 실행 · 공기청정기(모의) 전원 켜기", "자동 실행 · 공기청정기(모의)를 켜요"),
    ("자동 실행 · 공기청정기 풍량 강으로", "자동 실행 · 공기청정기 바람을 세게 해요"),
    ("자동 실행 · 공기청정기 풍량 약으로", "자동 실행 · 공기청정기 바람을 약하게 해요"),
    ("자동 실행 · 공기청정기 운전 모드 청정으로", "자동 실행 · 공기청정기를 청정 모드로 바꿔요"),
    ("자동 실행 · 공기청정기 바람 세기 바꾸기", "자동 실행 · 공기청정기 바람 세기를 바꿔요"),
    (OLD_QUESTION, NEW_QUESTION),
    # 지금 형식·사람이 한 말·루틴은 그대로.
    ("자동 실행 · '아침 공기청정기 끄기' 루틴", "자동 실행 · '아침 공기청정기 끄기' 루틴"),
    ("자동 실행 · 공기청정기를 켜요", "자동 실행 · 공기청정기를 켜요"),
    ("공기청정기 켜줘", "공기청정기 켜줘"),
    ("'저녁 공기청정기 켜기' 루틴을 실행할까요?", "'저녁 공기청정기 켜기' 루틴을 실행할까요?"),
    (None, None),
    ("", ""),
])
def test_stored_purposes_are_shown_in_the_current_style(stored, shown):
    from rpi.routines.auto_rules import display_purpose

    assert display_purpose(stored) == shown


# ── API: /history ─────────────────────────────────────────────────────────────────────────

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_control_arbiter, deps.get_presence_state_machine, deps.get_appliance_done_log,
)


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()
    reset_air_quality()


@pytest.fixture()
def api(monkeypatch):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_V2_SCENARIOS", "SIMPLELAY_LOCAL_APPLIANCES",
                 "SIMPLELAY_ACT_MODE", "SIMPLELAY_ROUTINE_DONE_SENSORS", "SIMPLELAY_PRESENCE_GATING",
                 "SIMPLELAY_AIR_POLL_SECONDS", "SIMPLELAY_PAUSE_CARRYOVER_UNTIL"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.3")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _wait_done(client, job_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish")


def _command(api, action, args):
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": action, "args": args})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    return api.get("/history").json()[0]


def test_screen_taps_on_the_purifier_are_titled_by_what_was_done(api):
    """'공기청정기 조작'(목적 없음)·'강풍으로 바꿔줘'(대응표 명령 문장) 대신 자동 실행과 같은 한 일 문장."""
    name = api.get("/appliances").json()
    name = next(a["name"] for a in name if a["id"] == "air_purifier")
    assert _command(api, "set_power", {"power": "POWER_ON"})["purpose"] == f"{name}를 켜요"
    assert _command(api, "set_wind_strength", {"wind_strength": "MID"})["purpose"] == f"{name} 바람을 중간으로 해요"
    assert _command(api, "set_wind_strength", {"wind_strength": "HIGH"})["purpose"] == f"{name} 바람을 세게 해요"
    # 습관 근거(사용 기록)는 대응표 목적 문장 그대로 — 루틴 초안·패턴 열쇠가 바뀌지 않는다.
    purposes = [r.purpose for r in deps.get_usage_log().records()]
    assert "공기청정기 켜줘" in purposes and "강풍으로 바꿔줘" in purposes


def test_history_shows_old_stored_purposes_in_the_current_style(api):
    from rpi.services.history import JobHistoryEntry

    store = deps.get_job_history()
    at = datetime(2026, 10, 17, 7, 0, 5, tzinfo=KST)
    for job, purpose in (("j-old-auto", "자동 실행 · 공기청정기 전원 끄기"), ("j-old-card", OLD_QUESTION)):
        store.append(JobHistoryEntry(job_id=job, finished_at=at, purpose=purpose, status="succeeded", buttons=()))
    shown = {e["job_id"]: e for e in api.get("/history").json()}
    assert shown["j-old-auto"]["purpose"] == "자동 실행 · 공기청정기를 꺼요"
    assert shown["j-old-card"]["purpose"] == NEW_QUESTION
    # 시각은 저장한 그대로(오프셋 포함) — 한국 시각 07:00:05가 다른 시각으로 바뀌어 나가지 않는다.
    assert shown["j-old-auto"]["finished_at"] == "2026-10-17T07:00:05+09:00"
    # 저장값은 고치지 않는다.
    assert {e.purpose for e in store.recent(10)} >= {"자동 실행 · 공기청정기 전원 끄기", OLD_QUESTION}
