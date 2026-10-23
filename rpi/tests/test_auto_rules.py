"""자동 실행 허용 규칙(2026-10-13, 시연 v4) — 조리 완료(확인된 사건) → ThinQ 공기청정기 동작 하나.

필수 조건(지시 10/13): ① 낮은 위험 ThinQ 동작만(물리 누름은 서버 거절) ② 모의 사건 → 모의 ThinQ만(실가전은 real
출처 사건에서만) ③ 같은 사건 1회·오래된 사건 제외·미확인 재전송 없음 ④ 허용은 조건·대상·속성·값에 묶이고 바뀌면 무효
⑤ 비상정지는 새 자동 실행·미전송 후속을 막고 보낸 클라우드 명령을 취소했다고 말하지 않음 ⑥ 조리 완료 근거는 CT 끝 판정.

전부 모의 ThinQ(프로세스 안 모의 클라이언트)다. 실제 CT 판정·실가전으로 확인한 것이 아니다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.controller.models import ExecutionMode
from rpi.services.thinq import MOCK_PURIFIER_ID
from rpi.tests.test_cook_done_card import _cards, _env, _inject, _reset, _wait_done
from rpi.verifier.done_fusion import rehearsal_done_event


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    monkeypatch.delenv("SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _client():
    from rpi.api.thinq_wiring import get_thinq_client

    return get_thinq_client()


def _controls():
    return list(_client().controls)


def _allow(api, card=None):
    card = card or _card(api)
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow",
                   json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"]})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    return res.json()


def _card(api):
    _inject(api, inputs=("power",))
    cards = _cards(api)
    assert len(cards) == 1, cards
    return cards[0]


def _set_wind(api, value):
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_wind_strength",
                                           "args": {"wind_strength": value}})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])


def _rules(api):
    res = api.get("/routines/auto-rules")
    assert res.status_code == 200, res.text
    return res.json()


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


def _frame(source="injected", age_s=0.0, at_s=None, sent=True):
    now = time.monotonic()
    done = rehearsal_done_event("microwave", ["power"], now_s=now - age_s if at_s is None else at_s)
    frame = done.to_frame(time.monotonic_ns() if sent else None)
    frame["source"] = source
    return frame


def _after_allow(api):
    """허용(이번에도 실행) → 공기청정기를 약으로 되돌린 상태. 보낸 제어 수를 돌려준다."""
    _allow(api)
    _set_wind(api, "LOW")
    return len(_controls())


# ── 카드의 허용 제안 · 확인 화면 내용 ─────────────────────────────────────────


def test_card_offers_auto_with_exact_condition_and_action(api):
    card = _card(api)
    offer = card["auto_rule_offer"]
    # A5(10/14): CT 끝 판정은 취소·문 열림으로 가열이 끝난 것과 구분하지 못한다 — 조리 완료라고 말하지 않는다.
    assert offer["condition_text"] == "전자레인지가 데우기를 멈추면"
    assert offer["action_text"] == "공기청정기(모의) 바람을 세게 해요"
    assert len(offer["fingerprint"]) == 64
    assert MOCK_PURIFIER_ID not in str(card)  # 기기 ID 원문을 내보내지 않는다


def test_allow_runs_this_time_and_saves_the_rule(api):
    body = _allow(api)
    assert body["rule"]["enabled"] is True
    assert len(_controls()) == 1
    status = api.get("/status").json()
    assert (status["last_status"], status["last_confirmation"]) == ("succeeded", "state_confirmed")
    rules = _rules(api)
    assert len(rules) == 1
    rule = rules[0]
    assert rule["status_label"] == "자동 실행 켜짐"
    assert rule["condition_text"] == "전자레인지가 데우기를 멈추면"
    assert rule["action_text"] == "공기청정기(모의) 바람을 세게 해요"
    assert _cards(api) == []  # 카드는 승인으로 내려갔다


def test_allow_with_a_stale_fingerprint_saves_nothing_and_runs_nothing(api):
    card = _card(api)
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow", json={"offer_fingerprint": "0" * 64})
    assert res.status_code == 409
    assert _rules(api) == [] and _controls() == []


def test_allow_runs_this_event_once_and_the_rule_applies_only_to_later_events(api):
    """A1(10/14): '허용하고 이번에도 실행'은 사용자의 명시 승인으로 **이 사건을 한 번** 실행한다. 저장된 규칙은 다음 사건부터.
    같은 사건이 허용 뒤 다시 와도(재전송·재연결) 승인 경로와 자동 경로가 각각 실행하지 않는다."""
    frame = _frame()
    deps.receive_appliance_done(dict(frame))
    cards = _cards(api)
    assert len(cards) == 1
    _allow(api, cards[0])
    assert len(_controls()) == 1  # 승인 경로 1회
    deps.receive_appliance_done(dict(frame))  # 같은 사건 재수신 — 이제 규칙이 켜져 있다
    time.sleep(0.3)
    assert len(_controls()) == 1  # 자동 경로가 같은 사건을 또 실행하지 않는다
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []
    assert any(r["outcome"] == "duplicate" for r in _runs(api))
    assert _cards(api) == []
    _set_wind(api, "LOW")  # 이미 강이면 보내지 않는다(already_at_target, 10/14) — 약으로 되돌려 둔다
    deps.receive_appliance_done(_frame())  # 다음 사건부터 규칙이 적용된다
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert len(_controls()) == 3


def test_next_cook_done_runs_without_approval_and_reports_per_device(api):
    sent = _after_allow(api)
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert len(_controls()) == sent + 1
    assert _controls()[-1][1] == {"airFlow": {"windStrength": "HIGH"}}
    assert run["status"] == "succeeded" and run["confirmation"] == "state_confirmed"
    notices = " / ".join(run["notices"])
    assert "멈춘 것 같아요" in notices and "다 익었는지는 봐 주세요" in notices
    assert "데우기가 끝났" not in notices and "조리 완료를 확인" not in notices
    assert "바람 세기 강으로 바꿨어요." in notices
    assert "깨끗" not in notices  # 설정 확인을 공기 상태로 말하지 않는다
    assert _cards(api) == []  # 허용한 조건이면 카드를 다시 띄우지 않는다
    assert api.get("/history").json()[0]["confirmation"] == "state_confirmed"


# ── ③ 같은 사건 1회 · 오래된 사건 · 미확인 재전송 없음 ────────────────────────


def test_the_same_event_delivered_twice_runs_once(api):
    sent = _after_allow(api)
    frame = _frame()
    deps.receive_appliance_done(dict(frame))
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    deps.receive_appliance_done(dict(frame))  # 재연결·중복 알림
    time.sleep(0.3)
    assert len(_controls()) == sent + 1
    assert any(r["outcome"] == "duplicate" for r in _runs(api))


def test_old_event_is_excluded(api):
    sent = _after_allow(api)
    deps.receive_appliance_done(_frame(age_s=1000))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "오래돼서" in run["reason"]
    assert len(_controls()) == sent


def test_status_carries_the_last_auto_run_result_for_the_kiosk(api):
    """C2(10/14): 키오스크가 자동 실행 결과를 짧게 알리도록 /status에 마지막 자동 실행 결과(대상·설정·값·확인 수준)."""
    assert api.get("/status").json()["last_auto_run"] is None
    _after_allow(api)
    assert api.get("/status").json()["last_auto_run"] is None  # 승인 실행은 자동 실행이 아니다
    deps.receive_appliance_done(_frame())
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    auto = api.get("/status").json()["last_auto_run"]
    assert auto["job_id"] == run["job_id"]
    assert (auto["status"], auto["confirmation"], auto["execution_mode"]) == ("succeeded", "state_confirmed", "mock")
    assert (auto["target_name"], auto["setting_label"], auto["value_label"]) == ("공기청정기(모의)", "바람 세기", "강")
    _set_wind(api, "LOW")  # 이미 강이면 보내지 않아 미확인이 나올 수 없다(10/14)
    _client().set_fault(MOCK_PURIFIER_ID, "unconfirmed")
    time.sleep(0.05)  # 사건 키는 RPi4 끝 시각(ms)이다 — 같은 시각이면 같은 사건으로 거른다
    deps.receive_appliance_done(_frame())
    _wait_run(api, lambda r: r.get("status") == "unconfirmed")
    auto = api.get("/status").json()["last_auto_run"]
    assert auto["status"] == "unconfirmed" and auto["job_id"] != run["job_id"]


def test_event_from_before_the_allowance_is_excluded(api):
    sent = _after_allow(api)
    deps.receive_appliance_done(_frame(age_s=60))  # 기한 안이지만 허용하기 전에 끝난 조리
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "허락하기 전" in run["reason"]
    assert len(_controls()) == sent


def test_event_without_rpi4_time_is_not_run(api):
    sent = _after_allow(api)
    deps.receive_appliance_done(_frame(sent=False))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "언제 끝났는지 알 수 없어" in run["reason"]
    assert len(_controls()) == sent


def test_unconfirmed_result_is_never_resent(api):
    sent = _after_allow(api)
    _client().set_fault(MOCK_PURIFIER_ID, "unconfirmed")
    frame = _frame()
    deps.receive_appliance_done(dict(frame))
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert run["status"] == "unconfirmed"
    notices = " / ".join(run["notices"])
    assert "바뀌었는지 확인하지 못했어요" in notices and "저절로 다시 하지 않으니" in notices
    assert "바꿨어요" not in notices
    deps.receive_appliance_done(dict(frame))
    time.sleep(0.5)
    assert len(_controls()) == sent + 1


# ── ② 모의 사건 → 모의 ThinQ만 ────────────────────────────────────────────────


def test_mock_or_injected_event_never_drives_a_real_target(api):
    sent = _after_allow(api)
    _client().execution_mode = ExecutionMode.REAL  # 대상이 실제 클라우드라고 선언(게이트만 시험)
    deps.receive_appliance_done(_frame(source="injected"))
    deps.receive_appliance_done(_frame(source="mock"))
    blocked = [r for r in _runs(api) if r["outcome"] == "blocked"]
    assert len(blocked) == 2
    assert all("실제 공기청정기" in r["reason"] for r in blocked)
    assert len(_controls()) == sent
    deps.receive_appliance_done(_frame(source="real"))  # 실물 L3 출처 사건만
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("event_source") == "real")
    assert len(_controls()) == sent + 1


def test_mock_event_drives_the_mock_target(api):
    sent = _after_allow(api)
    deps.receive_appliance_done(_frame(source="mock"))
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert run["execution_mode"] == "mock"
    assert len(_controls()) == sent + 1


# ── ⑥ 조리 완료 근거 ──────────────────────────────────────────────────────────


def test_button_press_completion_never_triggers_the_auto_rule(api):
    sent = _after_allow(api)
    job = api.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    _wait_done(api, job.json()["job_id"])
    time.sleep(0.3)
    assert len(_controls()) == sent
    assert [r for r in _runs(api) if r["outcome"] == "sent"] == []


def test_beep_only_end_does_not_run(api):
    sent = _after_allow(api)
    _inject(api, inputs=("beep",))
    time.sleep(0.3)
    assert len(_controls()) == sent


# ── ④ 허용은 조건·대상·속성·값에 묶인다 ─────────────────────────────────────


def test_replaced_target_device_voids_the_allowance(api):
    from rpi.api.thinq_wiring import appliance_for

    sent = _after_allow(api)
    registry = deps.get_appliance_registry()
    registry.unregister_system("air_purifier")
    registry.register_system(appliance_for("air_purifier", "other-purifier-02", "공기청정기(모의)"))
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "바뀌" in run["reason"]
    assert len(_controls()) == sent
    rule = _rules(api)[0]
    assert rule["enabled"] is False and rule["status_label"] == "자동 실행 꺼짐"
    assert "다시 허락" in rule["disabled_reason"]


def test_changed_value_needs_a_new_allowance(api):
    sent = _after_allow(api)
    rule = _rules(api)[0]
    changed = api.put(f"/routines/auto-rules/{rule['id']}", json={"value": "MID"})
    assert changed.status_code == 200, changed.text
    changed = changed.json()
    assert changed["enabled"] is False and changed["action_text"] == "공기청정기(모의) 바람을 중간으로 해요"
    _inject(api, inputs=("power",))
    time.sleep(0.3)
    assert len(_controls()) == sent  # 바뀐 값은 아직 허용 전 — 실행 안 함
    old = api.post(f"/routines/auto-rules/{rule['id']}/enable",
                   json={"enabled": True, "fingerprint": rule["fingerprint"]})
    assert old.status_code == 409  # 옛 허용으로는 켜지지 않는다
    ok = api.post(f"/routines/auto-rules/{rule['id']}/enable",
                  json={"enabled": True, "fingerprint": changed["fingerprint"]})
    assert ok.status_code == 200 and ok.json()["enabled"] is True
    _inject(api, inputs=("power",))
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert _controls()[-1][1] == {"airFlow": {"windStrength": "MID"}}


def test_turn_off_from_the_list_stops_auto_and_brings_back_the_card(api):
    sent = _after_allow(api)
    rule = _rules(api)[0]
    off = api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False})
    assert off.status_code == 200 and off.json()["status_label"] == "자동 실행 꺼짐"
    _inject(api, inputs=("power",))
    time.sleep(0.3)
    assert len(_controls()) == sent
    assert len(_cards(api)) == 1  # 다시 사용자가 고른다


def test_delete_rule(api):
    _allow(api)
    rule = _rules(api)[0]
    assert api.delete(f"/routines/auto-rules/{rule['id']}").status_code == 200
    assert _rules(api) == []


# ── ① 낮은 위험 ThinQ 동작만 · 물리 누름은 서버 거절 ─────────────────────────


def test_low_risk_table():
    from rpi.routines.auto_rules import is_low_risk

    assert is_low_risk("DEVICE_AIR_PURIFIER", "set_wind_strength", "HIGH")
    assert is_low_risk("DEVICE_AIR_PURIFIER", "set_job_mode", "CLEAN")
    assert is_low_risk("DEVICE_AIR_PURIFIER", "set_power", "POWER_ON")
    assert not is_low_risk("DEVICE_AIR_PURIFIER", "set_power", "POWER_OFF")
    assert not is_low_risk("DEVICE_WASHER", "set_operation", "START")
    assert not is_low_risk("DEVICE_DEHUMIDIFIER", "set_power", "POWER_ON")


def test_physical_press_card_cannot_be_made_automatic(api):
    saved = api.post("/routines", json={
        "name": "즉석밥", "mode": "approve", "trigger": {"kind": "manual"},
        "steps": [{"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["즉석밥"]}],
    })
    assert saved.status_code == 201, saved.text
    card = api.post(f"/routines/{saved.json()['id']}/trigger").json()["suggestion"]
    listed = next(s for s in api.get("/suggestions").json() if s["id"] == card["id"])
    assert listed.get("auto_rule_offer") is None  # 화면에 '다음부터도 자동으로'가 없다
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow", json={"offer_fingerprint": "x" * 64})
    assert res.status_code == 422
    assert "버튼" in res.json()["detail"]
    assert _rules(api) == []
    assert api.get("/status").json()["last_job_id"] is None  # 실행도 하지 않았다


def test_rule_edit_cannot_add_a_press_step_or_a_risky_value(api):
    _allow(api)
    rule = _rules(api)[0]
    press = api.put(f"/routines/auto-rules/{rule['id']}",
                    json={"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["시작"]})
    assert press.status_code == 422 and "버튼" in press.json()["detail"]
    bad = api.put(f"/routines/auto-rules/{rule['id']}", json={"value": "TURBO"})
    assert bad.status_code == 422
    assert _rules(api)[0]["enabled"] is True  # 거절된 수정은 허용을 건드리지 않는다


# ── ⑤ 비상정지 ───────────────────────────────────────────────────────────────


def test_emergency_stop_turns_auto_off_and_never_claims_a_cloud_cancel(api):
    sent = _after_allow(api)
    assert api.post("/stop").status_code == 200
    rule = _rules(api)[0]
    assert rule["enabled"] is False and "비상정지" in rule["disabled_reason"]
    stop = next(r for r in _runs(api) if r["outcome"] == "estop")
    assert "되돌리지 않아요" in stop["reason"]
    assert "취소했" not in stop["reason"] and "꺼졌" not in stop["reason"]
    _inject(api, inputs=("power",))
    time.sleep(0.3)
    assert len(_controls()) == sent  # 새 자동 실행 없음


def test_stop_between_decision_and_send_blocks_the_unsent_command(api, monkeypatch):
    from rpi.routines.wiring import stop_auto_rules_if_any

    sent = _after_allow(api)
    service = deps.get_service()
    original = service.submit_approved

    def stop_first(*args, **kwargs):
        stop_auto_rules_if_any("비상정지")  # 판단은 끝났고 아직 보내기 전에 정지
        return original(*args, **kwargs)

    monkeypatch.setattr(service, "submit_approved", stop_first)
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "비상정지" in run["reason"]
    time.sleep(0.3)
    assert len(_controls()) == sent


def _engine():
    from rpi.routines.wiring import get_auto_rule_engine

    return get_auto_rule_engine()


def test_rule_turned_off_while_waiting_to_send_is_not_sent(api, monkeypatch):
    """A2(10/14): 판단 뒤·보내기 전에 사용자가 자동 실행을 끄면 보내지 않는다."""
    sent = _after_allow(api)
    rule_id = _rules(api)[0]["id"]
    service = deps.get_service()
    original = service.submit_approved

    def off_first(*args, **kwargs):
        _engine().set_enabled(rule_id, False)
        return original(*args, **kwargs)

    monkeypatch.setattr(service, "submit_approved", off_first)
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "꺼져" in run["reason"]
    time.sleep(0.3)
    assert len(_controls()) == sent


def test_value_changed_and_reallowed_while_waiting_never_sends_the_old_value(api, monkeypatch):
    """A2(10/14): 판단 뒤·보내기 전에 설정값을 바꾸고 다시 허용했다 — 판단 때의 옛 값(강)을 보내지 않는다.
    (규칙이 '켜져 있음'만 보면 옛 명령이 새 허용으로 나간다.)"""
    sent = _after_allow(api)
    rule_id = _rules(api)[0]["id"]
    service = deps.get_service()
    original = service.submit_approved

    def change_first(*args, **kwargs):
        engine = _engine()
        changed = engine.update(rule_id, {"value": "MID"})
        engine.set_enabled(rule_id, True, changed.fingerprint())
        return original(*args, **kwargs)

    monkeypatch.setattr(service, "submit_approved", change_first)
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "바뀌" in run["reason"]
    time.sleep(0.3)
    assert len(_controls()) == sent  # 옛 값도, 새 값도 이 사건으로는 보내지 않았다


def test_rule_turned_off_after_the_start_gate_is_rechecked_right_before_sending(api, monkeypatch):
    """A2(10/14): 실행 시작 게이트는 통과했고 클라우드로 보내기 직전에 꺼졌다 — 보내기 직전 재검사로 막는다."""
    sent = _after_allow(api)
    rule_id = _rules(api)[0]["id"]
    service = deps.get_service()
    original = service._begin_run

    def off_after_gate(*args, **kwargs):
        job_id = original(*args, **kwargs)
        _engine().set_enabled(rule_id, False)  # 게이트 뒤, 실행 스레드가 보내기 전
        return job_id

    monkeypatch.setattr(service, "_begin_run", off_after_gate)
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked" and r.get("status"))
    assert run["reason"] == "자동으로 하기가 꺼져서 하지 않았어요."
    assert run["receipt"] == "not_dispatched"
    assert len(_controls()) == sent
    notices = " / ".join(run["notices"])
    assert "바꿨어요" not in notices and "하지 않았어요" in notices


def test_latched_outlet_estop_blocks_auto(api, monkeypatch):
    sent = _after_allow(api)
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True)
    _inject(api, inputs=("power",))
    run = _wait_run(api, lambda r: r["outcome"] == "blocked")
    assert "비상정지" in run["reason"]
    assert len(_controls()) == sent


def test_rule_texts_are_short_and_never_raw():
    """2026-10-14 UX: 조건은 '○○가 멈추면', 대상 기능을 못 찾아도 원시 동작 이름을 내지 않는다."""
    from rpi.routines.auto_rules import AutoRule, AutoRuleEngine

    names = {"mw": "전자레인지", "air": "공기청정기"}

    class Fake:
        def _name(self, appliance_id):
            return names[appliance_id]

        def _appliance(self, _appliance_id):
            return None  # 대상 가전을 지웠거나 바인딩을 잃었다

    rule = AutoRule("r1", "s1", "mw", "done", "air", "k", "DEVICE_AIR_PURIFIER",
                    "set_wind_strength", "windStrength", "HIGH")
    assert AutoRuleEngine.condition_text(Fake(), rule) == "전자레인지가 멈추면"
    action = AutoRuleEngine.action_text(Fake(), rule)
    assert action == "공기청정기 바람 세기를 바꿔요"
    assert "set_wind_strength" not in action and "HIGH" not in action


def test_missing_target_name_and_legacy_reason_are_human_words():
    """10/14 실물(ThinQ 끔): 대상이 없으면 이름 자리에 'air_purifier'가 나왔고, 10/14 전에 저장된 꺼짐 사유는
    옛 긴 문장 그대로였다. 대상 종류 이름으로, 옛 사유는 지금 문장으로 바꿔 보여 준다(저장값은 그대로)."""
    from rpi.routines.auto_rules import UNCLEAN_RESTART_REASON, ESTOP_REASON, AutoRuleEngine, display_reason

    class Fake:
        def _appliance(self, _appliance_id):
            return None

    assert AutoRuleEngine._name(Fake(), "air_purifier") == "공기청정기"
    assert "air_purifier" not in AutoRuleEngine._name(Fake(), "air_purifier")
    old = ("허브가 정상 종료되지 않아(전원 끊김·강제 종료 등) 자동 실행을 멈췄어요 — "
           "다시 켜려면 조건·동작을 확인하고 허용해 주세요")
    assert display_reason(old) == UNCLEAN_RESTART_REASON
    assert display_reason("비상정지로 자동 실행을 껐어요 — 다시 켜려면 조건·동작을 확인하고 허용해 주세요") == ESTOP_REASON
    assert display_reason(UNCLEAN_RESTART_REASON) == UNCLEAN_RESTART_REASON
    assert display_reason(None) is None
