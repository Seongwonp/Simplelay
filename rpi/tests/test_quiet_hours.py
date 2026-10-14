"""조용한 시간(2026-10-14, 사용자 승인 5번 — 정책 b '건너뛰기').

필수: 조용한 시간에 온 자동 실행 사건은 **끝난 뒤에도 재실행 0회**. 그 밖에: 직접 실행·정지는 동작, 진행 중 작업 유지,
재시작 뒤 설정 유지, 앱·키오스크가 보는 상태 일치(/quiet-hours = /health), 기존 자동 실행 경계(전송권·정지·사건 나이)와
충돌 없음(기존 시험 그대로). 전부 모의 ThinQ — 실제 CT 판정·실가전이 아니다.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.services.quiet_hours import SKIP_REASON
from rpi.tests.test_auto_rules import _after_allow, _controls, _frame, _runs, _wait_run
from rpi.tests.test_cook_done_card import _cards, _env, _reset, _wait_done


def _clear():
    _reset()
    deps.get_quiet_hours.cache_clear()


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    monkeypatch.delenv("SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S", raising=False)
    _clear()
    from rpi.main import app

    yield TestClient(app)
    _clear()


def _hhmm(dt: datetime) -> str:
    return dt.strftime("%H:%M")


def _quiet_now(api, on: bool = True) -> dict:
    """지금을 덮는 매일 시간대(앞뒤 2시간)를 켜거나 끈다."""
    now = datetime.now().astimezone()
    body = {"enabled": on, "start": _hhmm(now - timedelta(hours=2)), "end": _hhmm(now + timedelta(hours=2))}
    res = api.put("/quiet-hours", json=body)
    assert res.status_code == 200, res.text
    return res.json()


# ── 설정: 서버 영속·검증·앱/키오스크 같은 상태 ─────────────────────────────────


def test_default_is_off_and_bad_values_are_refused(api):
    body = api.get("/quiet-hours").json()
    assert (body["enabled"], body["start"], body["end"], body["active"]) == (False, "22:00", "07:00", False)
    # 실제 범위만 말한다 — '모든 알림이 조용해진다'고 하지 않는다.
    assert "새 제안과 일반 안내 소리만" in body["scope"]
    assert "모든" not in body["scope"]
    for bad in ({"enabled": "yes"}, {"start": "7시"}, {"start": "25:00"}, {"start": "07:00", "end": "07:00"}):
        assert api.put("/quiet-hours", json=bad).status_code == 422, bad
    assert api.get("/quiet-hours").json()["enabled"] is False


def test_phone_and_kiosk_see_the_same_state(api):
    status = _quiet_now(api)
    assert status["active"] is True and status["reason"] == "schedule"
    health = api.get("/health").json()["quiet"]
    assert health == api.get("/quiet-hours").json()
    _quiet_now(api, on=False)
    assert api.get("/health").json()["quiet"]["active"] is False
    # 잠시 쉬기(1·2시간)도 같은 판정으로 보인다.
    api.post("/dnd", json={"duration_minutes": 60})
    quiet = api.get("/health").json()["quiet"]
    assert quiet["active"] is True and quiet["reason"] == "pause" and quiet["pause_until"]


def test_setting_survives_restart(monkeypatch, tmp_path):
    _env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    deps.get_db.cache_clear()
    _clear()
    from rpi.main import app

    try:
        api = TestClient(app)
        assert api.put("/quiet-hours", json={"enabled": True, "start": "21:30", "end": "06:30"}).status_code == 200
        _clear()
        api = TestClient(app)
        body = api.get("/quiet-hours").json()
        assert (body["enabled"], body["start"], body["end"]) == (True, "21:30", "06:30")
    finally:
        _clear()
        deps.get_db.cache_clear()


# ── 제안: 새 카드 없음, 떠 있던 카드는 내림(나중에 한꺼번에 알리지 않음) ─────────────


def test_quiet_drops_pending_cards_and_makes_no_new_ones_and_does_not_revive_them(api):
    card = api.post("/demo/suggest", json={}).json()
    assert [s["id"] for s in api.get("/suggestions").json()] == [card["id"]]
    _quiet_now(api)
    assert api.get("/suggestions").json() == []
    assert api.post("/demo/suggest", json={}).status_code == 409
    _quiet_now(api, on=False)
    assert api.get("/suggestions").json() == []  # 오래된 제안은 버렸다 — 끝나도 다시 뜨지 않는다
    assert api.post(f"/suggestions/{card['id']}/approve").status_code == 404


# ── 자동 실행: 건너뛰고, 끝난 뒤에도 재실행 0회(필수) ──────────────────────────────


def test_auto_run_event_in_quiet_is_skipped_and_never_rerun_after_quiet_ends(api):
    sent = _after_allow(api)
    _quiet_now(api)
    frame = _frame()
    deps.receive_appliance_done(dict(frame))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert run["reason"] == SKIP_REASON
    time.sleep(0.3)
    assert len(_controls()) == sent
    assert _cards(api) == []
    # 조용한 시간이 끝난 뒤: 같은 사건이 다시 와도(재연결·재전송) 실행하지 않는다 — 재실행 0회.
    _quiet_now(api, on=False)
    deps.receive_appliance_done(dict(frame))
    time.sleep(0.3)
    assert len(_controls()) == sent
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []
    assert any(r["outcome"] == "duplicate" for r in _runs(api))
    assert _cards(api) == []
    # 끝난 뒤의 새 사건은 평소대로 자동 실행한다.
    deps.receive_appliance_done(_frame())
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert len(_controls()) == sent + 1


def test_quiet_starting_after_the_decision_but_before_sending_sends_nothing(api, monkeypatch):
    """판단은 조용한 시간 전, 보내기 전에 조용한 시간이 시작 — 아직 시작하지 않은 자동 실행이라 보내지 않는다."""
    sent = _after_allow(api)
    service = deps.get_service()
    original = type(service).submit_approved

    def quiet_then_submit(self, *args, **kwargs):
        _quiet_now(api)  # 판단(_try_run)은 끝났고 실행 게이트는 아직 — 이 사이에 조용한 시간이 시작된다
        return original(self, *args, **kwargs)

    monkeypatch.setattr(type(service), "submit_approved", quiet_then_submit)
    deps.receive_appliance_done(_frame())
    run = _wait_run(api, lambda r: r["outcome"] == "blocked" or (r["outcome"] == "sent" and r.get("status")))
    time.sleep(0.3)
    assert len(_controls()) == sent
    runs = _runs(api)
    assert any(SKIP_REASON in (r.get("reason") or "") for r in runs), runs
    assert run is not None


def test_pause_also_skips_auto_run(api):
    """기존 '제안 잠시 쉬기'(1·2시간)도 같은 판정 — 그 사이 사건은 건너뛴다."""
    sent = _after_allow(api)
    api.post("/dnd", json={"duration_minutes": 60})
    deps.receive_appliance_done(_frame())
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert run["reason"] == SKIP_REASON
    time.sleep(0.2)
    assert len(_controls()) == sent


# ── 유지: 직접 실행·정지·진행 중 작업·루틴 '지금 실행' ──────────────────────────────


def test_direct_execution_and_stop_still_work_in_quiet(api):
    _quiet_now(api)
    res = api.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert res.status_code == 200, res.text
    body = _wait_done(api, res.json()["job_id"])
    assert body["last_status"] == "succeeded"
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_wind_strength",
                                           "args": {"wind_strength": "MID"}})
    assert res.status_code == 200, res.text
    assert _wait_done(api, res.json()["job_id"])["last_status"] == "succeeded"
    assert api.post("/stop").status_code == 200


def test_routine_run_now_is_a_user_request_and_still_makes_its_card(api):
    made = api.post("/routines", json={
        "name": "공기 강", "trigger": {"kind": "manual"},
        "steps": [{"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
                   "args": {"wind_strength": "HIGH"}}]})
    assert made.status_code == 201, made.text
    _quiet_now(api)
    res = api.post(f"/routines/{made.json()['id']}/trigger")
    assert res.status_code == 200, res.text
    card_id = res.json()["suggestion"]["id"]
    assert [s["id"] for s in api.get("/suggestions").json()] == [card_id]
    approved = api.post(f"/suggestions/{card_id}/approve")
    assert approved.status_code == 200, approved.text


def test_quiet_starting_during_a_running_job_does_not_stop_it(api, monkeypatch):
    service = deps.get_service()
    stops: list[str] = []
    for name in ("emergency_stop", "emergency_stop_report"):
        original = getattr(type(service), name)

        def counted(self, *args, __name=name, __original=original, **kwargs):
            stops.append(__name)
            return __original(self, *args, **kwargs)

        monkeypatch.setattr(type(service), name, counted)
    res = api.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    _quiet_now(api)
    assert _wait_done(api, res.json()["job_id"])["last_status"] == "succeeded"
    assert stops == []


def test_time_triggered_routine_makes_no_card_in_quiet(api):
    from rpi.routines.wiring import get_routine_engine

    now = datetime.now().astimezone().replace(second=0, microsecond=0)
    made = api.post("/routines", json={
        "name": "공기 강", "trigger": {"kind": "time", "days": list(range(7)), "time": _hhmm(now)},
        "steps": [{"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
                   "args": {"wind_strength": "HIGH"}}]})
    assert made.status_code == 201, made.text
    _quiet_now(api)
    assert get_routine_engine().tick(now + timedelta(minutes=1)) == []
    assert api.get("/suggestions").json() == []
