"""'다음 루틴' 한 번 건너뛰기(2026-10-18 사용자 요청).

키오스크·폰 처음 화면의 '다음 루틴'(정해진 시각 루틴 — 시각 자동 실행 규칙도 그 루틴에 붙는다)에서 '오늘은 건너뛰기'를
누르면 **그 회차 한 번만** 하지 않는다. 되돌리기도 된다. 다음 회차부터는 원래대로.

- ``POST /routines/next/skip``·``POST /routines/next/unskip`` — 본문은 ``/routines/next``가 준 ``routine_id``·``at`` 그대로.
- 지났거나(이미 시작한 회차 포함) 다음 회차와 맞지 않으면 409. 건너뛰기는 실행을 멈추지 않는다(정지는 /stop).
- 재시작해도 남는다(서버 DB 설정 한 칸).

전부 모의 ThinQ·가짜 시계다(``test_thinq_time_auto_rule``과 같은 틀).
"""

from __future__ import annotations

import time
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_thinq_time_auto_rule import (  # noqa: F401 — 픽스처
    AT_2300,
    _allowed_time_rule,
    _controls,
    _move,
    _restart,
    _routine,
    _routine_cards,
    _runs,
    _tick,
    _wait_run,
    api,
    clock,
    db_api,
    hub,
)

SKIP_REASON = "오늘은 건너뛰기로 해서 안 했어요"


def _next(api):
    (item,) = api.get("/routines/next").json()
    return item


def _skip(api, item, path="skip"):
    return api.post(f"/routines/next/{path}", json={"routine_id": item["routine_id"], "at": item["at"]})


def _sent(api):
    return [r for r in _runs(api) if r["outcome"] == "sent"]


def test_next_item_says_not_skipped_by_default(api):
    _routine(api)
    item = _next(api)
    assert item["skipped"] is False and item["skip_label"] is None
    assert item["skip_action_label"] == "오늘은 건너뛰기"


def test_skipping_the_next_auto_run_skips_only_that_occurrence(api, clock, hub):
    routine = _allowed_time_rule(api, clock, hub)
    item = _next(api)
    res = _skip(api, item)
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["routine_id"] == routine["id"] and body["at"] == item["at"]
    assert body["skipped"] is True and body["skip_label"] == "오늘은 건너뛰어요"
    shown = _next(api)  # 회차가 지나기 전까지 같은 회차를 '건너뜀'으로 보인다(되돌리기 가능)
    assert shown["at"] == item["at"] and shown["skipped"] is True
    assert shown["auto"] is True  # 무엇을 건너뛰는지는 그대로
    sent = len(_controls())

    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    assert _tick(clock.value) == []
    run = _wait_run(api, lambda r: r["outcome"] == "skipped")
    assert run["reason"] == SKIP_REASON
    time.sleep(0.2)
    assert _sent(api) == [] and len(_controls()) == sent and _routine_cards(api) == []
    log = api.get("/routines/log").json()
    assert log[0]["routine_id"] == routine["id"] and log[0]["outcome"] == "skipped"
    assert log[0]["detail"] == SKIP_REASON
    after = _next(api)  # 지난 회차 다음은 원래대로
    assert after["day_label"] == "내일" and after["skipped"] is False

    _move(clock, hub, AT_2300 + timedelta(days=1, seconds=2))
    _tick(clock.value)
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert len(_controls()) == sent + 1


def test_unskip_restores_the_occurrence(api, clock, hub):
    _allowed_time_rule(api, clock, hub)
    item = _next(api)
    assert _skip(api, item).status_code == 200
    res = _skip(api, item, "unskip")
    assert res.status_code == 200, res.text
    assert res.json()["skipped"] is False and _next(api)["skipped"] is False
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert [r for r in _runs(api) if r["outcome"] == "skipped"] == []


def test_skip_and_unskip_are_idempotent(api):
    _routine(api)
    item = _next(api)
    assert _skip(api, item).status_code == 200
    assert _skip(api, item).json()["skipped"] is True
    assert _skip(api, item, "unskip").status_code == 200
    assert _skip(api, item, "unskip").json()["skipped"] is False


def test_skipping_a_card_routine_shows_no_card_that_time(api, clock, hub):
    routine = _routine(api)  # 자동 실행 없음 — 그 시각에 카드를 띄우는 루틴
    assert _skip(api, _next(api)).status_code == 200
    _move(clock, hub, AT_2300 + timedelta(seconds=5))
    assert _tick(clock.value) == []
    assert _routine_cards(api) == []
    assert api.get("/routines/log").json()[0]["outcome"] == "skipped"
    _move(clock, hub, AT_2300 + timedelta(days=1, seconds=5))
    assert len(_tick(clock.value)) == 1  # 다음 날은 원래대로
    assert any(s["scenario_id"].startswith(f"routine:{routine['id']}") for s in _routine_cards(api))


