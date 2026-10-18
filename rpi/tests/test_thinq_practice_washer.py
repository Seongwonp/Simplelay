"""연습용 LG 세탁기 — LG 가전 실제 모드에서도 모의 세탁기 한 대를 함께 보인다 (2026-10-18, 사용자 요청).

``SIMPLELAY_THINQ_PRACTICE_DEVICES=washer``면 실제(real) 모드에서도 모의 세탁기 한 대를 기기 목록에 더한다. 이 기기의
실행·상태는 **전부 모의**이고 실행 결과·기록·상태 조회가 ``execution_mode: mock``(화면 '연습')으로 나온다. 실제 공기청정기
경로(실행 환경 real·클라우드 호출)와 서버 전체 실행 환경(자동 실행 규칙·공기질 판정이 보는 값)은 그대로다.
env가 없으면 지금과 같다(실제 기기만).

실제 클라우드는 부르지 않는다 — real 조립 경로를 돌리려고 시험 안에서만 공식 SDK 생성자에 저장소 안 모의 클라우드
주소를 끼운다(``test_thinq_sdk_e2e.test_real_mode_code_path_records_real``과 같은 방법).
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.tests.test_thinq_u1 import _reset, _wait_done

pytest.importorskip("thinqconnect")

from rpi.tools.fake_thinq_cloud import FakeThinqCloud  # noqa: E402

SECRET_PAT = "pat-SECRET-practice-do-not-log-7d21"
WASHER = "thinq_washer"


@pytest.fixture()
def real_cloud(monkeypatch, tmp_path):
    from rpi.services.thinq import sdk_client

    fake = FakeThinqCloud(token=SECRET_PAT)
    fake.start()
    original = sdk_client.SdkThinqClient.__init__

    def redirected(self, **kw):
        assert kw.get("base_url") is None  # real 조립은 주소를 바꾸지 않는다
        kw["base_url"] = fake.base_url
        original(self, **kw)

    monkeypatch.setattr(sdk_client.SdkThinqClient, "__init__", redirected)
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "real")
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "2")
    # 보드와 같은 꼴 — 실제 공기청정기 하나만 환경 변수로.
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", fake.device_id("air_purifier"))
    for key in ("SIMPLELAY_THINQ_DEVICE_WASHER", "SIMPLELAY_THINQ_DEVICE_DEHUMIDIFIER", "SIMPLELAY_DB_PATH",
                "SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE", "SIMPLELAY_THINQ_PRACTICE_DEVICES", "SIMPLELAY_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    try:
        yield fake
    finally:
        fake.stop()
        _reset()


def _api():
    _reset()
    from rpi.main import app

    return TestClient(app)


def _command(api, appliance_id, action, args):
    response = api.post("/thinq/command", json={"appliance_id": appliance_id, "action": action, "args": args})
    assert response.status_code == 200, response.text
    return _wait_done(api, response.json()["job_id"], timeout=10)


def test_default_has_no_practice_washer(real_cloud):
    api = _api()
    ids = {a["id"] for a in api.get("/appliances").json()}
    assert "air_purifier" in ids and WASHER not in ids
    names = {a["appliance_id"] for a in api.get("/thinq/devices").json()["appliances"]}
    assert names == {"air_purifier"}


def test_practice_washer_listed_as_lg_washer_practice(real_cloud, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_PRACTICE_DEVICES", "washer")
    api = _api()
    items = {a["id"]: a for a in api.get("/appliances").json()}
    washer = items[WASHER]
    assert washer["name"] == "LG 세탁기(연습)"
    assert washer["category"] == "washing_machine"
    assert washer["control_path"] == "thinq"
    assert (washer["readiness"], washer["can_execute"]) == ("operable", True), washer
    # 실제 공기청정기는 그대로(이름에 연습 표시 없음).
    assert items["air_purifier"]["name"] == "공기청정기"

    devices = api.get("/thinq/devices").json()
    assert devices["execution_mode"] == "real"  # 서버 전체 실행 환경은 그대로
    by_id = {a["appliance_id"]: a for a in devices["appliances"]}
    assert by_id[WASHER]["execution_mode"] == "mock"
    assert by_id["air_purifier"]["execution_mode"] == "real"
    # 계정 기기 목록(실제 클라우드)에는 연습 기기를 섞지 않는다.
    from rpi.services.thinq import MOCK_WASHER_ID
    from rpi.services.thinq.discovery import device_key

    assert device_key(MOCK_WASHER_ID) not in {d["key"] for d in devices["devices"]}
    assert deps.get_service().thinq_controller.execution_mode.value == "real"


def test_practice_washer_run_is_mock_everywhere_and_never_reaches_cloud(real_cloud, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_PRACTICE_DEVICES", "washer")
    api = _api()
    status = _command(api, WASHER, "set_operation", {"operation": "START"})
    assert status["last_route"] == "thinq"
    assert status["last_status"] == "succeeded"
    assert status["last_execution_mode"] == "mock"
    assert real_cloud.controls() == []  # 실제 클라우드로 간 제어 없음
    history = api.get("/history").json()[0]
    assert history["execution_mode"] == "mock"
    seen = api.get(f"/thinq/status/{WASHER}").json()
    assert seen["execution_mode"] == "mock"
    assert seen["state"]["runState"]["currentState"] == "RUNNING"

    # 같은 서버에서 실제 공기청정기는 실제로 간다.
    real = _command(api, "air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})
    assert real["last_execution_mode"] == "real"
    assert len(real_cloud.controls()) == 1
    assert api.get("/thinq/status/air_purifier").json()["execution_mode"] == "real"


def test_practice_washer_does_not_take_a_real_washer_slot(real_cloud, monkeypatch):
    # 실제 세탁기를 환경 변수로 준 설치에서는 연습 세탁기를 더하지 않는다(자리 하나 — 실제가 먼저).
    monkeypatch.setenv("SIMPLELAY_THINQ_PRACTICE_DEVICES", "washer")
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_WASHER", real_cloud.device_id("washer"))
    api = _api()
    items = {a["id"]: a for a in api.get("/appliances").json()}
    assert items[WASHER]["name"] == "세탁기"
    by_id = {a["appliance_id"]: a for a in api.get("/thinq/devices").json()["appliances"]}
    assert by_id[WASHER]["execution_mode"] == "real"


def test_unknown_practice_value_is_ignored(real_cloud, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_PRACTICE_DEVICES", "rocket")
    api = _api()
    assert WASHER not in {a["id"] for a in api.get("/appliances").json()}
