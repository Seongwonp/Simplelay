"""끝-끝: 시각 루틴의 '다음부터도 자동으로'(시각 규칙) → 공식 SDK → 모의 ThinQ 클라우드 공기청정기 → 상태 재조회 → 기록.

``SIMPLELAY_THINQ_MODE=fake_cloud``(저장소 안 모의 클라우드 127.0.0.1). **실제 ThinQ 클라우드·실가전은 쓰지 않는다** —
결과의 실행 환경은 mock이다. 벽시계와 허브 단조 시계는 가짜로 함께 옮기고 루틴 엔진 ``tick``을 직접 부른다.
"""

from __future__ import annotations

import time
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_auto_rule_e2e import SECRET_PAT, _env, _wait_run, cloud  # noqa: F401
from rpi.tests.test_cook_done_card import _reset, _wait_done
from rpi.tests.test_thinq_time_auto_rule import (  # noqa: F401
    AT_2300,
    _manual_card,
    _move,
    _routine,
    _routine_cards,
    _tick,
    clock,
    hub,
)

pytest.importorskip("thinqconnect")

POWER_ON_BODY = {"operation": {"airPurifierOperationMode": "POWER_ON"}}


@pytest.fixture()
def api(monkeypatch, tmp_path, cloud, clock, hub):  # noqa: F811
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _allow_time_rule(api):
    """정오에 매일 23:00 공기청정기 켜기 루틴 → 카드에서 '이번에 실행하고 다음부터 자동으로' → 공기청정기를 끈다."""
    routine = _routine(api)
    card = _manual_card(api, routine["id"])
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow",
                   json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"]})
    assert res.status_code == 200, res.text
    assert _wait_done(api, res.json()["job_id"], timeout=10)["last_status"] == "succeeded"
    off = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_power",
                                           "args": {"power": "POWER_OFF"}})
    assert off.status_code == 200, off.text
    assert _wait_done(api, off.json()["job_id"], timeout=10)["last_status"] == "succeeded"
    return routine


def test_time_rule_drives_the_mock_cloud_purifier_on(api, cloud, clock, hub):  # noqa: F811
    device = cloud.device_id("air_purifier")
    _allow_time_rule(api)
    assert cloud.state(device)["operation"]["airPurifierOperationMode"] == "POWER_OFF"
    before = len(cloud.controls())

    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)  # 추가 승인 없음
    run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
    assert (run["status"], run["receipt"], run["confirmation"], run["execution_mode"]) == (
        "succeeded", "accepted", "state_confirmed", "mock")
    assert run["event_source"] == "schedule"
    controls = cloud.controls()[before:]
    assert [c["body"] for c in controls] == [POWER_ON_BODY]
    assert cloud.state(device)["operation"]["airPurifierOperationMode"] == "POWER_ON"
    assert _routine_cards(api) == []
    status = api.get("/status").json()
    assert status["last_auto_run"]["target_name"] == "공기청정기(모의 클라우드)"
    exposed = str(run) + str(api.get("/routines/auto-rules").json()) + str(status)
    assert SECRET_PAT not in exposed and device not in exposed


def test_rule_turned_off_after_the_final_guard_sends_nothing(monkeypatch, api, cloud, clock, hub):  # noqa: F811
    """최종 재판정(``dispatch_guard``)이 통과한 직후 목록에서 끄기 → 그 뒤 POST 시도 — 모의 클라우드 POST 0건."""
    from rpi.services.thinq.controller import ThinqController

    _allow_time_rule(api)
    rule = api.get("/routines/auto-rules").json()[0]
    before = len(cloud.controls())
    original_execute = ThinqController.execute_command
    responses = []

    def execute(controller, command, *, dispatch_guard=None):
        if dispatch_guard is None:
            return original_execute(controller, command)

        def guard_then_off(binding=None):
            out = dispatch_guard(binding)
            if binding is not None and not responses:
                responses.append(api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False}))
            return out

        return original_execute(controller, command, dispatch_guard=guard_then_off)

    monkeypatch.setattr(ThinqController, "execute_command", execute)
    _move(clock, hub, AT_2300 + timedelta(seconds=2))
    _tick(clock.value)
    run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
    time.sleep(0.3)
    assert responses and responses[0].status_code == 200, responses
    assert len(cloud.controls()) == before, cloud.controls()[before:]
    assert run["receipt"] == "not_dispatched" and run["outcome"] == "blocked"
