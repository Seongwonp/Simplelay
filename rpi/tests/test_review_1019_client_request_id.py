"""검토 2026-10-19: 실행을 접수했는데 HTTP 응답만 잃으면 클라이언트가 자기 실행 번호를 알 수 없었다.

선택 필드 ``client_request_id``(영문·숫자·_·- 1~64자)를 ``POST /execute``·``/execute-buttons``·``/execute-for-appliance``·
``/suggestions/{id}/approve``가 받는다. 같은 번호로 다시 보내면 같은 ``job_id``를 돌려주고 다시 실행하지 않는다(첫 요청이
아직 접수 중이어도 기다렸다가 같은 번호). ``GET /jobs/by-request/{client_request_id}``는 그 번호의 ``job_id`` 또는 404.
실행 대상은 가짜 — 실물 미검증.
"""

from __future__ import annotations

import threading

from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.deps import get_service, get_suggestion_service
from rpi.api.job_receipts import JobRequestLedger
from rpi.api.router import router
from rpi.tests.test_suggestion_race import CountingSubmitExecutor, build_service


class _CountingService:
    def __init__(self) -> None:
        self.calls: list[tuple] = []
        self.fail_next: Exception | None = None

    def _job(self, *args) -> str:
        if self.fail_next is not None:
            exc, self.fail_next = self.fail_next, None
            raise exc
        self.calls.append(args)
        return f"job-{len(self.calls)}"

    def submit_buttons(self, buttons, appliance_id=None):
        return self._job("buttons", buttons, appliance_id)

    def submit_purpose(self, text, appliance_id=None):
        return self._job("purpose", text, appliance_id)


def _client(service=None, suggestions=None) -> TestClient:
    app = FastAPI()
    app.include_router(router)
    if service is not None:
        app.dependency_overrides[get_service] = lambda: service
    if suggestions is not None:
        app.dependency_overrides[get_suggestion_service] = lambda: suggestions
    return TestClient(app)


def test_repeated_execute_buttons_with_same_request_id_returns_same_job_and_runs_once():
    service = _CountingService()
    client = _client(service)
    body = {"buttons": ["BT-05"], "appliance_id": "microwave", "client_request_id": "phone-1_a"}

    first = client.post("/execute-buttons", json=body)
    retry = client.post("/execute-buttons", json=body)

    assert first.status_code == 200 and retry.status_code == 200, (first.text, retry.text)
    assert retry.json()["job_id"] == first.json()["job_id"]
    assert len(service.calls) == 1
    found = client.get("/jobs/by-request/phone-1_a")
    assert found.status_code == 200
    assert found.json() == {"client_request_id": "phone-1_a", "job_id": first.json()["job_id"]}


def test_execute_purpose_is_idempotent_by_request_id():
    service = _CountingService()
    client = _client(service)
    body = {"text": "즉석밥 데워줘", "appliance_id": "microwave", "client_request_id": "r-2"}
    a = client.post("/execute", json=body).json()["job_id"]
    b = client.post("/execute", json=body).json()["job_id"]
    assert a == b and len(service.calls) == 1


def test_without_request_id_every_request_is_a_new_job():
    service = _CountingService()
    client = _client(service)
    body = {"buttons": ["BT-05"]}
    a = client.post("/execute-buttons", json=body).json()["job_id"]
    b = client.post("/execute-buttons", json=body).json()["job_id"]
    assert a != b and len(service.calls) == 2


def test_failed_admission_leaves_no_receipt_and_the_same_id_can_retry():
    service = _CountingService()
    service.fail_next = RuntimeError("an execution is already in progress")
    client = _client(service)
    body = {"buttons": ["BT-05"], "client_request_id": "busy-1"}

    assert client.post("/execute-buttons", json=body).status_code == 409
    assert client.get("/jobs/by-request/busy-1").status_code == 404
    ok = client.post("/execute-buttons", json=body)
    assert ok.status_code == 200
    assert len(service.calls) == 1


def test_unknown_and_malformed_request_ids():
    client = _client(_CountingService())
    assert client.get("/jobs/by-request/never-sent").status_code == 404
    assert client.get("/jobs/by-request/bad%20id").status_code == 422
    assert client.get("/jobs/by-request/" + "a" * 65).status_code == 422
    bad = client.post("/execute-buttons", json={"buttons": ["BT-05"], "client_request_id": "한글"})
    assert bad.status_code == 422
    long = client.post("/execute-buttons", json={"buttons": ["BT-05"], "client_request_id": "a" * 65})
    assert long.status_code == 422


def test_approve_accepts_request_id_and_maps_it_to_the_job():
    executor = CountingSubmitExecutor()
    suggestions = build_service(executor)
    card = suggestions.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    client = _client(suggestions=suggestions)

    first = client.post(f"/suggestions/{card.suggestion_id}/approve", json={"client_request_id": "ap-1"})
    retry = client.post(f"/suggestions/{card.suggestion_id}/approve", json={"client_request_id": "ap-1"})
    assert first.status_code == 200 and retry.status_code == 200
    assert retry.json()["job_id"] == first.json()["job_id"]
    assert executor.submitted == ["즉석밥 데워줘"]
    assert client.get("/jobs/by-request/ap-1").json()["job_id"] == first.json()["job_id"]
    # 본문 없는 옛 요청도 그대로 된다
    other = suggestions.create_demo_suggestion("물 끓여줘", appliance_id="microwave")
    assert client.post(f"/suggestions/{other.suggestion_id}/approve").status_code == 200


def test_duplicate_waits_for_the_first_admission_and_gets_the_same_job():
    ledger = JobRequestLedger()
    entered = threading.Event()
    release = threading.Event()
    calls: list[int] = []

    def slow_submit() -> str:
        calls.append(1)
        entered.set()
        release.wait(timeout=5)
        return "job-slow"

    results: list[str] = []
    first = threading.Thread(target=lambda: results.append(ledger.admit("dup", slow_submit)))
    first.start()
    assert entered.wait(timeout=5)
    second = threading.Thread(target=lambda: results.append(ledger.admit("dup", slow_submit)))
    second.start()
    lookup: list = []
    third = threading.Thread(target=lambda: lookup.append(ledger.wait_job_for("dup")))
    third.start()
    release.set()
    for t in (first, second, third):
        t.join(timeout=5)
    assert results == ["job-slow", "job-slow"]
    assert lookup == ["job-slow"]
    assert calls == [1]


def test_duplicate_waiting_on_a_failed_admission_gets_the_same_error_and_then_can_retry():
    ledger = JobRequestLedger()
    entered = threading.Event()
    release = threading.Event()

    def failing() -> str:
        entered.set()
        release.wait(timeout=5)
        raise RuntimeError("busy")

    errors: list[str] = []

    def call() -> None:
        try:
            ledger.admit("f", failing)
        except RuntimeError as exc:
            errors.append(str(exc))

    a = threading.Thread(target=call)
    a.start()
    assert entered.wait(timeout=5)
    b = threading.Thread(target=call)
    b.start()
    release.set()
    a.join(timeout=5)
    b.join(timeout=5)
    assert errors == ["busy", "busy"]
    assert ledger.admit("f", lambda: "job-ok") == "job-ok"


def test_receipts_are_bounded():
    ledger = JobRequestLedger(kept=3)
    for i in range(5):
        ledger.admit(f"k{i}", lambda i=i: f"j{i}")
    assert ledger.job_for("k0") is None and ledger.job_for("k1") is None
    assert ledger.job_for("k4") == "j4"
