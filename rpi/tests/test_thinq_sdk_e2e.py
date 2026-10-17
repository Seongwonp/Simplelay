"""끝-끝: 허브 API → 공식 SDK → 모의 ThinQ 클라우드 (2026-10-13, 단계 3).

``SIMPLELAY_THINQ_MODE=fake_cloud``로 서버를 조립하면 ``ThinQApi``(공식 SDK)가 실제로 요청을
만들고, 주소만 저장소 안 모의 클라우드(127.0.0.1)로 간다. 승인 카드 → 제어 → 상태 재조회 →
기록까지 U1-a 계약(승인 결속·확인 수준·자동 재전송 없음)을 그대로 지키는지 본다.

**실제 ThinQ 클라우드·실가전은 한 번도 부르지 않는다.** 모의 클라우드 결과는 실행 환경
``mock``이고 가전 이름에 '(모의 클라우드)'가 붙는다. 마지막 시험 하나는 **real 모드의 코드
경로**가 결과를 ``real``로 적는지만 보려고 SDK 생성자에 모의 클라우드 주소를 시험 안에서
끼워 넣는다 -- 실제 클라우드 성공 판정이 아니다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.tests.test_thinq_u1 import _reset, _wait_done

pytest.importorskip("thinqconnect")

from rpi.tools.fake_thinq_cloud import FakeThinqCloud, default_devices  # noqa: E402

from rpi.services.thinq.profiles_sample import air_purifier_profile  # noqa: E402

SECRET_PAT = "pat-SECRET-e2e-do-not-log-51c2"


def _env(monkeypatch, tmp_path, cloud, mode="fake_cloud"):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", mode)
    if mode == "fake_cloud":
        monkeypatch.setenv("SIMPLELAY_THINQ_FAKE_CLOUD_URL", cloud.base_url)
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "2")
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", cloud.device_id("air_purifier"))
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_WASHER", cloud.device_id("washer"))
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_DEHUMIDIFIER", cloud.device_id("dehumidifier"))
    monkeypatch.setenv("SIMPLELAY_V2_SCENARIOS", "1")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    monkeypatch.delenv("SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE", raising=False)


@pytest.fixture()
def cloud():
    fake = FakeThinqCloud()
    fake.start()
    yield fake
    fake.stop()


@pytest.fixture()
def api(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _command(api, appliance_id, action, args):
    response = api.post("/thinq/command", json={"appliance_id": appliance_id, "action": action,
                                                "args": args})
    assert response.status_code == 200, response.text
    return _wait_done(api, response.json()["job_id"], timeout=10)


def _no_secret(api, *bodies):
    texts = [str(b) for b in bodies] + [api.get("/history").text, api.get("/status").text]
    assert all(SECRET_PAT not in t for t in texts)


# ── 승인 카드 → 제어 → 상태 재조회 → 기록 ──────────────────────────────────


def test_scenario_card_approval_runs_through_sdk_to_fake_cloud(api, cloud):
    job = api.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert _wait_done(api, job.json()["job_id"])["last_status"] == "succeeded"
    assert cloud.controls() == []  # 승인 없는 자동 실행 없음

    cards = [s for s in api.get("/suggestions").json() if s.get("scenario_id") == "cook_then_air"]
    assert len(cards) == 1
    card = cards[0]
    assert card["is_demo"] is True
    assert card["commands"][0]["summary"] == "공기청정기(모의 클라우드) 바람 세기 강"

    approved = api.post(f"/suggestions/{card['id']}/approve")
    assert approved.status_code == 200, approved.text
    status = _wait_done(api, approved.json()["job_id"], timeout=10)
    assert status["last_route"] == "thinq"
    assert status["last_status"] == "succeeded"
    assert status["last_confirmation"] == "state_confirmed"
    assert status["last_execution_mode"] == "mock"  # 모의 클라우드 -- 실제 클라우드 성공 아님

    device = cloud.device_id("air_purifier")
    controls = cloud.controls()
    assert len(controls) == 1
    assert controls[0]["path"] == f"/devices/{device}/control"
    assert controls[0]["body"] == {"airFlow": {"windStrength": "HIGH"}}
    assert controls[0]["public_headers"]["x-conditional-control"] == "true"
    # 보낸 뒤 상태를 다시 조회해 확인했다.
    after = [r for r in cloud.requests() if r["at"] >= controls[0]["at"]]
    assert any(r["path"] == f"/devices/{device}/state" for r in after[1:])
    # 보내기 전에 프로필을 읽었다(실행 전 판정).
    assert any(r["path"] == f"/devices/{device}/profile" for r in cloud.requests())

    history = api.get("/history").json()[0]
    assert (history["route"], history["receipt"], history["confirmation"]) == (
        "thinq", "accepted", "state_confirmed")
    re_query = api.get("/thinq/status/air_purifier").json()
    assert re_query["state"]["airFlow"]["windStrength"] == "HIGH"
    assert re_query["execution_mode"] == "mock"
    _no_secret(api, card, status, re_query)


def test_devices_view_shows_profile_support_and_mock_cloud(api):
    body = api.get("/thinq/devices").json()
    assert body["mode"] == "fake_cloud" and body["execution_mode"] == "mock"
    names = {a["appliance_id"]: a for a in body["appliances"]}
    assert names["air_purifier"]["name"] == "공기청정기(모의 클라우드)"
    wind = next(c for c in names["air_purifier"]["capabilities"] if c["action"] == "set_wind_strength")
    assert wind["profile_allowed"] == ["LOW", "MID", "HIGH", "AUTO"]


# ── 세탁기 원격 시작 ───────────────────────────────────────────────────────


def test_washer_start_refused_while_remote_off_then_runs_when_on(api, cloud):
    washer = cloud.device_id("washer")
    readiness = api.get("/readiness/thinq_washer").json()
    assert readiness["can_execute"] is False and readiness["state"] == "needs_setup"
    assert any("원격" in r for r in readiness["reasons"])
    refused = api.post("/thinq/command", json={"appliance_id": "thinq_washer",
                                               "action": "set_operation", "args": {"operation": "START"}})
    assert refused.status_code == 412
    assert "원격" in refused.text
    assert cloud.controls() == []

    cloud.set_remote_control(washer, True)
    api.get("/thinq/status/thinq_washer")  # 준비 판정 캐시를 새 상태로
    status = _command(api, "thinq_washer", "set_operation", {"operation": "START"})
    assert status["last_status"] == "succeeded" and status["last_confirmation"] == "state_confirmed"
    assert cloud.controls()[-1]["body"] == {"location": {"locationName": "MAIN"},
                                            "operation": {"washerOperationMode": "START"}}
    status = _command(api, "thinq_washer", "set_operation", {"operation": "STOP"})
    assert status["last_status"] == "succeeded"
    assert cloud.state(washer)[0]["runState"]["currentState"] == "PAUSE"


def test_value_outside_model_profile_is_refused_before_sending(monkeypatch, tmp_path):
    devices = default_devices()
    devices["fake-ap-0001"]["profile"] = air_purifier_profile(job_modes_w=("CLEAN", "SLEEP"))
    fake = FakeThinqCloud(devices=devices)
    fake.start()
    try:
        _env(monkeypatch, tmp_path, fake)
        _reset()
        from rpi.main import app

        api = TestClient(app)
        status = _command(api, "air_purifier", "set_job_mode", {"job_mode": "SILENT"})
        assert status["last_status"] == "failed"
        assert status["last_receipt"] == "not_dispatched"
        assert "쓸 수 없어요" in status["last_detail"]
        assert fake.controls() == []
    finally:
        fake.stop()
        _reset()


# ── 오류: 토큰·호출 초과·응답 유실·접수 후 상태 미확인 ─────────────────────


def test_invalid_token_blocks_with_human_reason(api, cloud):
    cloud.set_fault("invalid_token")
    readiness = api.get("/readiness/air_purifier").json()
    assert readiness["can_execute"] is False
    assert any("LG 계정 연결" in r for r in readiness["reasons"])
    refused = api.post("/thinq/command", json={"appliance_id": "air_purifier",
                                               "action": "set_wind_strength",
                                               "args": {"wind_strength": "HIGH"}})
    assert refused.status_code == 412
    devices = api.get("/thinq/devices").json()
    assert devices["client_reachable"] is False and "LG 계정 연결" in devices["error"]
    assert cloud.controls() == []
    _no_secret(api, readiness, refused.text, devices)


def test_cloud_call_limit_blocks_with_human_reason(api, cloud):
    cloud.set_fault("rate_limit")
    readiness = api.get("/readiness/air_purifier").json()
    assert readiness["can_execute"] is False
    assert any("너무 많았어요" in r for r in readiness["reasons"])
    assert cloud.controls() == []


def test_lost_control_response_is_unknown_receipt_and_never_resent(api, cloud):
    device = cloud.device_id("air_purifier")
    cloud.set_fault("drop_control_response", device_id=device)
    status = _command(api, "air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})
    assert status["last_status"] == "unconfirmed"
    assert status["last_receipt"] == "unknown"
    assert status["last_confirmation"] == "none"
    assert len(cloud.controls()) == 1  # 자동 재전송 없음
    # 가전(모의)은 받았다 -- 재조회로만 보인다.
    assert api.get("/thinq/status/air_purifier").json()["state"]["airFlow"]["windStrength"] == "HIGH"


def test_cloud_rejecting_the_control_is_failed_not_success(api, cloud):
    """제어 실패: 클라우드가 거절하면 실패(실행 안 됨)로, 사람 말 이유와 코드를 남긴다."""
    device = cloud.device_id("air_purifier")
    cloud.set_fault("reject_control", device_id=device)
    status = _command(api, "air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})
    assert (status["last_status"], status["last_receipt"], status["last_confirmation"]) == (
        "failed", "accepted", "none")
    assert "모드" in status["last_detail"] and "바뀌지 않았어요" in status["last_detail"]
    assert cloud.state(device)["airFlow"]["windStrength"] == "LOW"
    assert len(cloud.controls()) == 1


def test_cloud_connection_lost_before_sending_is_not_sent(api, cloud):
    """연결 끊김: 준비 판정이 캐시로 통과해도, 보내기 전 상태 조회가 끊기면 보내지 않았다고 적는다."""
    first = _command(api, "air_purifier", "set_wind_strength", {"wind_strength": "MID"})
    assert first["last_status"] == "succeeded"
    cloud.stop()  # 클라우드가 사라졌다(인터넷 끊김과 같은 효과)
    response = api.post("/thinq/command", json={"appliance_id": "air_purifier",
                                                "action": "set_wind_strength",
                                                "args": {"wind_strength": "HIGH"}})
    if response.status_code == 412:  # 준비 판정에서 먼저 걸려도 정직한 결과다
        assert "연결" in response.text
        return
    assert response.status_code == 200, response.text
    status = _wait_done(api, response.json()["job_id"], timeout=20)
    assert (status["last_status"], status["last_receipt"]) == ("failed", "not_dispatched")
    assert "연결" in status["last_detail"]


def test_accepted_but_state_never_changes_is_unconfirmed(api, cloud):
    cloud.set_fault("freeze_state", device_id=cloud.device_id("air_purifier"))
    status = _command(api, "air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})
    assert (status["last_status"], status["last_receipt"], status["last_confirmation"]) == (
        "unconfirmed", "accepted", "none")
    assert len(cloud.controls()) == 1


# ── real 모드 코드 경로의 표시 ─────────────────────────────────────────────


def test_real_mode_code_path_records_real(monkeypatch, tmp_path):
    """real 모드는 결과를 ``real``로 적는다. **실제 클라우드가 아니다** -- 시험 안에서만 SDK
    생성자에 모의 클라우드 주소를 끼워 real 조립 경로(PAT·클라이언트 ID 파일·REAL 선언)를 돈다."""
    from rpi.services.thinq import sdk_client

    fake = FakeThinqCloud(token=SECRET_PAT)
    fake.start()
    original = sdk_client.SdkThinqClient.__init__

    def redirected(self, **kw):
        assert kw.get("base_url") is None  # real 조립은 주소를 바꾸지 않는다
        kw["base_url"] = fake.base_url
        original(self, **kw)

    monkeypatch.setattr(sdk_client.SdkThinqClient, "__init__", redirected)
    try:
        _env(monkeypatch, tmp_path, fake, mode="real")
        _reset()
        from rpi.main import app

        api = TestClient(app)
        status = _command(api, "air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})
        assert status["last_execution_mode"] == "real"
        assert status["last_confirmation"] == "state_confirmed"
        names = {a["appliance_id"]: a["name"] for a in api.get("/thinq/devices").json()["appliances"]}
        assert names["air_purifier"] == "공기청정기"  # '(모의…)' 표시 없음
        assert all(r["token_ok"] for r in fake.requests())
        assert (tmp_path / "thinq_client_id").exists()
        _no_secret(api, status)
        assert deps.get_service().thinq_controller.execution_mode.value == "real"
    finally:
        fake.stop()
        _reset()