def test_skipped_item_also_says_the_occurrence_after_it(api, clock, hub):
    # 2026-10-24 사용자 평가: '오늘은 건너뛰어요'만으로는 언제 다시 하는지 몰랐다 — 건너뛴 회차 다음 회차를 덧붙인다.
    _routine(api)
    item = _next(api)
    assert "next_after_skip_at" not in item  # 건너뛰지 않은 회차에는 없다(덧붙인 선택 필드)
    body = _skip(api, item).json()
    shown = _next(api)
    for got in (body, shown):
        assert got["skipped"] is True
        assert got["next_after_skip_at"] == (AT_2300 + timedelta(days=1)).isoformat()
        assert got["next_after_skip_day_label"] == "내일"
    assert _skip(api, item, "unskip").json().get("next_after_skip_at") is None


def test_after_skip_occurrence_in_quiet_hours_is_not_announced(api, clock, hub):
    # 다음 회차가 조용한 시간이면 그때도 하지 않는다 — '다음은 …'이라고 말하지 않는다(덧붙인 필드를 빼서).
    _routine(api)
    item = _next(api)
    assert _skip(api, item).status_code == 200
    res = api.put("/quiet-hours", json={"enabled": True, "start": "22:30", "end": "23:30"})
    assert res.status_code == 200, res.text
    shown = _next(api)
    assert shown["skipped"] is True and "next_after_skip_at" not in shown


def test_skip_tomorrow_says_tomorrow(api, clock, hub):
    _routine(api)
    _move(clock, hub, AT_2300 + timedelta(minutes=30))
    item = _next(api)
    assert item["day_label"] == "내일" and item["skip_action_label"] == "내일은 건너뛰기"
    body = _skip(api, item).json()
    assert body["skip_label"] == "내일은 건너뛰어요"


def test_skip_survives_a_restart(monkeypatch, db_api, clock, hub):
    api = db_api
    _routine(api)
    item = _next(api)
    assert _skip(api, item).status_code == 200
    api = _restart(monkeypatch, clean=True)
    assert _next(api)["skipped"] is True
    _move(clock, hub, AT_2300 + timedelta(seconds=5))
    assert _tick(clock.value) == []
    assert _routine_cards(api) == []


def test_unskip_survives_a_restart(monkeypatch, db_api, clock, hub):
    api = db_api
    _routine(api)
    item = _next(api)
    assert _skip(api, item).status_code == 200
    assert _skip(api, item, "unskip").status_code == 200
    api = _restart(monkeypatch, clean=True)
    assert _next(api)["skipped"] is False
    _move(clock, hub, AT_2300 + timedelta(seconds=5))
    assert len(_tick(clock.value)) == 1


def test_past_or_started_occurrence_is_refused(api, clock, hub):
    _routine(api)
    item = _next(api)
    _move(clock, hub, AT_2300 + timedelta(seconds=5))
    assert len(_tick(clock.value)) == 1  # 이미 시작했다
    for path in ("skip", "unskip"):
        res = _skip(api, item, path)
        assert res.status_code == 409, res.text
        assert "지난 회차" in res.json()["detail"]
    assert len(_routine_cards(api)) == 1  # 건너뛰기는 이미 낸 것을 거두지 않는다


def test_mismatched_or_unknown_occurrence_is_refused(api):
    routine = _routine(api)
    item = _next(api)
    later = dict(item, at=(AT_2300 + timedelta(days=1)).isoformat())
    res = _skip(api, later)
    assert res.status_code == 409 and "다음 회차" in res.json()["detail"]
    assert _skip(api, dict(item, routine_id="nope")).status_code == 404
    assert api.post("/routines/next/skip", json={"routine_id": routine["id"], "at": "모름"}).status_code == 422
    assert api.post("/routines/next/skip", json={"at": item["at"]}).status_code == 422
    assert api.post(f"/routines/{routine['id']}/enable", json={"enabled": False}).status_code == 200
    assert _skip(api, item).status_code == 409  # 꺼진 루틴은 다음 회차가 없다
    assert api.get("/routines/next").json() == []


def test_skip_routes_need_the_api_key(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_API_KEY", "k" * 32)
    from rpi.main import app

    client = TestClient(app)
    body = {"routine_id": "x", "at": AT_2300.isoformat()}
    for path in ("/routines/next/skip", "/routines/next/unskip"):
        assert client.post(path, json=body).status_code == 401
