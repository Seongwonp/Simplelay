"""'이번에 실행하고 다음부터 자동으로'(approve-and-allow)의 재요청 영수증 (검토 10/19).

첫 요청이 제안을 소비한 뒤 응답만 잃으면, 다시 보낸 요청이 '대기 중 제안' 확인에서 404를 받아 실행 번호와 자동 허용
결과를 알 길이 없었다. 같은 ``client_request_id``로 다시 보내면 **같은 묶음 응답**(job_id + auto_allow)을, 번호 없이 다시
보내면 이미 접수한 실행 번호와 저장된 자동 허용 결과를 돌려준다. 어느 쪽도 다시 실행하지 않는다.

모의 클라우드(127.0.0.1)만 쓴다 — 실제 ThinQ 클라우드·실가전은 쓰지 않는다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_auto_rule_e2e import _env, cloud  # noqa: F401
from rpi.tests.test_cook_done_card import _cards, _inject, _reset, _wait_done


@pytest.fixture()
def api(monkeypatch, tmp_path, cloud):  # noqa: F811
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        yield TestClient(app)
    finally:
        _reset()


def _card(api):
    _inject(api, inputs=("power",))
    return _cards(api)[0]


def _post(api, card, **extra):
    return api.post(f"/suggestions/{card['id']}/approve-and-allow",
                    json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"], **extra})


def test_retry_with_the_same_request_id_returns_the_same_combined_result(api, cloud):  # noqa: F811
    card = _card(api)
    first = _post(api, card, client_request_id="allow-req-1")
    assert first.status_code == 200, first.text
    _wait_done(api, first.json()["job_id"], timeout=10)
    assert first.json()["auto_allow"] == {"ok": True, "reason": None}
    controls = len(cloud.controls())

    retry = _post(api, card, client_request_id="allow-req-1")
    assert retry.status_code == 200, retry.text  # 예전에는 404(대기 중 제안이 아님)
    assert retry.json() == first.json()
    assert len(cloud.controls()) == controls  # 다시 실행하지 않았다
    assert len(api.get("/routines/auto-rules").json()) == 1

    by_request = api.get("/jobs/by-request/allow-req-1")
    assert by_request.status_code == 200, by_request.text
    assert by_request.json()["job_id"] == first.json()["job_id"]


def test_retry_without_a_request_id_returns_the_accepted_job_and_allow_result(api, cloud):  # noqa: F811
    card = _card(api)
    first = _post(api, card)
    assert first.status_code == 200, first.text
    _wait_done(api, first.json()["job_id"], timeout=10)
    controls = len(cloud.controls())

    retry = _post(api, card)
    assert retry.status_code == 200, retry.text
    body = retry.json()
    assert body["job_id"] == first.json()["job_id"]
    assert body["auto_allow"] == first.json()["auto_allow"] == {"ok": True, "reason": None}
    assert body["rule"]["enabled"] is True
    assert len(cloud.controls()) == controls


def test_retry_reports_the_current_rule_state_after_it_was_turned_off(api):
    card = _card(api)
    first = _post(api, card)
    _wait_done(api, first.json()["job_id"], timeout=10)
    rule_id = first.json()["rule"]["id"]
    off = api.post(f"/routines/auto-rules/{rule_id}/enable", json={"enabled": False})
    assert off.status_code == 200, off.text

    retry = _post(api, card)
    assert retry.status_code == 200, retry.text
    assert retry.json()["job_id"] == first.json()["job_id"]
    assert retry.json()["rule"]["enabled"] is False  # 지금 규칙 상태(꺼짐)를 그대로 보인다


def test_approved_with_plain_approve_then_allow_retry_does_not_claim_auto_allow(api, cloud):  # noqa: F811
    card = _card(api)
    approved = api.post(f"/suggestions/{card['id']}/approve")
    assert approved.status_code == 200, approved.text
    _wait_done(api, approved.json()["job_id"], timeout=10)
    controls = len(cloud.controls())

    res = _post(api, card)
    assert res.status_code == 200, res.text
    assert res.json()["job_id"] == approved.json()["job_id"]
    assert res.json()["auto_allow"]["ok"] is False
    assert api.get("/routines/auto-rules").json() == [] or not any(
        r["enabled"] for r in api.get("/routines/auto-rules").json())
    assert len(cloud.controls()) == controls


def test_unknown_suggestion_is_still_404(api):
    res = api.post("/suggestions/no-such-card/approve-and-allow", json={"offer_fingerprint": "x"})
    assert res.status_code == 404


@pytest.mark.parametrize("bad", ["", "has space", "x" * 65, 7])
def test_invalid_request_id_is_422_and_nothing_runs(api, bad):
    card = _card(api)
    res = _post(api, card, client_request_id=bad)
    assert res.status_code == 422, res.text
    assert _cards(api) and _cards(api)[0]["id"] == card["id"]  # 카드는 그대로
