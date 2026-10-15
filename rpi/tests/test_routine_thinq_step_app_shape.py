"""폰 루틴 편집기의 'ThinQ 가전 조작' 단계 모양이 서버에서 저장·실행되는가 (2026-10-15).

폰(``app/lib/widgets/thinq_state_card.dart``의 ``kAirPurifierControls``)이 고를 수 있는 값 9개를
폰이 보내는 JSON 그대로 ``POST /routines``에 넣고, 직접 실행 → 승인 카드 → 승인으로 모의 ThinQ
공기청정기에서 끝까지 도는지 본다. 서버 코드는 바꾸지 않았다 — 계약 확인용 시험이다.

실물 검증은 없다. 실행은 모의 ThinQ 공기청정기로만 확인한다(시작 값 전원 꺼짐·약풍·청정이라
같은 값을 고르면 보내지 않고 ``already_at_target``으로 끝난다).
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.routines.wiring import reset_routines

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_control_arbiter, deps.get_presence_state_machine,
)

#: 폰 편집기가 고를 수 있는 (동작, 인자 이름, 값) — 폰 표와 같아야 한다.
APP_CHOICES = [
    ("set_power", "power", "POWER_ON"),
    ("set_power", "power", "POWER_OFF"),
    ("set_wind_strength", "wind_strength", "LOW"),
    ("set_wind_strength", "wind_strength", "MID"),
    ("set_wind_strength", "wind_strength", "HIGH"),
    ("set_wind_strength", "wind_strength", "AUTO"),
    ("set_job_mode", "job_mode", "CLEAN"),
    ("set_job_mode", "job_mode", "SLEEP"),
    ("set_job_mode", "job_mode", "AUTO"),
]


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", "pat-test-routine-app-shape")
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "0.3")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _wait_run(client, run_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        run = client.get(f"/routines/runs/{run_id}")
        if run.status_code == 200 and run.json()["status"] != "running":
            return run.json()
        time.sleep(0.02)
    raise AssertionError("routine run did not finish")


@pytest.mark.parametrize(("action", "arg", "value"), APP_CHOICES)
def test_app_thinq_step_saves_and_runs_after_approval(client, action, arg, value):
    # 폰 RoutineStep.thinq(...).toJson()과 같은 모양.
    step = {"kind": "thinq_command", "appliance_id": "air_purifier", "action": action,
            "args": {arg: value}}
    body = {"name": "공기 루틴", "steps": [step], "trigger": {"kind": "manual"},
            "conditions": [], "mode": "approve", "enabled": True}
    saved = client.post("/routines", json=body)
    assert saved.status_code == 201, saved.text
    assert saved.json()["steps"] == [step]
    rid = saved.json()["id"]
    # 다시 읽어도 같은 모양이다(폰 RoutineStep.fromJson이 읽는 것).
    listed = [r for r in client.get("/routines").json() if r["id"] == rid]
    assert listed and listed[0]["steps"] == [step]

    # 저장만으로는 아무것도 보내지 않는다.
    purifier = deps.get_service().thinq_controller.client
    assert purifier.controls == []

    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    assert [c["route"] for c in card["commands"]] == ["thinq"]
    # 승인 카드 문장은 서버가 사람 말로 만든다 — 동작 이름을 내지 않는다.
    assert action not in card["commands"][0]["summary"]
    assert purifier.controls == []

    job = client.post(f"/suggestions/{card['id']}/approve")
    assert job.status_code == 200, job.text
    run = _wait_run(client, job.json()["job_id"])
    assert run["status"] == "succeeded", run
    # 모의 시작 값(꺼짐·약풍·청정)과 같으면 보내지 않고, 다르면 한 번 보내 바뀐 것을 본다.
    already = value in ("POWER_OFF", "LOW", "CLEAN")
    assert run["steps"][0]["confirmation"] == ("already_at_target" if already else "state_confirmed")
    assert len(purifier.controls) == (0 if already else 1)
