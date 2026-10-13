"""ThinQ 계정 가전 발견 → 사용자 확인 후 추가 (2026-10-13).

- 발견(GET /thinq/discovered)은 아무것도 등록하지 않는다. 종류·별칭·지원 여부·추가 여부를 준다.
- 추가(POST /thinq/added)는 사용자가 누를 때만. 추가한 기기만 기존 ThinQ 경로(준비 판정·승인·제어·
  확인·기록)에 들어가고, 서버 DB에 남아 재시작 뒤에도 돌아온다. 제거(DELETE)도 남는다.
- 환경 변수로 넣은 기기와 겹치지 않는다(종류마다 가전 ID 자리 하나).
- 목록 조회 실패(토큰 오류·연결 끊김)는 '0대'가 아니라 사람 말 이유로 낸다.
- 기기 ID 원문은 API 응답·로그에 나오지 않는다(``key``만).

모의 클라우드(127.0.0.1)만 쓴다. **실제 ThinQ 클라우드·실가전은 부르지 않는다.**
"""

from __future__ import annotations

import logging

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.services.thinq.discovery import (
    CONTROLLABLE,
    STATUS_ONLY,
    UNSUPPORTED,
    AddedDevice,
    ThinqAddedStore,
    classify,
    device_key,
)
from rpi.services.thinq.profiles_sample import (
    air_purifier_profile,
    air_purifier_state,
    dehumidifier_profile,
    washer_profile,
)
from rpi.tests.test_thinq_u1 import _reset, _wait_done

SECRET_PAT = "pat-SECRET-discovery-do-not-log-7d21"


# ── 지원 판정(SDK 없이) ───────────────────────────────────────────────────


def _read_only(profile: dict) -> dict:
    for section in profile["property"].values():
        for spec in section.values():
            if isinstance(spec, dict):
                spec["mode"] = ["r"]
                spec.get("value", {}).pop("w", None)
    return profile


def test_classify_by_profile():
    full = classify("DEVICE_AIR_PURIFIER", air_purifier_profile())
    assert full.support == CONTROLLABLE
    assert full.actions == ("전원", "풍량", "운전 모드")
    assert "제어할 수 있어요" in full.reason

    narrow = classify("DEVICE_AIR_PURIFIER", air_purifier_profile(job_modes_w=(), wind_w=()))
    assert narrow.support == CONTROLLABLE and narrow.actions == ("전원",)

    status_only = classify("DEVICE_AIR_PURIFIER", _read_only(air_purifier_profile()))
    assert status_only.support == STATUS_ONLY
    assert "상태만" in status_only.reason

    assert classify("DEVICE_WASHER", washer_profile()).actions == ("운전",)
    assert classify("DEVICE_DEHUMIDIFIER", dehumidifier_profile()).actions == ("전원",)

    empty = classify("DEVICE_AIR_PURIFIER", {"property": {}})
    assert empty.support == UNSUPPORTED and "속성" in empty.reason
    fridge = classify("DEVICE_REFRIGERATOR", {"property": {}})
    assert fridge.support == UNSUPPORTED and "종류" in fridge.reason


def test_added_store_round_trip_and_corrupt_record():
    saved: dict[str, str] = {}
    store = ThinqAddedStore(load=lambda: saved.get("v"), save=lambda v: saved.__setitem__("v", v))
    store.add(AddedDevice("dev-1", "DEVICE_AIR_PURIFIER", "거실", "M"))
    again = ThinqAddedStore(load=lambda: saved.get("v"))
    assert again.contains("dev-1")
    assert again.by_key(device_key("dev-1")).alias == "거실"
    assert store.remove("dev-1") is True
    assert ThinqAddedStore(load=lambda: saved.get("v")).entries() == ()
    assert ThinqAddedStore(load=lambda: "{not json").entries() == ()


# ── mock 모드: 서버 구성 가전은 '추가됨(서버 설정)' ─────────────────────────


@pytest.fixture()
def mock_api(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "mock")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def test_mock_mode_lists_configured_devices_as_added(mock_api):
    body = mock_api.get("/thinq/discovered").json()
    assert body["reachable"] is True and body["mode"] == "mock"
    rows = {r["kind"]: r for r in body["devices"]}
    assert rows["air_purifier"]["added"] is True and rows["air_purifier"]["source"] == "config"
    assert rows["air_purifier"]["appliance_id"] == "air_purifier"
    removed = mock_api.delete(f"/thinq/added/{rows['air_purifier']['key']}")
    assert removed.status_code == 409 and "환경 변수" in removed.json()["detail"]


