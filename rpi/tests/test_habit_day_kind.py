"""습관 날 종류(평일·주말·매일)와 맡긴 루틴 요일이 같은가(2026-10-26).

- 평일 습관을 맡기면 루틴도 월~금이다(매일로 저장하면 주말에도 묻거나 돈다).
- 평일 사흘만 이어 쓴 기록(사이에 주말 없음)은 '평일'이라 할 근거가 없다 — 매일로 본다.
- 첫날~마지막 날 사이 주말을 건너뛰었으면 평일 습관이다.
모의 ThinQ·가짜 시계 — 실가전 확인이 아니다.
"""

from __future__ import annotations

import pytest

from rpi.intent import habit_timing
from rpi.intent.habit_words import day_kind, routine_days
from rpi.tests.test_thinq_time_auto_rule import (  # noqa: F401 — 픽스처
    _candidates,
    _move,
    _use,
    api,
    clock,
    hub,
    submits,
)


@pytest.fixture(autouse=True)
def _no_holidays(monkeypatch):
    monkeypatch.setattr(habit_timing, "_holiday_lookup", None)  # 토·일만 쉬는 날


def test_three_weekdays_in_a_row_without_a_weekend_is_every_day():
    assert day_kind(["2026-10-12", "2026-10-13", "2026-10-14"]) is None  # 월·화·수


def test_weekend_skipped_inside_the_span_is_weekday():
    assert day_kind(["2026-10-08", "2026-10-09", "2026-10-12", "2026-10-13"]) == "weekday"  # 목·금 / 월·화


def test_weekend_habit_needs_a_skipped_weekday_in_the_span():
    assert day_kind(["2026-10-10", "2026-10-11", "2026-10-17"]) == "weekend"  # 토·일 / 토
    assert routine_days("weekend") == [5, 6]
    assert routine_days(None) == list(range(7))


def test_adopted_weekday_habit_saves_a_mon_to_fri_routine(api, clock, hub, submits):
    from rpi.api import deps

    _use((1, 2, 5, 6))  # 화·월 / 금·목 밤 11시 — 그 사이 토·일은 안 썼다
    _move(clock, hub, clock.value.replace(hour=23, minute=0))  # 수요일 밤
    deps.get_suggestion_service().create_suggestions()
    (card,) = [c for c in api.get("/suggestions").json() if not c.get("scenario_id")]
    offer = card["adopt_offer"]
    assert (offer["days"], offer["days_label"]) == ([0, 1, 2, 3, 4], "평일")
    (draft,) = _candidates(api)
    assert draft["run_choices"][0]["label"] == "평일 23:00에 물어보기"
    res = api.post(f"/suggestions/{card['id']}/approve-and-adopt", json={"candidate_key": offer["candidate_key"]})
    assert res.status_code == 200, res.text
    routine = api.get(f"/routines/{res.json()['routine_id']}").json()
    assert routine["trigger"]["days"] == [0, 1, 2, 3, 4]
    (habit,) = api.get("/learning").json()["routines"]
    assert habit["day_kind"] == "weekday"
