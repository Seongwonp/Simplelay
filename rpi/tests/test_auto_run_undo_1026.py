"""자동 실행 '되돌리기'(2026-10-26, 맡기기 신뢰 강화 1).

맡긴 일(시각 규칙)이 알아서 끝나면 결과 알림이 5분 동안 '되돌리기'를 보인다. 누르면
- 그 일의 맡기기(자동 실행 규칙)를 끄고 루틴은 그대로 둔다 — 다음 회차는 카드로 다시 묻는다.
- 반대 동작이 분명할 때만 보통 승인 실행 경로로 되돌린다: 전원 켜기↔끄기, 바람 세기·모드는 보내기 전에 **본** 원래 값.
- 이미 그 값이라 보내지 않은 실행은 되돌릴 것이 없어 끄기만 한다. 비상정지가 걸려 있으면 보내지 않는다(끄기는 한다).
- 5분이 지나면 409, 두 번째 누름도 409.

모의 ThinQ·가짜 시계(벽시계와 허브 단조 시계를 함께 옮긴다). 실제 가전으로 확인한 것이 아니다.
"""

from __future__ import annotations

from datetime import timedelta

from rpi.api import deps
from rpi.tests.test_cook_done_card import _wait_done
from rpi.tests.test_thinq_time_auto_rule import (  # noqa: F401 -- 픽스처
    AT_2300,
    _allowed_time_rule,
    _allow,
    _controls,
    _manual_card,
    _move,
    _routine,
    _routine_cards,
    _thinq_step,
    _tick,
    _wait_run,
    api,
    clock,
    hub,
)


def _auto_run(api, clock, hub, seconds=2):
    _move(clock, hub, AT_2300 + timedelta(seconds=seconds))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    _wait_done(api, run["job_id"])
    return run


def _last(api):
    return api.get("/status").json()["last_auto_run"]


def _undo(api, run_id):
    return api.post(f"/routines/auto-runs/{run_id}/undo")


def test_power_on_auto_run_offers_undo_for_five_minutes_and_undo_turns_off_and_hands_back(api, clock, hub):
    routine = _allowed_time_rule(api, clock, hub)
    run = _auto_run(api, clock, hub)
    last = _last(api)
    assert last["run_id"] == run["job_id"] and last["undone"] is False
    assert 299 <= last["undo_remaining_s"] <= 300
    sent = len(_controls())

    res = _undo(api, run["job_id"])
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["message"] == "되돌리고, 이 일은 다시 물어볼게요." and body["inverse_sent"] is True
    _wait_done(api, body["job_id"])
    assert _controls()[sent:] == [(_controls()[-1][0], {"operation": {"airPurifierOperationMode": "POWER_OFF"}})]
    # 맡기기는 꺼지고 루틴은 남는다(물어보기).
    rule, = api.get("/routines/auto-rules").json()
    assert rule["enabled"] is False and "다시 물어볼게요" in rule["disabled_reason"]
    assert api.get(f"/routines/{routine['id']}").json()["enabled"] is True
    assert _last(api)["undo_remaining_s"] is None and _last(api)["undone"] is True
    # 되돌린 실행은 습관 기록(직접 사용)에 들어가지 않는다 — '밤에 끄기' 습관을 만들지 않게.
    assert not any(r.purpose.startswith("되돌리기") for r in deps.get_usage_log().records())
    # 두 번째 누름은 409.
    assert _undo(api, run["job_id"]).status_code == 409
    # 다음 날 같은 시각은 카드로 묻는다(자동으로 하지 않는다).
    _move(clock, hub, AT_2300 + timedelta(days=1, seconds=2))
    _tick(clock.value)
    assert len(_routine_cards(api)) == 1


def test_undo_after_five_minutes_is_409_and_changes_nothing(api, clock, hub):
    _allowed_time_rule(api, clock, hub)
    run = _auto_run(api, clock, hub)
    sent = len(_controls())
    _move(clock, hub, clock.value + timedelta(minutes=5, seconds=1))
    assert _last(api)["undo_remaining_s"] is None
    res = _undo(api, run["job_id"])
    assert res.status_code == 409 and "5분" in res.json()["detail"]
    assert len(_controls()) == sent
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is True
    assert _undo(api, "no-such-run").status_code == 404


def test_wind_undo_restores_the_value_seen_before_the_run(api, clock, hub):
    routine = _routine(api, steps=[_thinq_step("set_wind_strength", {"wind_strength": "HIGH"})])
    _allow(api, _manual_card(api, routine["id"]))
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_wind_strength",
                                           "args": {"wind_strength": "MID"}})
    _wait_done(api, res.json()["job_id"])
    run = _auto_run(api, clock, hub)
    assert run["confirmation"] == "state_confirmed" and run["before_value"] == "MID"
    body = _undo(api, run["job_id"]).json()
    assert body["inverse_sent"] is True
    _wait_done(api, body["job_id"])
    assert _controls()[-1][1] == {"airFlow": {"windStrength": "MID"}}


def test_wind_undo_without_a_seen_value_only_turns_off_the_hand_over(api, clock, hub, monkeypatch):
    routine = _routine(api, steps=[_thinq_step("set_wind_strength", {"wind_strength": "HIGH"})])
    _allow(api, _manual_card(api, routine["id"]))
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_wind_strength",
                                           "args": {"wind_strength": "MID"}})
    _wait_done(api, res.json()["job_id"])
    run = _auto_run(api, clock, hub)
    from rpi.routines.wiring import get_auto_rule_engine

    engine = get_auto_rule_engine()
    with engine._lock:  # 보내기 전 값을 몰랐던 실행(조회 실패 → state_confirmed_unknown_before)과 같다
        next(e for e in engine._runs if e.get("run_id") == run["job_id"])["before_value"] = None
    sent = len(_controls())
    body = _undo(api, run["job_id"]).json()
    assert body["inverse_sent"] is False and body["message"] == "자동 실행을 껐어요. 이 일은 다시 물어볼게요."
    assert len(_controls()) == sent
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is False


def test_already_at_target_run_has_nothing_to_send_back(api, clock, hub):
    _allowed_time_rule(api, clock, hub)
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_power",
                                           "args": {"power": "POWER_ON"}})
    _wait_done(api, res.json()["job_id"])
    run = _auto_run(api, clock, hub)
    assert run["confirmation"] == "already_at_target"
    sent = len(_controls())
    body = _undo(api, run["job_id"]).json()
    assert body["inverse_sent"] is False
    assert len(_controls()) == sent  # 켜져 있던 것을 끄지 않는다


def test_estop_latched_blocks_the_inverse_but_still_turns_off_the_hand_over(api, clock, hub, monkeypatch):
    _allowed_time_rule(api, clock, hub)
    run = _auto_run(api, clock, hub)
    sent = len(_controls())
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True, raising=False)
    body = _undo(api, run["job_id"]).json()
    assert body["inverse_sent"] is False and "비상정지" in body["message"]
    assert len(_controls()) == sent
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is False


def test_blocked_auto_run_offers_no_undo(api, clock, hub):
    _allowed_time_rule(api, clock, hub)
    assert api.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"}).status_code == 200
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert run.get("run_id") is None and run["undo_remaining_s"] is None
