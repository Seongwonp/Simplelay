"""검토 2026-10-19: 여러 구간 루틴은 승인 응답이 **첫 구간**의 실행 번호만 주고 나머지는 백그라운드에서 이어 간다.

클라이언트가 ``GET /jobs/{첫 번호}``로 기다리면 첫 구간이 끝나는 순간 '끝남·성공'을 보고 루틴 전체가 끝난 줄 알았다
(뒤 구간이 실패·정지해도). 이제 그 번호는 **루틴 실행 전체의 수명**을 나타낸다: 루틴이 도는 동안 ``running: true``·
``finished: false``, 끝나면 루틴 전체 결과(모든 구간이 성공일 때만 성공)와 ``routine_run_id``. /status도 루틴이 도는 동안
첫 번호를 '쉬는 중·성공'으로 내놓지 않는다. 실행 대상은 모의 — 실물 미검증.
"""

from __future__ import annotations

import threading
import time

from rpi.routines.wiring import get_routine_engine
from rpi.tests.test_routines import HEAT, PURIFIER_ON, _body, _wait_run, client  # noqa: F401 — 픽스처

WAIT = {"kind": "wait_until_done", "appliance_id": "microwave"}


def _start_routine(client, gate: threading.Event, check=None):
    """첫 구간 뒤 기다림 단계에서 ``gate``가 열릴 때까지 멈추는 루틴을 승인하고 첫 실행 번호를 돌려준다."""
    rid = client.post("/routines", json=_body(steps=[HEAT, WAIT, PURIFIER_ON])).json()["id"]
    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    runner = get_routine_engine().runner
    original = runner._check_done
    entered = threading.Event()

    def held(run, appliance_id):
        entered.set()
        gate.wait(timeout=10)
        return check(run, appliance_id) if check is not None else original(run, appliance_id)

    runner._check_done = held
    response = client.post(f"/suggestions/{card['id']}/approve")
    assert response.status_code == 200, response.text
    assert entered.wait(timeout=5), "routine did not reach the wait step"
    return response.json()["job_id"]


def _wait_finished(client, job_id, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get(f"/jobs/{job_id}").json()
        if body.get("finished"):
            return body
        time.sleep(0.02)
    raise AssertionError("job did not finish")


def test_root_job_reports_running_while_the_routine_continues(client):
    gate = threading.Event()
    try:
        root = _start_routine(client, gate)
        # 첫 구간은 끝났고 루틴은 기다림 단계에 있다.
        body = client.get(f"/jobs/{root}").json()
        assert body["running"] is True and body["finished"] is False
        assert body["job_id"] == root and body["last_job_id"] is None
        assert body["last_status"] is None and body["last_outcome"] is None
        assert body["routine_run_id"] == root
        assert body["routine_status"] == "running"
        # /status는 첫 번호를 '쉬는 중·성공'으로 내놓지 않는다(모양은 그대로).
        status = client.get("/status").json()
        assert status["last_job_id"] != root
    finally:
        gate.set()
    run = _wait_run(client, root)
    assert run["status"] == "succeeded" and len(run["job_ids"]) == 2
    body = _wait_finished(client, root)
    assert body["running"] is False and body["finished"] is True
    assert body["last_job_id"] == root
    assert body["last_outcome"] == "success"
    assert body["routine_run_id"] == root and body["routine_status"] == "succeeded"
    # 마지막 구간(공기청정기)의 결과 필드를 싣는다.
    assert body["last_route"] == "thinq" and body["last_confirmation"] == "state_confirmed"
    assert body["routine_segment_job_id"] == run["job_ids"][-1]
    assert client.get("/status").json()["last_job_id"] == root


def test_root_job_reports_the_routine_outcome_not_the_first_segment(client):
    gate = threading.Event()

    def not_done(run, appliance_id):
        return False, "끝났는지 확인하지 못해 다음 단계는 시작하지 않았어요. 가전을 봐 주세요.", "none", False

    root = _start_routine(client, gate, check=not_done)
    gate.set()
    run = _wait_run(client, root)
    assert run["status"] == "unconfirmed" and len(run["job_ids"]) == 1
    body = _wait_finished(client, root)
    # 첫 구간은 성공이었지만 루틴은 미확인으로 멈췄다 — 성공으로 내놓지 않는다.
    assert body["last_outcome"] == "unconfirmed" and body["last_status"] == "unconfirmed"
    assert body["routine_status"] == "unconfirmed"
    assert body["last_detail"] == run["detail"]
    status = client.get("/status").json()
    assert status["last_job_id"] == root and status["last_outcome"] == "unconfirmed"


def test_plain_job_has_no_routine_fields(client):
    job = client.post("/execute-buttons", json={"buttons": ["BT-08"], "appliance_id": "microwave"})
    assert job.status_code == 200, job.text
    body = _wait_finished(client, job.json()["job_id"])
    assert body["routine_run_id"] is None and body["routine_status"] is None
