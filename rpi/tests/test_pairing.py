import base64
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from rpi.api import pairing
from rpi.main import app


@pytest.fixture
def window(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_API_KEY", "test-pair-key")
    monkeypatch.setenv("SIMPLELAY_PAIR_HOST", "http://192.0.2.10:8000")
    clock = [100.0]
    window = pairing.PairingWindow(lambda: clock[0])
    monkeypatch.setattr(pairing, "pairing_window", window)
    return window, clock


def local():
    return TestClient(app, client=("127.0.0.1", 1234))


def phone():
    return TestClient(app, client=("192.0.2.20", 1234))


def begin():
    screen = local().post("/pair/session")
    assert screen.status_code == 200
    data = screen.json()
    pending = phone().post("/pair", json={"code": data["code"], "phone": "시험 폰"})
    assert pending.status_code == 200
    return data, pending.json()


def test_approval_then_one_time_key(window):
    data, pending = begin()
    assert len(data["code"]) == 6 and data["code"].isdigit()
    assert data["expires_in"] == 300
    assert "simplelay://pair?" in data["uri"]
    assert base64.b64decode(data["qr_png"]).startswith(b"\x89PNG")
    assert "test-pair-key" not in str(data)
    assert "api_key" not in pending
    result = phone().post("/pair/result", json={"token": pending["token"]})
    assert result.json() == {"state": "pending"}
    assert result.headers["cache-control"] == "no-store"
    state = local().get("/pair/session").json()
    assert state["phone"] == "시험 폰"
    assert "token" not in state and "key" not in state
    assert local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": True}).status_code == 200
    response = phone().post("/pair/result", json={"token": pending["token"]})
    assert response.json() == {"state": "approved", "api_key": "test-pair-key"}
    assert response.headers["cache-control"] == "no-store"
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 404
    assert phone().post("/pair", json={"code": data["code"]}).status_code == 409


@pytest.mark.parametrize("method,path,body", [
    ("post", "/pair/session", None), ("get", "/pair/session", None),
    ("delete", "/pair/session", None),
    ("post", "/pair/approve", {"request_id": "a" * 32, "approved": True}),
])
def test_only_local_screen_can_create_read_cancel_approve(window, method, path, body):
    assert phone().request(method, path, json=body, headers={"X-API-Key": "test-pair-key"}).status_code == 403


def test_foreign_browser_origin_cannot_open_local_window(window):
    assert local().post("/pair/session", headers={"Origin": "https://foreign.test"}).status_code == 403
    assert local().post("/pair/session", headers={"Origin": "http://foreign.test", "Host": "foreign.test"}).status_code == 403


@pytest.mark.parametrize("approve_first", [False, True])
def test_expiration_including_after_approval(window, approve_first):
    _, pending = begin()
    if approve_first:
        local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": True})
    window[1][0] += 300
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 410
    assert local().get("/pair/session").status_code == 410


def test_wrong_guesses_are_bounded(window):
    code = local().post("/pair/session").json()["code"]
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(5):
        assert phone().post("/pair", json={"code": wrong}).status_code == 400
    assert phone().post("/pair", json={"code": code}).status_code == 429


def test_denial_wrong_token_and_wrong_request(window):
    _, pending = begin()
    assert phone().post("/pair/result", json={"token": "x" * 32}).status_code == 404
    assert local().post("/pair/approve", json={"request_id": "x" * 32, "approved": True}).status_code == 409
    local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": False})
    assert phone().post("/pair/result", json={"token": pending["token"]}).json() == {"state": "denied"}


def test_key_rotation_cancellation_and_new_window_invalidate_old_request(window, monkeypatch):
    _, pending = begin()
    monkeypatch.setenv("SIMPLELAY_API_KEY", "rotated-test-key")
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 410
    _, pending = begin()
    local().delete("/pair/session")
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 410
    _, pending = begin()
    local().post("/pair/session")
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 404


def test_no_configured_key_does_not_open_pairing(window, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY")
    assert local().post("/pair/session").status_code == 503


def test_two_phones_cannot_claim_same_code(window):
    store = window[0]
    code = store.open("http://192.0.2.10:8000")["code"]
    def claim():
        try:
            store.claim(code, "폰")
            return 200
        except HTTPException as exc:
            return exc.status_code
    with ThreadPoolExecutor(2) as pool:
        assert sorted(pool.map(lambda _: claim(), range(2))) == [200, 409]