def test_discovery_is_404_when_thinq_is_off(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "off")
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    _reset()
    try:
        from rpi.main import app

        api = TestClient(app)
        assert api.get("/thinq/discovered").status_code == 404
        assert api.post("/thinq/added", json={"key": "x"}).status_code == 404
    finally:
        _reset()


# ── fake_cloud: 공식 SDK → 모의 클라우드 (SDK가 없으면 이 아래는 건너뛴다) ─────

from rpi.tools.fake_thinq_cloud import FakeThinqCloud, default_devices  # noqa: E402


def _need_sdk():
    pytest.importorskip("thinqconnect")


def _env(monkeypatch, tmp_path, cloud, *, db: bool = False, env_devices: tuple[str, ...] = ()):
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", "fake_cloud")
    monkeypatch.setenv("SIMPLELAY_THINQ_FAKE_CLOUD_URL", cloud.base_url)
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "2")
    monkeypatch.setenv("SIMPLELAY_V2_SCENARIOS", "1")
    monkeypatch.delenv("SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE", raising=False)
    for kind in ("AIR_PURIFIER", "WASHER", "DEHUMIDIFIER"):
        monkeypatch.delenv(f"SIMPLELAY_THINQ_DEVICE_{kind}", raising=False)
    for kind in env_devices:
        monkeypatch.setenv(f"SIMPLELAY_THINQ_DEVICE_{kind.upper()}", cloud.device_id(kind))
    if db:
        monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    else:
        monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)


def _restart():
    """서버 재시작과 같게: 싱글턴·DB 연결을 모두 버리고 앱을 다시 조립한다."""
    _reset()
    deps.get_db.cache_clear()
    from rpi.main import app

    return TestClient(app)


@pytest.fixture()
def cloud():
    _need_sdk()
    fake = FakeThinqCloud()
    fake.start()
    yield fake
    fake.stop()


@pytest.fixture()
def api(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud)
    yield _restart()
    _reset()
    deps.get_db.cache_clear()


def _rows(api) -> dict[str, dict]:
    body = api.get("/thinq/discovered").json()
    assert body["reachable"] is True, body
    return {r["kind"]: r for r in body["devices"]}


def _appliance_ids(api) -> set[str]:
    return {a["id"] for a in api.get("/appliances").json()}


def _add(api, kind: str) -> dict:
    response = api.post("/thinq/added", json={"key": _rows(api)[kind]["key"]})
    assert response.status_code == 200, response.text
    return response.json()


def test_discovered_lists_account_devices_without_registering(api, cloud):
    body = api.get("/thinq/discovered").json()
    assert (body["mode"], body["execution_mode"], body["mock_cloud"]) == ("fake_cloud", "mock", True)
    rows = {r["kind"]: r for r in body["devices"]}
    assert set(rows) == {"air_purifier", "dehumidifier", "washer"}
    purifier = rows["air_purifier"]
    assert purifier["kind_label"] == "공기청정기"
    assert purifier["alias"] == "공기청정기(모의 클라우드)"
    assert purifier["support"] == "controllable"
    assert purifier["actions"] == ["전원", "풍량", "운전 모드"]
    assert purifier["added"] is False and purifier["can_add"] is True and purifier["reason"] is None
    assert rows["washer"]["support"] == "controllable" and rows["washer"]["actions"] == ["운전"]
    # 발견만으로는 아무것도 등록하지 않는다.
    assert "air_purifier" not in _appliance_ids(api)
    assert api.get("/thinq/devices").json()["appliances"] == []
    # 기기 ID 원문은 응답에 없다.
    raw = api.get("/thinq/discovered").text
    assert all(device_id not in raw for device_id in default_devices())
    assert cloud.controls() == []


def test_device_not_added_is_refused_before_anything_is_sent(api, cloud):
    response = api.post("/thinq/command", json={"appliance_id": "air_purifier",
                                                "action": "set_wind_strength",
                                                "args": {"wind_strength": "HIGH"}})
    assert response.status_code != 200
    assert api.get("/readiness/air_purifier").status_code == 404
    assert cloud.controls() == []


def test_add_registers_once_and_shows_in_appliances(api):
    added = _add(api, "air_purifier")
    assert added == {"appliance_id": "air_purifier", "name": "공기청정기(모의 클라우드)",
                     "added": True, "source": "added"}
    listing = {a["id"]: a for a in api.get("/appliances").json()}
    assert listing["air_purifier"]["control_path"] == "thinq"
    assert listing["air_purifier"]["name"] == "공기청정기(모의 클라우드)"
    row = _rows(api)["air_purifier"]
    assert (row["added"], row["source"], row["can_add"]) == (True, "added", False)
    # 두 번 눌러도 한 대다.
    again = api.post("/thinq/added", json={"key": row["key"]})
    assert again.status_code == 200 and again.json()["appliance_id"] == "air_purifier"
    assert [a["appliance_id"] for a in api.get("/thinq/devices").json()["appliances"]] == ["air_purifier"]
    # 추가한 가전도 준비 판정을 그대로 거친다.
    readiness = api.get("/readiness/air_purifier").json()
    assert readiness["route"] == "thinq" and readiness["can_execute"] is True


