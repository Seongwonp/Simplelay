"""검토 2026-10-19: ThinQ 직접 명령(``POST /thinq/command``)은 요청 번호를 받지 않아, 접수 응답을 잃은 폰이 다시 보내면
같은 명령을 한 번 더 보냈고 자기 실행 번호도 찾을 수 없었다.

이제 선택 필드 ``client_request_id``를 다른 실행 경로와 같은 영수증 장부로 받는다 — 같은 번호로 다시 보내면 같은 ``job_id``
(다시 보내지 않음), ``GET /jobs/by-request/{id}``로도 찾는다. 번호가 없으면 종전 그대로. 모의 ThinQ — 실물 미검증.
"""

from __future__ import annotations

from rpi.api import deps
from rpi.tests.test_thinq_u1 import _wait_done, client, mock_mode  # noqa: F401 — 픽스처

HIGH = {"appliance_id": "air_purifier", "action": "set_wind_strength", "args": {"wind_strength": "HIGH"}}


def test_retry_with_same_request_id_returns_same_job_and_sends_once(client):
    body = {**HIGH, "client_request_id": "phone-thinq_1"}
    first = client.post("/thinq/command", json=body)
    assert first.status_code == 200, first.text
    job_id = first.json()["job_id"]
    _wait_done(client, job_id)
    controls = list(deps.get_service().thinq_controller.client.controls)
    retry = client.post("/thinq/command", json=body)
    assert retry.status_code == 200 and retry.json() == {"job_id": job_id}
    assert deps.get_service().thinq_controller.client.controls == controls  # 다시 보내지 않았다
    found = client.get("/jobs/by-request/phone-thinq_1")
    assert found.status_code == 200 and found.json() == {"client_request_id": "phone-thinq_1", "job_id": job_id}


def test_without_request_id_behaves_as_before(client):
    a = client.post("/thinq/command", json=HIGH)
    assert a.status_code == 200
    _wait_done(client, a.json()["job_id"])
    b = client.post("/thinq/command", json=HIGH)
    assert b.status_code == 200 and b.json()["job_id"] != a.json()["job_id"]


def test_bad_request_id_is_rejected(client):
    response = client.post("/thinq/command", json={**HIGH, "client_request_id": "has space"})
    assert response.status_code == 422
