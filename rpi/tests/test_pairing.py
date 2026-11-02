import base64
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from rpi.api import auth, pairing
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
    # 받았음 알림(ack) 전에는 같은 키를 다시 받을 수 있고, 알린 뒤에는 그 토큰이 끝난다(검토 10/19).
    assert phone().post("/pair/ack", json={"token": pending["token"]}).status_code == 200
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 404
    assert phone().post("/pair", json={"code": data["code"]}).status_code == 409


@pytest.mark.parametrize("method,path,body", [
    ("post", "/pair/session", None), ("get", "/pair/session", None),
    ("delete", "/pair/session", None),
    ("get", "/pair/phones", None),
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


# ── 검토 2026-10-19: 키를 돌려준 응답을 폰이 잃으면 같은 토큰이 영영 404였다 ──


def _approved():
    data, pending = begin()
    local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": True})
    return data, pending


def test_lost_result_response_can_be_fetched_again_until_ack(window):
    _, pending = _approved()
    first = phone().post("/pair/result", json={"token": pending["token"]})
    assert first.json() == {"state": "approved", "api_key": "test-pair-key"}
    # 응답을 잃은 폰이 다시 물으면 같은 키를 받는다(창이 열려 있는 동안).
    again = phone().post("/pair/result", json={"token": pending["token"]})
    assert again.status_code == 200 and again.json() == {"state": "approved", "api_key": "test-pair-key"}
    # 허브 화면은 키를 보낸 것으로 본다(옛 화면 문구 그대로).
    assert local().get("/pair/session").json()["state"] == "consumed"
    ack = phone().post("/pair/ack", json={"token": pending["token"]})
    assert ack.status_code == 200 and ack.json() == {"state": "consumed"}
    assert ack.headers["cache-control"] == "no-store"
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 404
    # 받았음 알림의 응답을 잃어 다시 보내도 같은 답이다.
    assert phone().post("/pair/ack", json={"token": pending["token"]}).json() == {"state": "consumed"}


def test_refetch_still_expires_and_wrong_token_cannot_ack(window):
    _, pending = _approved()
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 200
    assert phone().post("/pair/ack", json={"token": "x" * 32}).status_code == 404
    window[1][0] += 300
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 410
    assert phone().post("/pair/ack", json={"token": pending["token"]}).status_code == 410


def test_ack_before_approval_is_refused(window):
    _, pending = begin()
    assert phone().post("/pair/ack", json={"token": pending["token"]}).status_code == 409
    assert phone().post("/pair/result", json={"token": pending["token"]}).json() == {"state": "pending"}


# ── 첫 환영 화면의 판단 근거: 연결된 휴대폰 수. 키오스크는 루프백이라 키 없이 통과하므로 '키오스크 인증'과 섞이면 안 된다 ──


class _Db:
    """설정 칸과 옛 사용 흔적만 흉내 낸다."""

    def __init__(self, appliances=(), routines=(), history=(), broken=False):
        self.settings = {}
        self._appliances, self._routines, self._history = appliances, routines, history
        self.broken = broken

    def load_setting(self, key):
        if self.broken:
            raise sqlite3.OperationalError("database is locked")
        return self.settings.get(key)

    def save_setting(self, key, value):
        if self.broken:
            raise sqlite3.OperationalError("database is locked")
        self.settings[key] = value

    def appliances(self):
        return self._appliances

    def routine_documents(self):
        return self._routines

    def recent_job_history(self, limit=50):
        return self._history


@pytest.fixture
def ledger(window, monkeypatch):
    db = _Db()
    monkeypatch.setattr(pairing, "phone_ledger", pairing.PhoneLedger(lambda: db))
    monkeypatch.setattr(auth, "_lan_key_used", False)
    return db


def phones():
    response = local().get("/pair/phones")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    return response.json()["phones"]


def test_fresh_hub_has_no_phone_and_the_answer_is_kept(ledger):
    assert phones() == 0
    assert ledger.settings[pairing.PHONES_SETTING] == "0"


def test_kiosk_itself_is_not_a_phone(ledger):
    # 키오스크는 키 없이 통과한다 — 그 요청이 '연결된 폰'이 되면 환영 화면이 영영 안 뜬다.
    assert local().get("/status").status_code == 200
    assert phones() == 0


def test_phone_counts_only_after_the_key_was_handed_over(ledger):
    _, pending = begin()
    assert phones() == 0, "코드만 넣은 폰은 아직 연결된 폰이 아니다"
    local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": True})
    assert phones() == 0, "허락만 하고 키를 안 가져갔다"
    for _ in range(3):  # 응답을 잃은 폰이 다시 물어도 한 대다
        assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 200
    assert phones() == 1
    assert phones() == 1


def test_denied_phone_does_not_count(ledger):
    _, pending = begin()
    local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": False})
    phone().post("/pair/result", json={"token": pending["token"]})
    assert phones() == 0


def test_count_survives_a_hub_restart(ledger, monkeypatch):
    _, pending = begin()
    local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": True})
    phone().post("/pair/result", json={"token": pending["token"]})
    monkeypatch.setattr(pairing, "phone_ledger", pairing.PhoneLedger(lambda: ledger))
    assert phones() == 1


def test_phone_using_the_key_on_the_network_counts(ledger):
    # 코드 연결 전부터 쓰던 폰, '연결 비밀번호'를 직접 넣은 폰 — 연결 기록은 없어도 이미 연결된 본체다.
    assert phones() == 0
    assert phone().get("/status", headers={"X-API-Key": "test-pair-key"}).status_code == 200
    assert phones() == 1


def test_wrong_key_on_the_network_does_not_count(ledger):
    assert phone().get("/status", headers={"X-API-Key": "wrong-key"}).status_code == 401
    assert phones() == 0


@pytest.mark.parametrize("trace", [
    {"appliances": ("에어컨",)}, {"routines": (("r1", "{}"),)}, {"history": ("job",)},
])
def test_hub_used_before_this_record_existed_is_not_treated_as_new(window, monkeypatch, trace):
    # 이 기록이 생기기 전에 연결해 쓰던 본체가 배포 직후 '0대'로 보이면 첫 환영 화면이 뜬다.
    db = _Db(**trace)
    monkeypatch.setattr(pairing, "phone_ledger", pairing.PhoneLedger(lambda: db))
    monkeypatch.setattr(auth, "_lan_key_used", False)
    assert phones() == 1


def test_traces_are_read_once_so_a_recorded_answer_stands(ledger):
    assert phones() == 0
    ledger._appliances = ("에어컨",)
    assert phones() == 0, "기록이 있으면 그 값이 답이다 — 첫 값을 0으로 되돌리면 환영 화면을 다시 볼 수 있다"


@pytest.mark.parametrize("make", [
    lambda: None,  # 저장소가 없는 구성 — 재시작하면 잊으니 0이라고 말하지 않는다
    lambda: _Db(broken=True),
])
def test_unknown_is_not_zero(window, monkeypatch, make):
    db = make()
    monkeypatch.setattr(pairing, "phone_ledger", pairing.PhoneLedger(lambda: db))
    monkeypatch.setattr(auth, "_lan_key_used", False)
    assert phones() is None


def test_unreadable_record_is_not_zero(ledger):
    ledger.settings[pairing.PHONES_SETTING] = "망가진 값"
    assert phones() is None


def test_phone_delivered_while_store_failed_is_saved_when_it_recovers(ledger):
    _, pending = begin()
    local().post("/pair/approve", json={"request_id": pending["request_id"], "approved": True})
    ledger.broken = True
    assert phone().post("/pair/result", json={"token": pending["token"]}).status_code == 200, "저장 실패가 키 받기를 막으면 안 된다"
    assert phones() is None
    ledger.broken = False
    assert phones() == 1