def test_discover_add_approve_control_confirm_end_to_end(api, cloud):
    """발견 → 추가 → 승인 카드 → SDK 제어 → 상태 재조회 확인 → 기록."""
    _add(api, "air_purifier")
    assert cloud.controls() == []  # 추가는 실행이 아니다

    job = api.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert _wait_done(api, job.json()["job_id"])["last_status"] == "succeeded"
    assert cloud.controls() == []  # 승인 없는 자동 실행 없음
    cards = [s for s in api.get("/suggestions").json() if s.get("scenario_id") == "cook_then_air"]
    assert len(cards) == 1
    assert cards[0]["commands"][0]["summary"] == "공기청정기(모의 클라우드) 풍량 강"

    approved = api.post(f"/suggestions/{cards[0]['id']}/approve")
    assert approved.status_code == 200, approved.text
    status = _wait_done(api, approved.json()["job_id"], timeout=10)
    assert (status["last_route"], status["last_status"], status["last_confirmation"]) == (
        "thinq", "succeeded", "state_confirmed")
    assert status["last_execution_mode"] == "mock"
    device = cloud.device_id("air_purifier")
    assert [c["body"] for c in cloud.controls()] == [{"airFlow": {"windStrength": "HIGH"}}]
    assert cloud.state(device)["airFlow"]["windStrength"] == "HIGH"
    history = api.get("/history").json()[0]
    assert (history["route"], history["receipt"], history["confirmation"]) == (
        "thinq", "accepted", "state_confirmed")
    texts = [api.get("/history").text, api.get("/status").text, api.get("/thinq/discovered").text]
    assert all(SECRET_PAT not in t and device not in t for t in texts)


def test_added_and_removed_devices_persist_across_restart(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud, db=True)
    try:
        api = _restart()
        _add(api, "air_purifier")
        api = _restart()
        assert "air_purifier" in _appliance_ids(api)
        row = _rows(api)["air_purifier"]
        assert (row["added"], row["source"]) == (True, "added")
        assert api.get("/readiness/air_purifier").json()["can_execute"] is True

        removed = api.delete(f"/thinq/added/{row['key']}")
        assert removed.status_code == 200 and removed.json()["appliance_id"] == "air_purifier"
        assert "air_purifier" not in _appliance_ids(api)
        api = _restart()
        assert "air_purifier" not in _appliance_ids(api)
        assert _rows(api)["air_purifier"]["added"] is False
        # 기기 ID는 서버 DB에만 -- 다른 모드의 기록과 섞이지 않게 모드별 칸이다.
        assert deps.get_db().load_setting("thinq_added_devices:real") is None
    finally:
        _reset()
        deps.get_db.cache_clear()


def test_env_configured_device_and_added_device_never_duplicate(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud, db=True)
    try:
        api = _restart()
        _add(api, "air_purifier")  # 먼저 추가해 두고
        _env(monkeypatch, tmp_path, cloud, db=True, env_devices=("air_purifier",))
        api = _restart()  # 같은 기기를 환경 변수로도 넣은 뒤 재시작
        thinq = [a for a in api.get("/appliances").json() if a.get("control_path") == "thinq"]
        assert [a["id"] for a in thinq] == ["air_purifier"]
        row = _rows(api)["air_purifier"]
        assert row["added"] is True
        again = api.post("/thinq/added", json={"key": row["key"]})
        assert again.status_code == 200
        assert len([a for a in api.get("/appliances").json() if a["id"] == "air_purifier"]) == 1
    finally:
        _reset()
        deps.get_db.cache_clear()


def test_env_only_device_cannot_be_removed_here(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud, env_devices=("air_purifier",))
    try:
        api = _restart()
        row = _rows(api)["air_purifier"]
        assert (row["added"], row["source"]) == (True, "config")
        response = api.delete(f"/thinq/added/{row['key']}")
        assert response.status_code == 409 and "환경 변수" in response.json()["detail"]
        assert "air_purifier" in _appliance_ids(api)
    finally:
        _reset()


