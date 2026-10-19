"""검토 2026-10-19 (A): 승인이 소비되고 실행이 접수됐는데 HTTP 응답만 잃으면, 다시 보낸 승인이 409('이미 승인')만 받아
클라이언트가 실행 번호(job_id)를 알 수 없었다. 이제 같은 제안의 재승인은 200과 **같은 실행 번호**를 돌려준다(다시 실행하지 않는다).
"""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.deps import get_suggestion_service
from rpi.api.router import router
from rpi.tests.test_suggestion_race import CountingSubmitExecutor, build_service


def _api(service) -> TestClient:
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_suggestion_service] = lambda: service
    return TestClient(app)


def test_retried_approve_returns_the_same_job_without_running_again():
    executor = CountingSubmitExecutor()
    service = build_service(executor)
    card = service.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    client = _api(service)

    first = client.post(f"/suggestions/{card.suggestion_id}/approve")
    assert first.status_code == 200
    job_id = first.json()["job_id"]

    # 첫 응답을 잃었다고 보고 다시 보낸다.
    retry = client.post(f"/suggestions/{card.suggestion_id}/approve")
    assert retry.status_code == 200, retry.text
    assert retry.json()["job_id"] == job_id
    assert executor.submitted == ["즉석밥 데워줘"]  # 물리 실행은 한 번
    assert service.accepted_job(card.suggestion_id) == job_id


def test_failed_submission_leaves_no_receipt_and_the_card_can_be_approved_again():
    """접수 자체가 실패했으면(바쁨 등) 영수증이 없다 — 카드는 다시 승인할 수 있고, 그때 새로 접수한다."""
    executor = CountingSubmitExecutor()
    service = build_service(executor)
    card = service.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    original = executor.submit_purpose
    calls = {"n": 0}

    def busy_once(purpose, appliance_id=None, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("다른 일을 하고 있어요")
        return original(purpose, appliance_id, **kw)

    executor.submit_purpose = busy_once
    client = _api(service)
    assert client.post(f"/suggestions/{card.suggestion_id}/approve").status_code == 409
    assert service.accepted_job(card.suggestion_id) is None
    ok = client.post(f"/suggestions/{card.suggestion_id}/approve")
    assert ok.status_code == 200
    assert executor.submitted == ["즉석밥 데워줘"]
