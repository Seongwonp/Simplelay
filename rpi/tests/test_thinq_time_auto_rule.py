"""ThinQ 사용 기록 → 시각 루틴 초안 → '다음부터도 자동으로'(시각 규칙) — 2026-10-16 사용자 승인 기능.

1. 사용자가 낮은 위험 ThinQ 명령(공기청정기 켜기 등)을 비슷한 시각에 직접 여러 날 쓰면, 그 시각의 루틴 초안이 생긴다
   (ThinQ 명령 한 단계, 승인 루틴). 저장만으로는 실행하지 않고 자동 실행도 켜지지 않는다.
2. 그 시각 루틴의 카드에서 '이번에 실행하고 다음부터 자동으로'를 고르면, 다음 정해진 시각에 **카드 없이** 같은 자동 실행
   경로(조용한 시간·비상정지·정지 세대·지문·전송권·같은 시각 한 번·사건 나이·허용 전후 경계)로 보낸다.
   버튼 누름(물리) 단계는 자동 실행 대상이 아니다.

전부 모의 ThinQ(프로세스 안 모의 클라이언트)·가짜 시계다. 벽시계(``deps._clock``)와 허브 단조 시계를 함께 옮기고
``get_routine_engine().tick(now)``를 직접 부른다. 실제 ThinQ 클라우드·실가전으로 확인한 것이 아니다.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageOutcome, UsageRecord, UsageSource
from rpi.tests.test_cook_done_card import _env, _reset, _wait_done

KST = timezone(timedelta(hours=9))
# 2026-10-14(수) 12:00 — 야간(21~06시) 밖이라 지금 뜨는 습관 카드와 섞이지 않는다.
NOON = datetime(2026, 10, 14, 12, 0, tzinfo=KST)
AT_2300 = NOON.replace(hour=23, minute=0)
COOK_CAVEAT = "멈춤은 전력이 줄어든 것으로 판단해요. 조리 완료가 아닐 수 있어요."


class _Clock:
    def __init__(self, now):
        self.value = now

    def now(self):
        return self.value


class _Hub:
    """이 허브의 가짜 단조 시계 — 벽시계와 함께 옮긴다."""

    def __init__(self) -> None:
        self.now = 10_000.0


@pytest.fixture()
def clock(monkeypatch):
    fixed = _Clock(NOON)
    monkeypatch.setattr(deps, "_clock", fixed)
    return fixed


@pytest.fixture()
def hub():
    from rpi.services.event_clock import reset_event_clock

    fake = _Hub()
    reset_event_clock(lambda: fake.now)
    yield fake
    reset_event_clock()


def _move(clock, hub, when: datetime) -> None:
    hub.now += (when - clock.value).total_seconds()
    clock.value = when


def _prepare(monkeypatch, db_path=None):
    _env(monkeypatch, "mock")
    monkeypatch.delenv("SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S", raising=False)
    if db_path is not None:
        monkeypatch.setenv("SIMPLELAY_DB_PATH", str(db_path))
    deps.get_db.cache_clear()
    _reset()


@pytest.fixture()
def api(monkeypatch, clock, hub):
    _prepare(monkeypatch)
    from rpi.main import app

    yield TestClient(app)
    _reset()


@pytest.fixture()
def db_api(monkeypatch, tmp_path, clock, hub):
    _prepare(monkeypatch, tmp_path / "simplelay.db")
    from rpi.main import app

    yield TestClient(app)
    _reset()
    deps.get_db.cache_clear()


def _restart(monkeypatch, *, clean: bool):
    """프로세스 재시작 흉내 — 깨끗한 종료면 규칙 쓰기를 마치고 세션 표시를 닫는다. 새 프로세스 표시·새 시작 시각."""
    from uuid import uuid4

    from rpi.routines import auto_rules
    from rpi.routines.wiring import close_auto_rules_if_any
    from rpi.services.event_clock import get_event_clock, reset_event_clock

    if clean:
        assert close_auto_rules_if_any() is True
    mono = get_event_clock().monotonic
    _reset()
    deps.get_db.cache_clear()
    monkeypatch.setattr(auto_rules, "PROCESS_SESSION", uuid4().hex)
    reset_event_clock(mono)  # 새 프로세스의 시작 시각 = 지금 허브 시각
    from rpi.main import app

    return TestClient(app)


# ── 헬퍼 ─────────────────────────────────────────────────────────────────────


def _use(days, *, purpose="공기청정기 켜줘", hour=23, minute=0, mode=ExecutionMode.REAL,
         source=UsageSource.DIRECT, appliance="air_purifier"):
    log = deps.get_usage_log()
    for d in days:
        at = (NOON - timedelta(days=d)).replace(hour=hour, minute=minute)
        log.append(UsageRecord(at, purpose, UsageOutcome.SUCCEEDED, appliance_id=appliance,
                               execution_mode=mode, source=source))


def _candidates(api):
    res = api.get("/routines/candidates")
    assert res.status_code == 200, res.text
    return res.json()


def _thinq_step(action="set_power", args=None):
    return {"kind": "thinq_command", "appliance_id": "air_purifier", "action": action,
            "args": args if args is not None else {"power": "POWER_ON"}}


def _routine(api, *, steps=None, trigger=None, conditions=None, name="밤 공기청정기"):
    body = {"name": name, "steps": steps or [_thinq_step()],
            "trigger": trigger or {"kind": "time", "days": list(range(7)), "time": "23:00"},
            "mode": "approve"}
    if conditions is not None:
        body["conditions"] = conditions
    res = api.post("/routines", json=body)
    assert res.status_code == 201, res.text
    return res.json()


def _routine_cards(api):
    return [s for s in api.get("/suggestions").json() if (s.get("scenario_id") or "").startswith("routine:")]


def _manual_card(api, routine_id):
    res = api.post(f"/routines/{routine_id}/trigger")
    assert res.status_code == 200, res.text
    card_id = res.json()["suggestion"]["id"]
    return next(s for s in api.get("/suggestions").json() if s["id"] == card_id)


def _allow(api, card):
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow",
                   json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"]})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    return res.json()


def _power_off(api):
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_power",
                                           "args": {"power": "POWER_OFF"}})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])


def _controls():
    from rpi.api.thinq_wiring import get_thinq_client

    return list(get_thinq_client().controls)


def _tick(at):
    from rpi.routines.wiring import get_routine_engine

    return get_routine_engine().tick(at)


def _runs(api):
    return api.get("/routines/auto-rules/runs").json()


def _wait_run(api, pred, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for run in _runs(api):
            if pred(run):
                return run
        time.sleep(0.02)
    raise AssertionError(_runs(api))


def _allowed_time_rule(api, clock, hub):
    """정오에 시각 루틴(매일 23:00 공기청정기 켜기)을 만들고 카드에서 허용한 뒤 공기청정기를 끈다."""
    routine = _routine(api)
    _allow(api, _manual_card(api, routine["id"]))
    _power_off(api)
    return routine


@pytest.fixture()
def submits(monkeypatch, api):
    """실행 서비스·루틴 순서기의 승인 제출 기록(시나리오 ID)."""
    from rpi.api.service import SimpleLayService
    from rpi.routines.runner import RoutineRunner

    calls: list[tuple[str, str | None]] = []
    for owner, label in ((SimpleLayService, "service"), (RoutineRunner, "runner")):
        original = owner.submit_approved

        def counted(self, *args, __label=label, __original=original, **kwargs):
            calls.append((__label, kwargs.get("scenario_id")))
            return __original(self, *args, **kwargs)

        monkeypatch.setattr(owner, "submit_approved", counted)
    return calls


# ── 1~4. 사용 기록 → 시각 루틴 초안 ─────────────────────────────────────────────


def test_thinq_usage_becomes_a_time_draft_with_one_thinq_step(api):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(api)
    assert draft["appliance_id"] == "air_purifier"
    assert draft["steps"] == [_thinq_step()]
    assert draft["ask_time"] == "23:00"
    assert draft["run_choices"][0]["run"] == "ask_at_time"
    assert draft["run_choices"][0]["label"] == "매일 23:00에 물어보기"
    assert draft["buttons"] == ["전원 켜기"]  # 폰은 buttons가 빈 초안을 숨긴다 — 한 줄 표시
    assert draft["key"].startswith("tc-")
    assert draft["evidence"] == "최근 28일 중 23시쯤 4일 공기청정기(모의)를 켰어요"
    for word in ("하셨", "습관이", "당신", "님이"):
        assert word not in draft["evidence"]


@pytest.mark.parametrize("purpose, appliance", [("공기청정기 꺼줘", "air_purifier"),
                                                ("세탁 시작해줘", "thinq_washer")])
def test_only_low_risk_thinq_purposes_become_drafts(api, purpose, appliance):
    _use((1, 2, 3, 4), purpose=purpose, appliance=appliance)
    assert _candidates(api) == []


def test_mock_or_suggested_thinq_records_are_not_evidence(api):
    _use((1, 2))
    _use((3, 4, 5, 6), mode=ExecutionMode.MOCK)
    _use((3, 4, 5, 6), source=UsageSource.SUGGESTION)
    assert _candidates(api) == []


def test_saving_a_thinq_draft_makes_a_time_routine_and_runs_nothing(api, submits):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(api)
    res = api.post(f"/routines/candidates/{draft['key']}/save", json={"name": "밤 공기청정기", "run": "ask_at_time"})
    assert res.status_code == 201, res.text
    routine = res.json()["routine"]
    assert routine["trigger"] == {"kind": "time", "days": [0, 1, 2, 3, 4, 5, 6], "time": "23:00"}
    assert routine["steps"] == [_thinq_step()] and routine["mode"] == "approve"
    assert res.json()["executed"] is False
    assert submits == [] and _controls() == []
    assert api.get("/routines/auto-rules").json() == []
    again = api.post(f"/routines/candidates/{draft['key']}/save", json={"name": "또", "run": "manual"})
    assert again.status_code == 409
    assert _candidates(api) == []  # 같은 ThinQ 명령 루틴이 있으면 초안으로 보이지 않는다


def test_same_thinq_command_routine_already_saved_is_a_duplicate(api):
    _use((1, 2, 3, 4))
    (draft,) = _candidates(api)
    _routine(api, trigger={"kind": "manual"}, name="공기청정기")
    assert _candidates(api) == []
    res = api.post(f"/routines/candidates/{draft['key']}/save", json={"name": "밤", "run": "ask_at_time"})
    assert res.status_code == 409 and "공기청정기" in res.json()["detail"]


# ── 5. 직접 ThinQ 명령은 목적 문장으로 기록된다 ────────────────────────────────────


def test_direct_thinq_command_is_recorded_with_its_purpose(api):
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_power",
                                           "args": {"power": "POWER_ON"}})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    records = [r for r in deps.get_usage_log().records() if r.appliance_id == "air_purifier"]
    assert [(r.purpose, r.source) for r in records] == [("공기청정기 켜줘", UsageSource.DIRECT)]
    # 목적 문장이 없는 명령(대응표에 없는 값)은 기록하지 않는다.
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_job_mode",
                                           "args": {"job_mode": "SLEEP"}})
    _wait_done(api, res.json()["job_id"])
    assert len([r for r in deps.get_usage_log().records() if r.appliance_id == "air_purifier"]) == 1


# ── 6~7. 시각 루틴 카드의 '다음부터도 자동으로' ──────────────────────────────────


def test_time_routine_card_offers_auto_for_a_single_low_risk_thinq_step(api):
    routine = _routine(api)
    offer = _manual_card(api, routine["id"])["auto_rule_offer"]
    assert offer is not None
    assert offer["condition_text"] == "매일 밤 11시에"
    assert offer["action_text"] == "공기청정기(모의)를 켜요"
    assert offer["caveat"] and offer["caveat"] != COOK_CAVEAT
    assert "본체가 꺼져 있었거나 조용한 시간이면 하지 않아요" in offer["caveat"] and "허브" not in offer["caveat"]
    assert len(offer["fingerprint"]) == 64


@pytest.mark.parametrize("variant", ["physical", "extra_note", "conditions", "manual_trigger"])
def test_time_routine_card_has_no_offer_unless_single_low_risk_thinq(api, variant):
    kwargs = {}
    if variant == "physical":
        kwargs["steps"] = [{"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["즉석밥", "시작"]}]
    elif variant == "extra_note":
        kwargs["steps"] = [_thinq_step(), {"kind": "announce", "text": "공기청정기를 켰어요"}]
    elif variant == "conditions":
        kwargs["conditions"] = [{"kind": "environment", "humidity_at_least": 10}]
    else:
        kwargs["trigger"] = {"kind": "manual"}
    routine = _routine(api, **kwargs)
    card = _manual_card(api, routine["id"])
    assert card["auto_rule_offer"] is None


def test_approve_and_allow_saves_a_time_rule_and_this_run_goes_through_the_routine(api, submits):
    routine = _routine(api)
    body = _allow(api, _manual_card(api, routine["id"]))
    assert body["auto_allow"]["ok"] is True
    assert [label for label, _ in submits] == ["runner", "service"]  # 이번 실행은 루틴 순서기로
    (rule,) = api.get("/routines/auto-rules").json()
    assert rule["name"] == "밤 공기청정기"
    assert rule["enabled"] is True
    assert rule["condition_text"] == "매일 밤 11시에"
    # 폰이 조용한 시간과 겹치는 자동 실행을 미리 말할 수 있게 시각을 따로 준다(UI 평가 6차 10/17).
    assert rule["condition_time"] == "23:00"
    assert rule["caveat"] and "늦게 알면 먼저 물어봐요" in rule["caveat"]


# ── 8~13. 다음 시각: 카드 없이 같은 자동 실행 경로 ────────────────────────────────


def test_next_scheduled_time_runs_without_a_card(api, clock, hub, submits):
    routine = _allowed_time_rule(api, clock, hub)
    sent_before = len(_controls())
    submits.clear()
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    assert _tick(clock.value) == []
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert run["status"] == "succeeded"
    assert _routine_cards(api) == []
    assert [s for s in submits if s[0] == "runner"] == []
    service_calls = [s for s in submits if s[0] == "service"]
    assert len(service_calls) == 1 and service_calls[0][1].startswith("auto:")
    assert len(_controls()) == sent_before + 1
    assert "밤 11시가 되어" in " / ".join(run["notices"])
    log = api.get("/routines/log").json()
    assert log[0]["routine_id"] == routine["id"] and log[0]["outcome"] == "auto"


def test_same_occurrence_runs_once_across_ticks_and_a_clean_restart(monkeypatch, db_api, clock, hub):
    api = db_api
    _allowed_time_rule(api, clock, hub)
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    sent = len([r for r in _runs(api) if r["outcome"] == "sent"])
    _move(clock, hub, AT_2300 + timedelta(seconds=20))
    _tick(clock.value)
    api = _restart(monkeypatch, clean=True)
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is True
    _move(clock, hub, AT_2300 + timedelta(seconds=40))
    _tick(clock.value)
    time.sleep(0.2)
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []  # 재시작 뒤 같은 시각 다시 보내지 않음
    assert _routine_cards(api) == []
    assert sent == 1


def test_occurrence_before_allowance_is_held_and_shown_as_a_card(api, clock, hub):
    routine = _routine(api)
    _move(clock, hub, AT_2300 + timedelta(seconds=30))  # 23:00 tick 전에 직접 실행 카드에서 허용
    _allow(api, _manual_card(api, routine["id"]))
    _power_off(api)
    sent = len(_controls())
    _move(clock, hub, AT_2300 + timedelta(seconds=40))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "허락하기 전" in run["reason"]
    assert len(_routine_cards(api)) == 1  # 그 대신 카드(승인 필요)
    assert len(_controls()) == sent


def test_occurrence_before_restart_is_held_and_shown_as_a_card(monkeypatch, db_api, clock, hub):
    api = db_api
    _allowed_time_rule(api, clock, hub)
    _move(clock, hub, AT_2300 + timedelta(seconds=20))
    api = _restart(monkeypatch, clean=True)
    _move(clock, hub, AT_2300 + timedelta(seconds=40))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "다시 켜지기 전" in run["reason"]
    assert len(_routine_cards(api)) == 1
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []


def test_late_tick_beyond_the_age_limit_shows_a_card_instead(api, clock, hub):
    _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    _move(clock, hub, AT_2300 + timedelta(seconds=150))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "늦게 알아서" in run["reason"] and "150초" not in run["reason"]  # 숫자는 화면에 내지 않는다(10/17)
    assert len(_routine_cards(api)) == 1
    assert len(_controls()) == sent


def test_quiet_hours_skip_the_time_auto_run_with_no_card_and_no_rerun(api, clock, hub):
    from rpi.services.quiet_hours import SKIP_REASON

    _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    assert api.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"}).status_code == 200
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert run["reason"] == SKIP_REASON
    assert _routine_cards(api) == []
    assert api.put("/quiet-hours", json={"enabled": False}).status_code == 200
    _move(clock, hub, AT_2300 + timedelta(seconds=60))
    _tick(clock.value)
    time.sleep(0.2)
    assert len(_controls()) == sent
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []
    assert _routine_cards(api) == []


def test_offer_caveat_says_when_the_routine_time_is_inside_quiet_hours(api):
    assert api.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"}).status_code == 200
    routine = _routine(api)
    card = _manual_card(api, routine["id"])  # '지금 실행'은 조용한 시간에도 카드를 만든다
    assert "조용한 시간이라 자동으로 하지 않아요" in card["auto_rule_offer"]["caveat"]


def test_estop_latched_blocks_the_time_auto_run(api, clock, hub, monkeypatch):
    _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True, raising=False)
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "비상정지" in run["reason"]
    assert _routine_cards(api) == []
    assert len(_controls()) == sent


def test_halt_between_decision_and_send_sends_nothing(api, clock, hub, monkeypatch):
    from rpi.routines.wiring import stop_auto_rules_if_any

    _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    service = deps.get_service()
    original = service.submit_approved

    def stop_first(*args, **kwargs):
        stop_auto_rules_if_any("비상정지")  # 판단은 끝났고 아직 보내기 전
        return original(*args, **kwargs)

    monkeypatch.setattr(service, "submit_approved", stop_first)
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "비상정지" in run["reason"]
    time.sleep(0.2)
    assert len(_controls()) == sent
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is False


# ── 14~16. 루틴을 바꾸거나 지우거나 끄면 ─────────────────────────────────────────


@pytest.mark.parametrize("change", ["time", "value", "step", "delete"])
def test_editing_or_deleting_the_routine_voids_the_rule(api, clock, hub, change):
    routine = _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    body = {"name": routine["name"], "steps": [_thinq_step()], "mode": "approve",
            "trigger": {"kind": "time", "days": list(range(7)), "time": "23:00"}}
    at = AT_2300
    if change == "time":
        body["trigger"]["time"] = "23:30"
        at = AT_2300.replace(minute=30)
    elif change == "value":
        body["steps"] = [_thinq_step("set_wind_strength", {"wind_strength": "HIGH"})]
    elif change == "step":
        body["steps"] = [_thinq_step(), {"kind": "announce", "text": "켰어요"}]
    if change == "delete":
        assert api.delete(f"/routines/{routine['id']}").status_code == 200
    else:
        res = api.put(f"/routines/{routine['id']}", json=body)
        assert res.status_code == 200, res.text
    (rule,) = api.get("/routines/auto-rules").json()
    assert rule["enabled"] is False and rule["disabled_reason"]
    if change == "delete":
        return
    _move(clock, hub, at + timedelta(seconds=2))
    _tick(clock.value)
    time.sleep(0.2)
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []
    assert len(_controls()) == sent
    assert len(_routine_cards(api)) == 1  # 다시 카드(승인)로


def test_routine_changed_behind_the_router_is_caught_right_before_running(api, clock, hub):
    """라우터의 철회를 거치지 않고 루틴이 바뀌었어도(철회 실패·다른 경로) 실행 직전 재검사가 규칙을 끄고 카드로 묻는다."""
    from dataclasses import replace

    from rpi.routines.model import RoutineTrigger
    from rpi.routines.wiring import get_routine_store

    routine = _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    store = get_routine_store()
    current = store.get(routine["id"])
    store.save(replace(current, trigger=RoutineTrigger("time", days=tuple(range(5)), time="23:00")))
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is True  # 아직 모름
    _move(clock, hub, AT_2300 + timedelta(seconds=2))  # 10/14(수) — 평일이라 여전히 정해진 날
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "루틴이 바뀌어" in run["reason"]
    (rule,) = api.get("/routines/auto-rules").json()
    assert rule["enabled"] is False and "루틴이 바뀌어" in rule["disabled_reason"]
    assert len(_routine_cards(api)) == 1
    assert len(_controls()) == sent


def test_renaming_the_routine_keeps_the_rule(api, clock, hub):
    routine = _allowed_time_rule(api, clock, hub)
    body = {"name": "새 이름", "steps": [_thinq_step()], "mode": "approve",
            "trigger": {"kind": "time", "days": list(range(7)), "time": "23:00"}}
    assert api.put(f"/routines/{routine['id']}", json=body).status_code == 200
    (rule,) = api.get("/routines/auto-rules").json()
    assert rule["enabled"] is True and rule["name"] == "새 이름"


def test_turning_the_rule_off_from_the_list_brings_back_the_card(api, clock, hub):
    _allowed_time_rule(api, clock, hub)
    sent = len(_controls())
    (rule,) = api.get("/routines/auto-rules").json()
    assert api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False}).status_code == 200
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    time.sleep(0.2)
    assert len(_routine_cards(api)) == 1
    assert len(_controls()) == sent
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []


def test_reenabling_from_the_list_works_only_while_the_routine_is_unchanged(api, clock, hub):
    from rpi.routines.auto_rules import TIME_REENABLE_REFUSED

    routine = _allowed_time_rule(api, clock, hub)
    (rule,) = api.get("/routines/auto-rules").json()
    url = f"/routines/auto-rules/{rule['id']}/enable"
    assert api.post(url, json={"enabled": False}).status_code == 200
    again = api.post(url, json={"enabled": True, "fingerprint": rule["fingerprint"]})
    assert again.status_code == 200 and again.json()["enabled"] is True
    assert api.put(f"/routines/auto-rules/{rule['id']}", json={"value": "POWER_ON"}).status_code == 422
    body = {"name": routine["name"], "steps": [_thinq_step()], "mode": "approve",
            "trigger": {"kind": "time", "days": list(range(7)), "time": "22:30"}}
    assert api.put(f"/routines/{routine['id']}", json=body).status_code == 200
    refused = api.post(url, json={"enabled": True, "fingerprint": rule["fingerprint"]})
    assert refused.status_code == 409 and refused.json()["detail"] == TIME_REENABLE_REFUSED
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is False


def test_physical_time_routine_never_gets_auto(api):
    """회귀 고정: 버튼 누름 시각 루틴은 허용 제안이 없고 허용 요청은 422."""
    from rpi.routines.auto_rules import PHYSICAL_REFUSED

    routine = _routine(api, steps=[{"kind": "press_sequence", "appliance_id": "microwave",
                                    "buttons": ["즉석밥", "시작"]}])
    card = _manual_card(api, routine["id"])
    assert card["auto_rule_offer"] is None
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow", json={"offer_fingerprint": "x"})
    assert res.status_code == 422 and res.json()["detail"] == PHYSICAL_REFUSED
    assert api.get("/routines/auto-rules").json() == []


# ── 17~18. 옛 규칙 지문·재시작 ───────────────────────────────────────────────────

#: 시각 규칙을 넣기 전 코드(da6fcac)로 계산한 옛 '가열 종료' 규칙의 지문 — 바뀌면 저장된 허용이 모두 꺼진다.
LEGACY_FINGERPRINT = "1c3afe7eed2e4f0c2708fdb874a920dfa2c9818e9ae932d4e68ff3a3266831c0"
LEGACY_RULE = {
    "rule_id": "ar-legacy01", "scenario_id": "cook_done_air", "condition_appliance_id": "microwave",
    "condition_event": "appliance_done", "target_appliance_id": "air_purifier",
    "target_device_key": "dk-0123456789ab", "target_device_type": "DEVICE_AIR_PURIFIER",
    "action": "set_wind_strength", "arg": "wind_strength", "value": "HIGH",
}


def test_legacy_appliance_done_fingerprint_is_unchanged():
    from rpi.routines.auto_rules import AutoRule

    rule = AutoRule(**LEGACY_RULE)
    assert rule.fingerprint() == LEGACY_FINGERPRINT
    stored = {**LEGACY_RULE, "enabled": True, "allowed_fingerprint": LEGACY_FINGERPRINT}
    loaded = AutoRule.from_dict(stored)  # 새 칸이 없는 옛 저장값
    assert loaded.condition_kind == "appliance_done"
    assert loaded.fingerprint() == LEGACY_FINGERPRINT
    assert loaded.allowed is True


def test_unclean_restart_holds_time_rules_off(monkeypatch, db_api, clock, hub):
    """회귀 고정: 깨끗이 닫히지 않은 재시작 뒤에는 시각 규칙도 꺼진 채 시작하고 다음 시각에 카드로 묻는다."""
    api = db_api
    _allowed_time_rule(api, clock, hub)
    api = _restart(monkeypatch, clean=False)
    (rule,) = api.get("/routines/auto-rules").json()
    assert rule["enabled"] is False and "갑자기 꺼져서" in rule["disabled_reason"]
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    time.sleep(0.2)
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []
    assert len(_routine_cards(api)) == 1


def test_time_card_is_not_shown_again_after_a_restart_in_the_same_window(monkeypatch, db_api, clock, hub):
    """2026-10-16 결함 ① — '이 회차는 이미 띄웠다'가 메모리에만 있어 10분 창 안에서 재시작하면 같은 카드가 또 떴다."""
    api = db_api
    routine = _routine(api)
    _move(clock, hub, AT_2300 + timedelta(seconds=5))
    assert len(_tick(clock.value)) == 1
    assert len(_routine_cards(api)) == 1
    api = _restart(monkeypatch, clean=True)
    _move(clock, hub, AT_2300 + timedelta(minutes=3))
    assert _tick(clock.value) == []  # 같은 날 같은 시각 회차 — 다시 띄우지 않는다
    assert len([s for s in _routine_cards(api) if s["scenario_id"].startswith(f"routine:{routine['id']}")]) <= 1
    _move(clock, hub, AT_2300 + timedelta(days=1, seconds=5))
    assert len(_tick(clock.value)) == 1  # 다음 날 회차는 그대로 뜬다


def test_history_keeps_the_appliance_name_at_run_time_across_a_restart(monkeypatch, db_api, clock, hub):
    """2026-10-16 결함 ② — 기록이 가전 ID만 남겨 클라이언트가 **지금** 이름을 붙였다(모의로 바꾸자 실제 실행이
    '공기청정기(모의)'로 보였다). 실행할 때의 이름을 기록에 남기고 DB에서도 그대로 읽는다."""
    api = db_api
    name = next(a["name"] for a in api.get("/appliances").json() if a["id"] == "air_purifier")
    _power_off(api)
    assert api.get("/history").json()[0]["appliance_name"] == name
    api = _restart(monkeypatch, clean=True)
    entry = api.get("/history").json()[0]
    assert entry["appliance_id"] == "air_purifier" and entry["appliance_name"] == name


def test_next_run_says_auto_and_which_day_when_the_time_rule_is_on(api, clock, hub):
    """외부 평가 10/16 p02 — '다음 실행'이 자동 실행이 켜진 루틴도 '승인 후 실행'이라 했고(아래 줄은 '자동 실행 켜짐'),
    오늘인지 내일인지 없었다."""
    routine = _routine(api)
    first = api.get("/routines/next").json()[0]
    assert first["routine_id"] == routine["id"]
    assert first["auto"] is False and first["mode_label"] == "승인 후 실행"
    assert first["day_label"] == "오늘"
    _allow(api, _manual_card(api, routine["id"]))
    first = api.get("/routines/next").json()[0]
    assert first["auto"] is True and first["mode_label"] == "자동 실행"
    _move(clock, hub, AT_2300 + timedelta(minutes=30))  # 23:30 — 오늘 회차는 지났다
    assert api.get("/routines/next").json()[0]["day_label"] == "내일"


def test_time_routine_to_power_off_the_purifier_can_be_allowed(api, submits):
    """2026-10-16 사용자 요청 — '밤 22:00 켜고 아침 07:00 끄기'. 시각 규칙에서만 공기청정기 전원 끄기를 자동 실행할 수
    있다(끄기는 위험이 낮다). 가열 종료 같은 사건 규칙은 여전히 켜기만이다(아래 시험)."""
    routine = _routine(api, steps=[_thinq_step(args={"power": "POWER_OFF"})], name="아침 공기청정기 끄기",
                       trigger={"kind": "time", "days": list(range(7)), "time": "07:00"})
    card = _manual_card(api, routine["id"])
    assert card["auto_rule_offer"] is not None
    _allow(api, card)
    rule = api.get("/routines/auto-rules").json()[0]
    assert rule["enabled"] is True and rule["condition_kind"] == "time"


def test_event_rules_still_cannot_power_off():
    from rpi.routines.auto_rules import is_low_risk

    assert not is_low_risk("DEVICE_AIR_PURIFIER", "set_power", "POWER_OFF")
    assert is_low_risk("DEVICE_AIR_PURIFIER", "set_power", "POWER_OFF", time_rule=True)
    assert not is_low_risk("DEVICE_WASHER", "set_power", "POWER_OFF", time_rule=True)


# UI 평가 8차 10/17: 조용한 시간을 켜면 그 시간대의 시각 루틴은 건너뛰는데 '다음 실행'(폰 루틴 탭·키오스크 홈)은
# 여전히 '오늘 23:00 실행'이라고 말했다 — 같은 화면의 규칙 카드와 반대로.
def test_next_run_says_quiet_hours_skip(api, clock, hub):
    _routine(api)  # 매일 23:00
    (before,) = api.get("/routines/next").json()
    assert before.get("quiet_skip") is not True
    assert api.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"}).status_code == 200
    (item,) = api.get("/routines/next").json()
    assert item["quiet_skip"] is True
    assert item["mode_label"] == "조용한 시간이라 건너뜀"
    # 끝 시각은 포함하지 않는다(서버 판정과 같게) — 23:00이 끝이면 그대로 실행.
    assert api.put("/quiet-hours", json={"enabled": True, "start": "21:00", "end": "23:00"}).status_code == 200
    (edge,) = api.get("/routines/next").json()
    assert edge.get("quiet_skip") is not True and edge["mode_label"] != "조용한 시간이라 건너뜀"