def test_second_device_of_same_kind_is_not_addable(monkeypatch, tmp_path):
    _need_sdk()
    devices = default_devices()
    devices["fake-ap-0002"] = {**devices["fake-ap-0001"], "alias": "안방 공기청정기",
                               "profile": air_purifier_profile(), "state": air_purifier_state()}
    fake = FakeThinqCloud(devices=devices)
    fake.start()
    try:
        _env(monkeypatch, tmp_path, fake)
        api = _restart()
        body = api.get("/thinq/discovered").json()["devices"]
        first = next(r for r in body if r["alias"] == "공기청정기(모의 클라우드)")
        second = next(r for r in body if r["alias"] == "안방 공기청정기")
        assert api.post("/thinq/added", json={"key": first["key"]}).status_code == 200
        second = next(r for r in api.get("/thinq/discovered").json()["devices"]
                      if r["key"] == second["key"])
        assert second["can_add"] is False and "한 대만" in second["reason"]
        refused = api.post("/thinq/added", json={"key": second["key"]})
        assert refused.status_code == 409 and "한 대만" in refused.json()["detail"]
    finally:
        fake.stop()
        _reset()


def test_status_only_and_unsupported_devices_show_reason_and_cannot_be_added(monkeypatch, tmp_path):
    _need_sdk()
    devices = default_devices()
    devices["fake-ap-0001"]["profile"] = _read_only(air_purifier_profile())
    devices["fake-rf-0001"] = {"kind": "fridge", "type": "DEVICE_REFRIGERATOR", "model": "FAKE-RF",
                               "alias": "냉장고", "profile": {"property": {}}, "state": {}}
    fake = FakeThinqCloud(devices=devices)
    fake.start()
    try:
        _env(monkeypatch, tmp_path, fake)
        api = _restart()
        rows = {r["kind_label"]: r for r in api.get("/thinq/discovered").json()["devices"]}
        purifier, fridge = rows["공기청정기"], rows["냉장고"]
        assert purifier["support"] == "status_only" and purifier["can_add"] is False
        assert "상태만" in purifier["reason"]
        assert fridge["support"] == "unsupported" and fridge["kind"] is None
        assert "종류" in fridge["reason"]
        for row in (purifier, fridge):
            refused = api.post("/thinq/added", json={"key": row["key"]})
            assert refused.status_code == 409 and "추가하지 않았어요" in refused.json()["detail"]
        assert "air_purifier" not in _appliance_ids(api)
    finally:
        fake.stop()
        _reset()


def test_token_error_is_a_reason_not_zero_devices(api, cloud):
    cloud.set_fault("invalid_token")
    body = api.get("/thinq/discovered").json()
    assert body["reachable"] is False and body["devices"] == []
    assert "PAT" in body["error"]
    refused = api.post("/thinq/added", json={"key": device_key(cloud.device_id("air_purifier"))})
    assert refused.status_code == 503 and "PAT" in refused.json()["detail"]
    assert SECRET_PAT not in str(body) and SECRET_PAT not in refused.text


def test_cloud_unreachable_is_a_reason_not_zero_devices(api, cloud):
    cloud.stop()
    body = api.get("/thinq/discovered").json()
    assert body["reachable"] is False and body["devices"] == []
    assert body["error"] and "연결" in body["error"]


def test_removed_device_is_refused_again(api, cloud):
    _add(api, "air_purifier")
    key = _rows(api)["air_purifier"]["key"]
    assert api.delete(f"/thinq/added/{key}").status_code == 200
    assert api.delete(f"/thinq/added/{key}").status_code == 404
    response = api.post("/thinq/command", json={"appliance_id": "air_purifier",
                                                "action": "set_power", "args": {"power": "POWER_ON"}})
    assert response.status_code != 200
    assert cloud.controls() == []


def test_device_ids_never_reach_logs(api, cloud, caplog):
    caplog.set_level(logging.DEBUG)
    _add(api, "air_purifier")
    key = _rows(api)["air_purifier"]["key"]
    api.delete(f"/thinq/added/{key}")
    assert all(device_id not in caplog.text for device_id in default_devices())
    assert SECRET_PAT not in caplog.text


def test_added_device_reaches_kiosk_in_the_same_shape_as_env_device(monkeypatch, tmp_path, cloud):
    """키오스크는 바꾸지 않는다 -- 추가한 가전의 GET /appliances 항목이 환경 변수로 넣은 가전과
    같은 모양(같은 키·경로·준비 판정)이어야 기존 키오스크 표시가 그대로 받는다."""
    _env(monkeypatch, tmp_path, cloud, env_devices=("air_purifier",))
    try:
        api = _restart()
        from_env = next(a for a in api.get("/appliances").json() if a["id"] == "air_purifier")
        _env(monkeypatch, tmp_path, cloud)
        api = _restart()
        _add(api, "air_purifier")
        added = next(a for a in api.get("/appliances").json() if a["id"] == "air_purifier")
        assert added == from_env
        assert added["control_path"] == "thinq" and added["is_custom"] is False
    finally:
        _reset()
