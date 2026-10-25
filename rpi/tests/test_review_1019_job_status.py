"""검토 2026-10-19: /status는 마지막 한 건의 결과만 보여, 그 사이 다른 실행이 끝나면 클라이언트가 자기 실행의 결과를 잃었다.

``GET /jobs/{job_id}``는 실행 번호 하나의 상태·결과를 /status와 같은 필드 이름으로 돌려준다(최근 64건, 모르면 404):
실행 중이면 ``running: true``·``finished: false``·``job_id``·진행 필드(last_*는 null), 끝났으면 ``finished: true``·
``last_job_id``·last_*. 버튼 실행·ThinQ·여러 단계(기본 번호와 ``<기본>-<n>`` 단계 번호)·루틴 구간 모두. 실행 대상은 가짜 — 실물 미검증.
"""

from __future__ import annotations

import threading
import time

from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api import SimpleLayService, deps
from rpi.api.router import router
from rpi.api.service import JOB_RESULTS_KEPT
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.tests.test_review_1019_plan_stop_status import NOW, _setup
from rpi.tests.test_thinq_u1 import _wait_done, client, mock_mode  # noqa: F401 — 픽스처


class _Controller:
    """버튼별 성공·실패를 정하는 가짜 실행 대상. ``gate``가 있으면 그것이 열릴 때까지 누르지 않는다."""

    def __init__(self) -> None:
        self.fail_buttons: set[str] = set()
        self.gate: threading.Event | None = None
        self.entered = threading.Event()

    def execute(self, buttons, targets=None):
        self.entered.set()
        if self.gate is not None:
            self.gate.wait(timeout=5)
        results = tuple(
            ButtonResult(b, ButtonStatus.FAILED if b in self.fail_buttons else ButtonStatus.SUCCEEDED, 1, None)
            for b in buttons
        )
        failed = any(r.status is ButtonStatus.FAILED for r in results)
        return ExecutionResult(ExecutionStatus.FAILED if failed else ExecutionStatus.SUCCEEDED, results)


def _api(service) -> TestClient:
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[deps.get_service] = lambda: service
    return TestClient(app)


def _service(controller) -> SimpleLayService:
    return SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW))


def _wait_idle(service, job_id) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        snap = service.status()
        if not snap.running and snap.last_job_id == job_id:
            return
        time.sleep(0.005)
    raise AssertionError("job did not finish")


def test_earlier_job_result_survives_a_later_job():
    controller = _Controller()
    controller.fail_buttons = {"BT-09"}
    service = _service(controller)
    api = _api(service)

    first = service.submit_buttons(("BT-09",), appliance_id="a1")
    _wait_idle(service, first)
    second = service.submit_buttons(("BT-05",), appliance_id="a2")
    _wait_idle(service, second)

    assert api.get("/status").json()["last_job_id"] == second
    body = api.get(f"/jobs/{first}").json()
    assert body["finished"] is True and body["running"] is False
    assert body["last_job_id"] == first and body["job_id"] is None
    assert body["last_status"] == "failed" and body["last_outcome"] == "failed"
    assert body["last_appliance_id"] == "a1"
    assert body["last_buttons"] == [{"button": "BT-09", "success": False, "attempts": 1}]
    assert body["last_route"] == "physical"
    assert body["step"] is None
    # 기기 전체 값은 싣지 않는다
    assert body["estop_latched"] is None and body["actuator_link_up"] is None
    later = api.get(f"/jobs/{second}").json()
    assert later["last_status"] == "succeeded" and later["last_appliance_id"] == "a2"


def test_running_job_reports_progress_without_the_previous_result():
    controller = _Controller()
    service = _service(controller)
    api = _api(service)
    done = service.submit_buttons(("BT-05",), appliance_id="a1")
    _wait_idle(service, done)

    controller.gate = threading.Event()
    controller.entered.clear()
    running = service.submit_buttons(("BT-05", "BT-06"), appliance_id="a2")
    try:
        assert controller.entered.wait(timeout=5)
        body = api.get(f"/jobs/{running}").json()
        assert body["running"] is True and body["finished"] is False
        assert body["job_id"] == running and body["appliance_id"] == "a2"
        assert body["total_steps"] == 2
        # 직전 실행(a1)의 결과를 이 실행 것처럼 싣지 않는다
        assert body["last_job_id"] is None and body["last_status"] is None
        assert body["last_appliance_id"] is None and body["last_buttons"] is None
    finally:
        controller.gate.set()
    _wait_idle(service, running)
    assert api.get(f"/jobs/{running}").json()["finished"] is True


def test_unknown_job_is_404_and_results_are_bounded():
    controller = _Controller()
    service = _service(controller)
    api = _api(service)
    assert api.get("/jobs/nope").status_code == 404
    first = service.submit_buttons(("BT-05",))
    _wait_idle(service, first)
    last = first
    for _ in range(JOB_RESULTS_KEPT):
        last = service.submit_buttons(("BT-05",))
        _wait_idle(service, last)
    assert api.get(f"/jobs/{first}").status_code == 404
    assert api.get(f"/jobs/{last}").status_code == 200


def test_plan_base_and_step_ids_report_their_own_results():
    controller, service, _history, approved = _setup()
    controller.on_execute = service.emergency_stop_report  # 첫 단계를 누르는 중 /stop → 둘째 단계는 보내지 않음
    record = service.execute_approved(approved)
    api = _api(service)

    base = api.get(f"/jobs/{record.job_id}").json()
    assert base["finished"] is True and base["last_job_id"] == record.job_id
    assert base["last_outcome"] == "stopped" and base["last_receipt"] == "not_dispatched"
    assert base["last_appliance_id"] == "microwave"

    step1 = api.get(f"/jobs/{record.job_id}-1").json()
    assert step1["step"] == 1 and step1["last_job_id"] == f"{record.job_id}-1"
    assert step1["last_appliance_id"] == "microwave" and step1["last_route"] == "physical"
    assert step1["last_status"] == "succeeded"
    assert [b["button"] for b in step1["last_buttons"]] == list(approved[0].command.buttons)

    step2 = api.get(f"/jobs/{record.job_id}-2").json()
    assert step2["step"] == 2 and step2["last_appliance_id"] == "induction"
    assert step2["last_outcome"] == "stopped" and step2["last_receipt"] == "not_dispatched"
    assert step2["last_detail"] == "정지를 눌러서 보내지 않았어요."

    assert api.get(f"/jobs/{record.job_id}-3").status_code == 404
    assert api.get(f"/jobs/{record.job_id}-0").status_code == 404


def test_thinq_job_result_survives_a_later_physical_job(client):  # noqa: F811
    thinq = client.post("/execute", json={"text": "강풍으로 바꿔줘", "appliance_id": "air_purifier"})
    assert thinq.status_code == 200, thinq.text
    thinq_id = thinq.json()["job_id"]
    _wait_done(client, thinq_id)
    physical = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    _wait_done(client, physical.json()["job_id"])

    body = client.get(f"/jobs/{thinq_id}").json()
    assert body["finished"] is True and body["last_job_id"] == thinq_id
    assert body["last_route"] == "thinq"
    assert body["last_status"] == "succeeded" and body["last_outcome"] == "success"
    assert body["last_confirmation"] == "state_confirmed"
    assert body["last_execution_mode"] == "mock"
    assert body["last_appliance_id"] == "air_purifier"
    assert client.get("/status").json()["last_route"] == "physical"
