"""습관 제안 → 루틴 초안 저장(2026-10-14, 사용자 승인 4번).

필수: **저장만으로 실행하지 않는다**(실행 요청 0회), 자동 실행 허용이 생기지 않는다, 같은 가전·버튼 순서는
중복 저장을 거절한다, 저장한 후보는 다시 보이지 않는다, 거절한 후보는 일정 기간 다시 묻지 않는다,
모의·추천받아 실행한 기록은 근거에서 빠진다(기존 규칙 유지). 실물 검증은 없다(모의 전자레인지).
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageOutcome, UsageRecord, UsageSource
from rpi.routines.wiring import reset_routines

KST = timezone(timedelta(hours=9))

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


class _Clock:
    def __init__(self, now):
        self.value = now

    def now(self):
        return self.value


# 2026-10-14(수) 12:00 — 아침 시간대(06~10시) 밖이라 지금 뜨는 습관 카드와 섞이지 않는다.
NOON = datetime(2026, 10, 14, 12, 0, tzinfo=KST)


@pytest.fixture()
def clock(monkeypatch):
    fixed = _Clock(NOON)
    monkeypatch.setattr(deps, "_clock", fixed)
    return fixed


@pytest.fixture()
def client(monkeypatch, clock):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", "pat-test-habit-routine")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


@pytest.fixture()
def execution_calls(monkeypatch, client):
    """실행 진입점이 불린 횟수(필수 시험: 저장만으로 실행 요청 0회)."""
    from rpi.api.service import SimpleLayService
    from rpi.routines.runner import RoutineRunner

    calls: list[str] = []
    names = ("execute_purpose", "execute_purpose_for_appliance", "execute_buttons", "submit_purpose",
             "submit_purpose_for_appliance", "submit_buttons", "submit_command", "execute_command",
             "submit_approved", "execute_approved")
    for name in names:
        original = getattr(SimpleLayService, name)

        def counted(self, *args, __name=name, __original=original, **kwargs):
            calls.append(__name)
            return __original(self, *args, **kwargs)

        monkeypatch.setattr(SimpleLayService, name, counted)
    for name in ("submit_approved", "execute_approved"):
        original = getattr(RoutineRunner, name)

        def counted_runner(self, *args, __name=name, __original=original, **kwargs):
            calls.append(f"routine.{__name}")
            return __original(self, *args, **kwargs)

        monkeypatch.setattr(RoutineRunner, name, counted_runner)
    return calls


def _use(days, *, purpose="즉석밥 데워줘", hour=7, minute=30, mode=ExecutionMode.REAL,
         source=UsageSource.DIRECT, outcome=UsageOutcome.SUCCEEDED, appliance="microwave"):
    log = deps.get_usage_log()
    for d in days:
        at = (NOON - timedelta(days=d)).replace(hour=hour, minute=minute)
        log.append(UsageRecord(at, purpose, outcome, appliance_id=appliance,
                               execution_mode=mode, source=source))


def _candidates(client):
    response = client.get("/routines/candidates")
    assert response.status_code == 200, response.text
    return response.json()


def _nothing_ran(client):
    status = client.get("/status").json()
    return status["last_job_id"] is None and not status["running"]


# ── 1. 초안: 가전·버튼 순서가 채워져 있고, 근거는 실제 기록 숫자 ─────────────────────


def test_draft_is_filled_with_appliance_and_button_order(client):
    _use((1, 2, 4, 6), minute=30)
    _use((3,), minute=40)
    (draft,) = _candidates(client)
    assert draft["appliance_id"] == "microwave"
    assert draft["appliance_name"]
    assert draft["buttons"] == ["즉석밥", "시작"]
    assert draft["steps"] == [{"kind": "press_sequence", "appliance_id": "microwave",
                               "buttons": ["즉석밥", "시작"]}]
    assert draft["suggested_name"]
    # 근거는 가전 사용 기록 — 누가 썼는지 모르므로 개인 습관으로 단정하지 않는다.
    assert draft["evidence"] == "최근 28일 중 아침에 5일 사용했어요"
    assert draft["evidence_detail"] == {"window_days": 28, "distinct_days": 5, "occurrences": 5,
                                        "time_band": "아침"}
    for word in ("하셨", "습관이", "당신", "님이"):
        assert word not in draft["evidence"]
    # '정해진 때 물어보기'의 시각 — 기록 시각의 중앙값(5분 단위 내림).
    assert draft["ask_time"] == "07:30"
    assert draft["run_choices"] == [
        {"run": "manual", "label": "직접 실행할 때만"},
        {"run": "ask_at_time", "label": "매일 07:30에 물어보기"},
    ]


def test_mock_suggested_demo_and_failed_records_are_not_evidence(client):
    # 실제 직접 사용은 2일뿐(3일 미만) — 나머지는 근거에서 빠져야 후보가 없다.
    _use((1, 2))
    _use((3, 4, 5, 6), mode=ExecutionMode.MOCK)
    _use((3, 4, 5, 6), source=UsageSource.SUGGESTION)
    _use((3, 4, 5, 6), source=UsageSource.DEMO)
    _use((3, 4, 5, 6), outcome=UsageOutcome.FAILED)
    assert _candidates(client) == []


def test_unknown_or_unmapped_purpose_gives_no_draft(client):
    # 버튼 순서를 결정적으로 알 수 없는 목적은 초안을 만들지 않는다(빈 폼 금지).
    _use((1, 2, 3, 4), purpose="무언가 해줘")
    assert _candidates(client) == []


# ── 2. 저장만으로는 실행하지 않는다(필수) ─────────────────────────────────────────


@pytest.mark.parametrize("run, trigger", [
    ("manual", {"kind": "manual"}),
    ("ask_at_time", {"kind": "time", "days": [0, 1, 2, 3, 4, 5, 6], "time": "07:30"}),
])
def test_saving_a_draft_executes_nothing(client, execution_calls, run, trigger):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    before_cards = client.get("/suggestions").json()
    response = client.post(f"/routines/candidates/{draft['key']}/save",
                           json={"name": "아침 즉석밥", "run": run})
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["routine"]["name"] == "아침 즉석밥"
    assert body["routine"]["mode"] == "approve"
    assert body["routine"]["trigger"] == trigger
    assert body["routine"]["steps"] == draft["steps"]
    assert body["executed"] is False
    # 실행 요청 0회 · 새 카드 0장 · 자동 실행 허용 0건.
    assert execution_calls == []
    assert _nothing_ran(client)
    assert client.get("/suggestions").json() == before_cards
    assert client.get("/routines/auto-rules").json() == []
    assert client.get("/routines/log").json() == []
    # 루틴 목록에 들어갔다.
    assert [r["name"] for r in client.get("/routines").json()] == ["아침 즉석밥"]


def test_saved_draft_routine_cannot_become_an_auto_rule(client, execution_calls):
    """물리 버튼 루틴은 자동 실행 불가 — 카드에 '다음부터 자동으로' 내용이 붙지 않고, 허용은 422."""
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    routine = client.post(f"/routines/candidates/{draft['key']}/save",
                          json={"name": "아침 즉석밥", "run": "manual"}).json()["routine"]
    card = client.post(f"/routines/{routine['id']}/trigger").json()["suggestion"]
    listed = next(s for s in client.get("/suggestions").json() if s["id"] == card["id"])
    assert listed["auto_rule_offer"] is None
    refused = client.post(f"/suggestions/{card['id']}/approve-and-allow", json={"offer_fingerprint": "x"})
    assert refused.status_code == 422
    assert client.get("/routines/auto-rules").json() == []
    assert execution_calls == []  # 카드를 만든 것까지 — 승인 전에는 실행 없음


def test_save_requires_an_explicit_run_choice_and_a_name(client, execution_calls):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    url = f"/routines/candidates/{draft['key']}/save"
    assert client.post(url, json={"name": "아침"}).status_code == 422
    assert client.post(url, json={"name": "아침", "run": "auto"}).status_code == 422
    assert client.post(url, json={"name": "가" * 31, "run": "manual"}).status_code == 422
    assert client.post(url, json={"name": "  ", "run": "manual"}).status_code == 422
    assert client.get("/routines").json() == []
    assert execution_calls == []


# ── 3. 중복·재추천·거절 ───────────────────────────────────────────────────────


def test_saved_draft_is_not_offered_again_even_after_deleting_the_routine(client):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    routine = client.post(f"/routines/candidates/{draft['key']}/save",
                          json={"name": "아침 즉석밥", "run": "manual"}).json()["routine"]
    assert _candidates(client) == []
    assert client.delete(f"/routines/{routine['id']}").status_code == 200
    assert _candidates(client) == []


def test_same_appliance_and_button_order_is_refused_as_duplicate(client, execution_calls):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    # 편집기로 같은 가전·버튼 순서의 루틴을 이미 만들었다(버튼 ID로 적었어도 같은 순서).
    made = client.post("/routines", json={
        "name": "내가 만든 즉석밥", "trigger": {"kind": "manual"},
        "steps": [{"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["즉석밥", "시작"]}]})
    assert made.status_code == 201
    assert _candidates(client) == []  # 이미 있는 순서는 초안으로 보이지 않는다
    refused = client.post(f"/routines/candidates/{draft['key']}/save",
                          json={"name": "아침 즉석밥", "run": "manual"})
    assert refused.status_code == 409
    assert "내가 만든 즉석밥" in refused.json()["detail"]
    assert len(client.get("/routines").json()) == 1
    assert execution_calls == []


def test_double_save_of_the_same_draft_saves_once(client):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    url = f"/routines/candidates/{draft['key']}/save"
    assert client.post(url, json={"name": "아침 즉석밥", "run": "manual"}).status_code == 201
    second = client.post(url, json={"name": "아침 즉석밥", "run": "manual"})
    assert second.status_code in (404, 409)
    assert len(client.get("/routines").json()) == 1


def test_declined_draft_stays_quiet_for_fourteen_days(client, clock):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(client)
    response = client.post(f"/routines/candidates/{draft['key']}/decline")
    assert response.status_code == 200
    assert _candidates(client) == []
    clock.value = NOON + timedelta(days=13, hours=23)
    _use((-13, -12, -11, -10))  # 그사이에도 계속 썼다
    assert _candidates(client) == []
    clock.value = NOON + timedelta(days=14, minutes=1)
    assert [d["key"] for d in _candidates(client)] == [draft["key"]]
    assert client.get("/routines").json() == []  # 거절은 아무것도 저장하지 않는다


def test_unknown_key_is_404(client):
    assert client.post("/routines/candidates/hc-nope/save",
                       json={"name": "x", "run": "manual"}).status_code == 404
    assert client.post("/routines/candidates/hc-nope/decline").status_code == 404


# ── 4. 조용히: 제안을 쉬는 동안·다시 받지 않기로 한 목적은 보이지 않는다 ────────────


def test_drafts_are_hidden_while_suggestions_are_paused(client):
    _use((1, 2, 3, 4))
    assert len(_candidates(client)) == 1
    assert client.post("/dnd", json={"duration_minutes": 60}).status_code == 200
    assert _candidates(client) == []
    client.delete("/dnd")
    assert len(_candidates(client)) == 1


def test_muted_purpose_is_not_offered_as_a_draft(client):
    _use((1, 2, 3, 4))
    deps.get_suppression_store().mute("즉석밥 데워줘")
    assert _candidates(client) == []


# ── 5. 판단(저장·거절)은 재시작 뒤에도 남는다 ───────────────────────────────────


def test_decisions_survive_restart_with_db(monkeypatch, tmp_path, clock):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", "pat-test-habit-routine")
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    try:
        client = TestClient(app)
        _use((1, 2, 3, 4))
        _use((1, 2, 3, 4), purpose="해동해줘", hour=18)
        drafts = {d["buttons"][0]: d for d in _candidates(client)}
        assert set(drafts) == {"즉석밥", "해동"}
        client.post(f"/routines/candidates/{drafts['즉석밥']['key']}/save",
                    json={"name": "아침 즉석밥", "run": "manual"})
        client.post(f"/routines/candidates/{drafts['해동']['key']}/decline")
        _reset()
        client = TestClient(app)
        assert _candidates(client) == []
        assert [r["name"] for r in client.get("/routines").json()] == ["아침 즉석밥"]
        stored = json.loads(deps.get_db().load_setting("routine_candidate_decisions"))
        assert {v["state"] for v in stored.values()} == {"saved", "declined"}
    finally:
        _reset()
        deps.get_db.cache_clear()
