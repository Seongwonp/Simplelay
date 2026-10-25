"""습관 카드에서 바로 '매일 이 시간에'(2026-10-25 — 묻기에서 맡기기로 가는 다리).

습관 카드(사용 기록으로 뜬 '지금 할까요?')에 루틴 초안이 있으면 ``adopt_offer``가 실린다. 한 번 눌러
이번 실행 + 매일 그 시각 루틴 저장 + (낮은 위험 LG 가전 동작이면) 자동 실행 맡기기를 한다. 초안이 바뀌었으면 409로
실행·저장 둘 다 하지 않는다. 모의 ThinQ·가짜 시계 — 실가전 확인이 아니다.
"""

from __future__ import annotations

from rpi.tests.test_thinq_time_auto_rule import (  # noqa: F401 — 픽스처
    _candidates,
    _move,
    _use,
    api,
    clock,
    hub,
    submits,
)


def _habit_card(api, clock, hub):
    from rpi.api import deps

    _use((1, 2, 3, 4))  # 나흘 동안 밤 11시에 직접 공기청정기를 켰다
    _move(clock, hub, clock.value.replace(hour=23, minute=0))
    deps.get_suggestion_service().create_suggestions()
    cards = [c for c in api.get("/suggestions").json() if not c.get("scenario_id")]
    assert len(cards) == 1, cards
    return cards[0]


def test_habit_card_offers_to_adopt_the_draft_as_a_daily_routine(api, clock, hub):
    card = _habit_card(api, clock, hub)
    offer = card["adopt_offer"]
    (draft,) = _candidates(api)
    assert offer["candidate_key"] == draft["key"]
    assert offer["ask_time"] == "23:00"
    assert offer["auto"] is True  # 낮은 위험 LG 가전 동작 — 맡길 수 있다


def test_one_press_runs_now_saves_the_routine_and_hands_it_over(api, clock, hub, submits):
    card = _habit_card(api, clock, hub)
    res = api.post(f"/suggestions/{card['id']}/approve-and-adopt",
                   json={"candidate_key": card["adopt_offer"]["candidate_key"]})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["job_id"]
    assert body["adopt"] == {"ok": True, "reason": None}
    assert body["auto_allow"] == {"ok": True, "reason": None}
    routine = api.get(f"/routines/{body['routine_id']}").json()
    assert routine["trigger"]["time"] == "23:00"
    (rule,) = api.get("/routines/auto-rules").json()
    assert rule["enabled"] is True
    assert _candidates(api) == []  # 저장했으니 초안으로 다시 권하지 않는다


def test_changed_draft_runs_and_saves_nothing(api, clock, hub, submits):
    card = _habit_card(api, clock, hub)
    res = api.post(f"/suggestions/{card['id']}/approve-and-adopt", json={"candidate_key": "tc-other"})
    assert res.status_code == 409
    assert submits == []
    assert api.get("/routines/auto-rules").json() == []


def test_learning_view_marks_the_adopted_habit_as_auto_even_when_hidden(api, clock, hub, submits):
    """'알게 된 것'(2026-10-26) — 맡긴 습관은 '자동 실행 중'과 루틴 이름. 제안을 숨겨도 루틴은 돌기에 그대로 보인다."""
    card = _habit_card(api, clock, hub)
    before = api.get("/learning").json()["routines"]
    assert [r["state"] for r in before] == ["asking"]
    body = api.post(f"/suggestions/{card['id']}/approve-and-adopt",
                    json={"candidate_key": card["adopt_offer"]["candidate_key"]}).json()
    name = api.get(f"/routines/{body['routine_id']}").json()["name"]
    (habit,) = api.get("/learning").json()["routines"]
    assert (habit["state"], habit["routine_name"]) == ("auto", name)
    assert api.post("/suppressions/mute", json={"purpose": habit["purpose"]}).status_code == 200
    (habit,) = api.get("/learning").json()["routines"]
    assert (habit["state"], habit["muted"]) == ("auto", True)
