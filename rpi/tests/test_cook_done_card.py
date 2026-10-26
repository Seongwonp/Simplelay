"""시연 v4(2026-10-13) — 전자레인지 조리 완료(CT 끝 판정) → 공기청정기 강풍 **제안 카드**.

조리 완료의 근거는 RPi4가 보내는 ``appliance_done``(전자레인지 CT 채널 전력 하강, 이벤트 ``heat_complete``)뿐이다.
버튼 누름 완료(실행 성공)는 조리 완료가 아니다. 카드는 제안이며 실행은 승인 뒤다(자동 실행 규칙은
test_auto_rules.py). 전부 모의 — 실제 CT 판정·실가전으로 확인한 것이 아니다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.routines.wiring import reset_routines
from rpi.services.appliance_done import parse_appliance_done

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_db,
    deps.get_control_arbiter, deps.get_presence_state_machine, deps.get_appliance_done_log,
)


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()


def _env(monkeypatch, thinq_mode: str | None):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_V2_SCENARIOS",
                 "SIMPLELAY_LOCAL_APPLIANCES", "SIMPLELAY_ACT_MODE", "SIMPLELAY_ROUTINE_DONE_SENSORS"):
        monkeypatch.delenv(name, raising=False)
    if thinq_mode is None:
        monkeypatch.delenv("SIMPLELAY_THINQ_MODE", raising=False)
    else:
        monkeypatch.setenv("SIMPLELAY_THINQ_MODE", thinq_mode)
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.3")


@pytest.fixture()
def api(monkeypatch):
    _env(monkeypatch, "mock")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _cards(client, scenario_id="cook_done_air"):
    return [s for s in client.get("/suggestions").json() if s.get("scenario_id") == scenario_id]


def _inject(client, appliance_id="microwave", inputs=("power",)):
    res = client.post("/demo/appliance-done", json={"appliance_id": appliance_id, "inputs": list(inputs)})
    assert res.status_code == 200, res.text
    return res.json()


def _wait_done(client, job_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish")


def test_default_catalog_is_the_v4_cook_done_scenario(api):
    scenarios = api.get("/scenarios").json()
    # 2026-10-15: 공기청정기 센서 공기질 카드(air_quality_high, 꺼져 있을 때 air_quality_power_on)가 뒤에 함께 실린다
    # (test_air_quality_suggestion.py·test_air_quality_power_on.py).
    # 2026-10-26: 환경 제안 세 개(test_context_suggestions.py)가 그 뒤에 실린다.
    assert [s["scenario_id"] for s in scenarios] == ["cook_done_air", "air_quality_high", "air_quality_power_on",
                                                     "context_sleep_mode", "context_arrival_air", "context_dust_air"]
    assert scenarios[0]["name"] == "전자레인지가 멈추면 공기청정기 세게"
    trigger = scenarios[0]["trigger"]
    assert (trigger["kind"], trigger["appliance_id"], trigger["event"]) == (
        "appliance_done", "microwave", "heat_complete")
    assert scenarios[0]["steps"] == [{"target_id": "air_purifier", "route": "thinq",
                                      "action": "set_wind_strength", "args": {"wind_strength": "HIGH"},
                                      "buttons": []}]


def test_ct_cook_done_offers_the_air_purifier_card(api):
    _inject(api, inputs=("power",))
    cards = _cards(api)
    assert len(cards) == 1
    card = cards[0]
    assert card["purpose"] == "공기청정기 바람을 세게 할까요?"
    assert card["commands"][0]["summary"] == "공기청정기(모의) 바람 세기 강"
    assert card["is_demo"] is True  # 주입 사건 — 실제 CT 판정이 아니다
    assert "멈춘 것 같아요" in card["reason"] and "연습으로 넣은 신호예요" in card["reason"]
    # A5(10/14): 지금 판정은 취소·문 열림 가열 종료와 구분하지 못한다 — 조리 완료를 보장하지 않는다.
    assert "멈춘 것 같아요" in card["reason"] and "조리 완료가 아닐 수 있어요" in card["reason"]
    assert "조리 완료를 콘센트 전력" not in card["reason"]
    # 카드는 제안일 뿐 — 아무것도 보내지 않았다.
    from rpi.api.thinq_wiring import get_thinq_client

    assert get_thinq_client().controls == []


def test_first_event_with_no_history_states_no_habit(api):
    """3차 평가 M4: 사용 이력이 없는 첫 가열 종료 — 사용자의 습관을 단정하지 않는다('식사 뒤 … 켜 두시곤 해요' 없음).
    제안 문장과 감지 근거(가열 종료·조리 완료가 아닐 수 있음)만."""
    _inject(api, inputs=("power",))
    card = _cards(api)[0]
    assert card["purpose"] == "공기청정기 바람을 세게 할까요?"
    for claim in ("식사", "두시곤", "습관", "자주", "승인하셨어요"):
        assert claim not in card["reason"], claim
    assert "조리 완료가 아닐 수 있어요" in card["reason"]


def test_habit_sentence_only_with_counted_history(api):
    """3차 평가 M4: 근거 문장은 실제 집계가 있을 때만 — 같은 제안을 승인한 횟수(제안 기록)를 센 그대로."""
    _inject(api, inputs=("power",))
    first = _cards(api)[0]
    res = api.post(f"/suggestions/{first['id']}/approve")
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    _inject(api, inputs=("power",))
    second = _cards(api)[0]
    assert second["id"] != first["id"]
    assert "지금까지 1번 허락받은 제안이에요" in second["reason"]
    # 2026-10-16 결함 ④: 누가 눌렀는지 모른다 — '하셨어요'로 사람을 단정하지 않는다.
    assert "하셨어요" not in second["reason"]
    assert "식사" not in second["reason"] and "두시곤" not in second["reason"]


def test_beep_only_end_is_not_cook_done(api):
    """CT 전력 끝이 없는 종료음만으로는 조리 완료가 아니다 — 카드 없음."""
    _inject(api, inputs=("beep",))
    assert _cards(api) == []


def test_button_press_success_is_not_cook_done(api):
    """버튼 누름(실행) 성공은 조리 완료가 아니다 — 실행 끝으로는 카드를 만들지 않는다."""
    job = api.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert job.status_code == 200, job.text
    assert _wait_done(api, job.json()["job_id"])["last_status"] == "succeeded"
    assert _cards(api) == []


def test_washer_end_does_not_offer_the_cook_card(api):
    _inject(api, appliance_id="washer", inputs=("power", "beep"))
    assert _cards(api) == []


def test_no_card_when_thinq_is_off(monkeypatch):
    _env(monkeypatch, None)
    _reset()
    from rpi.main import app

    try:
        client = TestClient(app)
        _inject(client, inputs=("power",))
        assert _cards(client) == []
    finally:
        _reset()


def test_parsed_done_record_keeps_the_event_time_fields():
    """같은 사건 판별(재전송·재연결)과 오래된 사건 판별에 쓰는 RPi4 시각을 버리지 않는다."""
    record = parse_appliance_done({
        "type": "appliance_done", "appliance_id": "microwave", "event": "heat_complete",
        "state": "done_power_only", "inputs": ["power"], "expected_inputs": ["power"],
        "source": "real", "at_s": 1234.5, "t_monotonic_ns": 1_244_500_000_000,
    })
    assert record["at_s"] == 1234.5
    assert record["t_monotonic_ns"] == 1_244_500_000_000
    bad = parse_appliance_done({
        "type": "appliance_done", "appliance_id": "microwave", "event": "heat_complete",
        "state": "done_power_only", "inputs": ["power"], "source": "real", "at_s": "soon",
        "t_monotonic_ns": True,
    })
    assert bad["at_s"] is None and bad["t_monotonic_ns"] is None


def test_rpi5_mock_injection_carries_the_send_time(api):
    _inject(api, inputs=("power",))
    record = deps.get_appliance_done_log().recent()[0]
    assert isinstance(record["at_s"], float)
    assert isinstance(record["t_monotonic_ns"], int)
