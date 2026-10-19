"""검토 2026-10-19: 쉬고 있던 클라이언트가 /status로 루틴을 알아챌 때 루틴이 이미 2번째 구간 이후면 그 구간 번호만 알았다.

그래서 구간 하나만 보여 주다 그 구간이 끝나면 루틴은 이어 가는데 '끝났어요'로 말했다. 이제 /status는 루틴이 도는 동안
(구간 실행 중·구간 사이 기다림 포함) ``routine_run_id``(첫 번호)·``routine_status``·``routine_segment``(1부터)·
``routine_segment_job_id``를 싣고, ``GET /jobs/{구간 번호}``도 ``routine_run_id``를 실어 첫 번호로 갈아탈 수 있게 한다.
실행 대상은 모의 — 실물 미검증.
"""

from __future__ import annotations

import threading

from rpi.routines.wiring import get_routine_engine
from rpi.tests.test_review_1019_routine_job_status import _wait_finished
from rpi.tests.test_routines import HEAT, PURIFIER_ON, _body, _wait_run, client  # noqa: F401 — 픽스처

WAIT = {"kind": "wait_until_done", "appliance_id": "microwave"}


def _start_held_at_second_wait(client, gate: threading.Event):
    """구간 셋(데우기 · 데우기 · 공기청정기) 루틴을 승인하고, 2번째 구간 뒤 기다림에서 ``gate``까지 멈춘다."""
    steps = [HEAT, WAIT, HEAT, WAIT, PURIFIER_ON]
    rid = client.post("/routines", json=_body(steps=steps)).json()["id"]
    card = client.post(f"/routines/{rid}/trigger").json()["suggestion"]
    runner = get_routine_engine().runner
    original = runner._check_done
    calls = []
    entered = threading.Event()

    def held(run, appliance_id):
        calls.append(appliance_id)
        if len(calls) == 2:
            entered.set()
            gate.wait(timeout=10)
        return original(run, appliance_id)

    runner._check_done = held
    response = client.post(f"/suggestions/{card['id']}/approve")
    assert response.status_code == 200, response.text
    assert entered.wait(timeout=5), "routine did not reach the second wait"
    return response.json()["job_id"]


def test_status_names_the_routine_while_it_waits_after_segment_two(client):
    gate = threading.Event()
    try:
        root = _start_held_at_second_wait(client, gate)
        run = get_routine_engine().runner.get(root)
        assert run is not None and len(run.job_ids) == 2
        second = run.job_ids[1]
        assert second != root

        status = client.get("/status").json()
        assert status["running"] is False
        assert status["routine_run_id"] == root
        assert status["routine_status"] == "running"
        assert status["routine_segment"] == 2
        assert status["routine_segment_job_id"] == second

        segment = client.get(f"/jobs/{second}").json()
        assert segment["routine_run_id"] == root
        assert segment["routine_status"] == "running"
        assert segment["routine_segment"] == 2
        assert segment["routine_segment_job_id"] == second
        # 구간 번호 자체는 그 구간 것 그대로(끝남) — 클라이언트는 routine_run_id로 갈아탄다.
        assert segment["finished"] is True and segment["last_job_id"] == second

        root_body = client.get(f"/jobs/{root}").json()
        assert root_body["running"] is True and root_body["finished"] is False
        assert root_body["routine_segment"] == 2
    finally:
        gate.set()
    done = _wait_run(client, root)
    assert done["status"] == "succeeded" and len(done["job_ids"]) == 3
    _wait_finished(client, root)
    # 루틴이 끝나면 /status는 루틴 필드를 싣지 않는다(last_job_id가 첫 번호).
    status = client.get("/status").json()
    assert status["last_job_id"] == root
    assert status["routine_run_id"] is None and status["routine_segment"] is None


def test_status_has_no_routine_fields_for_a_plain_job(client):
    job = client.post("/execute-buttons", json={"buttons": ["BT-08"], "appliance_id": "microwave"})
    assert job.status_code == 200, job.text
    _wait_finished(client, job.json()["job_id"])
    status = client.get("/status").json()
    assert status["routine_run_id"] is None and status["routine_status"] is None
    assert status["routine_segment"] is None and status["routine_segment_job_id"] is None


def test_status_names_the_routine_while_segment_two_is_running(monkeypatch):
    """2번째 구간이 실행 중일 때 — /status의 ``job_id``는 그 구간이고 루틴 첫 번호·순번을 함께 싣는다."""
    from types import SimpleNamespace

    from rpi.api import router as api_router
    from rpi.routines import RunStatus, wiring

    run = SimpleNamespace(run_id="root", job_ids=["root", "seg2"], status=RunStatus.RUNNING)
    monkeypatch.setattr(wiring, "routine_run_containing",
                        lambda job_id: run if job_id in run.job_ids else None)
    fields = api_router._routine_status_fields({"running": True, "job_id": "seg2", "last_job_id": "root"})
    assert fields["job_id"] == "seg2" and fields["last_job_id"] is None
    assert fields["routine_run_id"] == "root" and fields["routine_status"] == "running"
    assert fields["routine_segment"] == 2 and fields["routine_segment_job_id"] == "seg2"
