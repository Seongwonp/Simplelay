"""공식 SDK 클라이언트 → 모의 ThinQ 클라우드 (2026-10-13, 단계 2).

``SdkThinqClient``는 공식 SDK(``thinqconnect`` 1.0.14)의 ``ThinQApi``를 **실제로** 부른다.
SDK는 접속 주소를 ``https://api-<지역>.lgthinq.com/``로 고정하므로(기준 주소 설정 없음),
모의 클라우드 모드에서는 SDK에 넘기는 aiohttp 세션 자리에서 주소만 저장소 안
``rpi/tools/fake_thinq_cloud.py``(127.0.0.1)로 바꾼다. 경로·헤더·본문은 SDK가 만든 그대로다.

**실제 ThinQ 클라우드·실가전에는 한 번도 닿지 않는다.** SDK가 없으면 SDK가 필요한 시험만
건너뛴다(설정·기동 거절 시험은 SDK 없이 돈다).
"""

from __future__ import annotations

import logging
import sys
import uuid
from pathlib import Path

import pytest

from rpi.controller.models import ExecutionMode
from rpi.services.thinq.client import (
    ThinqCommandRejected,
    ThinqOfflineError,
    ThinqRateLimited,
    ThinqTransportError,
)
from rpi.services.thinq.config import (
    ThinqConfig,
    ThinqMode,
    load_access_token,
    load_or_create_client_id,
)
from rpi.services.thinq.profiles_sample import air_purifier_profile

TOKEN = "pat-SECRET-fake-cloud-77ab"
REPO = Path(__file__).resolve().parents[2]


@pytest.fixture()
def sdk():
    return pytest.importorskip("thinqconnect")


@pytest.fixture()
def cloud():
    from rpi.tools.fake_thinq_cloud import FakeThinqCloud

    fake = FakeThinqCloud(token=TOKEN)
    fake.start()
    yield fake
    fake.stop()


def _client(cloud, **kw):
    from rpi.services.thinq.sdk_client import SdkThinqClient

    client = SdkThinqClient(access_token=TOKEN, country="KR", client_id=str(uuid.uuid4()),
                            execution_mode=ExecutionMode.MOCK, base_url=cloud.base_url, **kw)
    return client


@pytest.fixture()
def client(sdk, cloud):
    c = _client(cloud)
    yield c
    c.close()


# ── SDK가 실제로 만든 요청 ────────────────────────────────────────────────


def test_reads_go_through_sdk_paths_and_headers(client, cloud):
    devices = client.list_devices()
    assert {d.device_type for d in devices} == {
        "DEVICE_AIR_PURIFIER", "DEVICE_DEHUMIDIFIER", "DEVICE_WASHER"}
    purifier = next(d for d in devices if d.device_type == "DEVICE_AIR_PURIFIER")
    assert purifier.alias.endswith("(모의 클라우드)")
    assert client.get_profile(purifier.device_id) == air_purifier_profile()
    state = client.get_status(purifier.device_id)
    assert state["airFlow"]["windStrength"] == "LOW"

    paths = [(r["method"], r["path"]) for r in cloud.requests()]
    assert paths == [("GET", "/devices"),
                     ("GET", f"/devices/{purifier.device_id}/profile"),
                     ("GET", f"/devices/{purifier.device_id}/state")]
    first = cloud.requests()[0]
    # SDK ThinQApi._generate_headers가 붙이는 머리글 -- 이름만 기록한다(값은 비밀일 수 있다).
    for name in ("authorization", "x-country", "x-message-id", "x-client-id", "x-api-key",
                 "x-service-phase"):
        assert name in first["header_names"], name
    assert first["token_ok"] is True and first["auth_scheme"] == "Bearer"
    assert first["client_id_is_uuid"] is True
    assert first["public_headers"]["x-country"] == "KR"
    assert first["public_headers"]["x-service-phase"] == "OP"
    assert TOKEN not in repr(cloud.requests())


def test_control_body_and_conditional_header(client, cloud):
    device_id = cloud.device_id("air_purifier")
    payload = {"airFlow": {"windStrength": "HIGH"}}
    client.post_control(device_id, payload)
    control = cloud.requests()[-1]
    assert (control["method"], control["path"]) == ("POST", f"/devices/{device_id}/control")
    assert control["body"] == payload
    assert control["public_headers"]["x-conditional-control"] == "true"
    assert client.get_status(device_id)["airFlow"]["windStrength"] == "HIGH"


def test_profile_is_cached_per_device(client, cloud):
    device_id = cloud.device_id("air_purifier")
    client.get_profile(device_id)
    client.get_profile(device_id)
    assert [r["path"] for r in cloud.requests()].count(f"/devices/{device_id}/profile") == 1


# ── 오류 → 사람 말 이유, 토큰 비노출 ───────────────────────────────────────


@pytest.mark.parametrize("fault, name, kind", [
    ("invalid_token", "INVALID_TOKEN", ThinqCommandRejected),
    ("terms", "NOT_ACCEPTABLE_TERMS", ThinqCommandRejected),
    ("not_allowed", "NOT_ALLOWED_API_AGAIN", ThinqCommandRejected),
    ("country", "NOT_SUPPORTED_COUNTRY", ThinqCommandRejected),
    ("rate_limit", "EXCEEDED_API_CALLS", ThinqCommandRejected),
    ("internal_error", "INTERNAL_SERVER_ERROR", ThinqTransportError),
])
def test_cloud_errors_become_human_reasons_without_token(client, cloud, caplog, fault, name, kind):
    caplog.set_level(logging.DEBUG)
    cloud.set_fault(fault)
    with pytest.raises(kind) as info:
        client.list_devices()
    err = info.value
    assert err.name == name
    assert err.reason and name not in err.reason
    # SDK 예외는 요청 머리글(Authorization)을 속성으로 든다 -- 우리 오류에 연결되면 안 된다.
    assert err.__cause__ is None and err.__context__ is None
    for text in (str(err), repr(err), repr(err.args), err.reason, caplog.text):
        assert TOKEN not in text


def test_wrong_token_is_invalid_token(sdk, cloud):
    from rpi.services.thinq.sdk_client import SdkThinqClient

    c = SdkThinqClient(access_token="other-token", country="KR", client_id=str(uuid.uuid4()),
                       execution_mode=ExecutionMode.MOCK, base_url=cloud.base_url)
    try:
        with pytest.raises(ThinqCommandRejected) as info:
            c.list_devices()
        assert info.value.name == "INVALID_TOKEN"
        assert cloud.requests()[0]["token_ok"] is False
    finally:
        c.close()


def test_offline_device_is_offline_error(client, cloud):
    device_id = cloud.device_id("air_purifier")
    cloud.set_fault("offline", device_id=device_id)
    with pytest.raises(ThinqOfflineError) as info:
        client.get_status(device_id)
    assert info.value.name == "NOT_CONNECTED_DEVICE"


def test_lost_control_response_is_transport_error_but_state_changed(client, cloud):
    """응답 유실: 클라우드는 받아 상태를 바꿨는데 우리는 응답을 못 받았다 -- 보냈는지 모름."""
    device_id = cloud.device_id("air_purifier")
    cloud.set_fault("drop_control_response", device_id=device_id)
    with pytest.raises(ThinqTransportError):
        client.post_control(device_id, {"airFlow": {"windStrength": "HIGH"}})
    assert cloud.state(device_id)["airFlow"]["windStrength"] == "HIGH"


def test_client_side_call_limit_stops_before_sending(sdk, cloud):
    c = _client(cloud, max_calls_per_minute=3)
    try:
        for _ in range(3):
            c.get_status(cloud.device_id("air_purifier"))
        with pytest.raises(ThinqRateLimited) as info:
            c.post_control(cloud.device_id("air_purifier"), {"airFlow": {"windStrength": "HIGH"}})
        assert "상한" in info.value.reason
        assert len(cloud.requests()) == 3  # 넷째는 보내지 않았다
    finally:
        c.close()


def test_unreachable_cloud_is_offline_not_unknown(sdk):
    from rpi.services.thinq.sdk_client import SdkThinqClient

    c = SdkThinqClient(access_token=TOKEN, country="KR", client_id=str(uuid.uuid4()),
                       execution_mode=ExecutionMode.MOCK, base_url="http://127.0.0.1:9")
    try:
        with pytest.raises(ThinqOfflineError):
            c.list_devices()
        with pytest.raises(ThinqOfflineError):
            c.post_control("x", {"airFlow": {"windStrength": "HIGH"}})
    finally:
        c.close()


def test_client_never_shows_token(client):
    assert TOKEN not in repr(client) and TOKEN not in str(vars(client))


def test_redirect_only_to_loopback(sdk):
    from rpi.services.thinq.sdk_client import SdkThinqClient

    with pytest.raises(ValueError):
        SdkThinqClient(access_token=TOKEN, country="KR", client_id=str(uuid.uuid4()),
                       execution_mode=ExecutionMode.MOCK, base_url="http://example.com:8080")


def test_missing_sdk_is_refused_with_install_hint(monkeypatch):
    from rpi.services.thinq.sdk_client import SdkThinqClient, ThinqSdkMissing

    monkeypatch.setitem(sys.modules, "thinqconnect", None)
    with pytest.raises(ThinqSdkMissing, match=r"\.\[thinq\]"):
        SdkThinqClient(access_token=TOKEN, country="KR", client_id=str(uuid.uuid4()),
                       execution_mode=ExecutionMode.REAL)


# ── 설정: 비밀은 환경 변수·저장소 밖 파일에서만 ─────────────────────────────


def test_modes_and_fake_cloud_url_is_loopback_only():
    cfg = ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "fake_cloud",
                                "SIMPLELAY_THINQ_FAKE_CLOUD_URL": "http://127.0.0.1:8790"})
    assert cfg.mode is ThinqMode.FAKE_CLOUD and cfg.fake_cloud_url == "http://127.0.0.1:8790"
    with pytest.raises(RuntimeError, match="FAKE_CLOUD_URL"):
        ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "fake_cloud"})
    with pytest.raises(RuntimeError, match="127.0.0.1"):
        ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "fake_cloud",
                              "SIMPLELAY_THINQ_FAKE_CLOUD_URL": "http://10.0.0.5:8790"})
    # real 모드는 주소를 바꿀 수 없다 -- 실제 클라우드 판정이 모의와 섞이지 않게.
    with pytest.raises(RuntimeError, match="real"):
        ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "real",
                              "SIMPLELAY_THINQ_FAKE_CLOUD_URL": "http://127.0.0.1:8790"})


def test_pat_from_env_or_file_outside_repo(tmp_path):
    pat_file = tmp_path / "thinq_pat"
    pat_file.write_text(TOKEN + "\n", encoding="utf-8")
    assert load_access_token({"SIMPLELAY_THINQ_PAT_FILE": str(pat_file)}) == TOKEN
    assert load_access_token({"SIMPLELAY_THINQ_PAT": TOKEN}) == TOKEN
    assert load_access_token({}) is None
    cfg = ThinqConfig.from_env({"SIMPLELAY_THINQ_MODE": "real", "SIMPLELAY_THINQ_PAT_FILE": str(pat_file)})
    assert cfg.has_pat and TOKEN not in repr(cfg)


def test_secret_files_inside_repo_are_refused():
    inside = REPO / "docs" / "thinq_pat"
    with pytest.raises(RuntimeError, match="저장소"):
        load_access_token({"SIMPLELAY_THINQ_PAT_FILE": str(inside)})
    with pytest.raises(RuntimeError, match="저장소"):
        load_or_create_client_id({"SIMPLELAY_THINQ_CLIENT_ID_FILE": str(REPO / "thinq_client_id")})


def test_client_id_is_created_once_and_reused(tmp_path):
    path = tmp_path / "sub" / "thinq_client_id"
    env = {"SIMPLELAY_THINQ_CLIENT_ID_FILE": str(path)}
    first = load_or_create_client_id(env)
    assert uuid.UUID(first).version == 4
    assert load_or_create_client_id(env) == first
    path.write_text("not-a-uuid", encoding="utf-8")
    with pytest.raises(RuntimeError, match="UUID"):
        load_or_create_client_id(env)
    fixed = str(uuid.uuid4())
    assert load_or_create_client_id({"SIMPLELAY_THINQ_CLIENT_ID": fixed}) == fixed


# ── 조립: 모드별 클라이언트와 기동 거절 ──────────────────────────────────────


@pytest.fixture()
def thinq_env(monkeypatch, tmp_path):
    from rpi.api.thinq_wiring import reset_thinq_caches

    for key in list(__import__("os").environ):
        if key.startswith("SIMPLELAY_THINQ_"):
            monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    reset_thinq_caches()
    yield monkeypatch
    reset_thinq_caches()


def test_real_mode_refuses_to_start_without_sdk(thinq_env):
    from rpi.api.thinq_wiring import get_thinq_client

    thinq_env.setenv("SIMPLELAY_THINQ_MODE", "real")
    thinq_env.setenv("SIMPLELAY_THINQ_PAT", TOKEN)
    thinq_env.setitem(sys.modules, "thinqconnect", None)
    with pytest.raises(RuntimeError, match=r"\.\[thinq\]"):
        get_thinq_client()


def test_real_mode_refuses_to_start_without_pat(sdk, thinq_env):
    from rpi.api.thinq_wiring import get_thinq_client

    thinq_env.setenv("SIMPLELAY_THINQ_MODE", "real")
    with pytest.raises(RuntimeError, match="PAT"):
        get_thinq_client()


def test_real_mode_builds_sdk_client_declared_real(sdk, thinq_env, tmp_path):
    from rpi.api.thinq_wiring import get_thinq_client
    from rpi.services.thinq.sdk_client import SdkThinqClient

    thinq_env.setenv("SIMPLELAY_THINQ_MODE", "real")
    thinq_env.setenv("SIMPLELAY_THINQ_PAT", TOKEN)
    client = get_thinq_client()
    assert isinstance(client, SdkThinqClient)
    assert client.execution_mode is ExecutionMode.REAL and client.redirected is False
    # 클라이언트 ID는 저장소 밖 파일에 한 번 만들어졌다.
    assert uuid.UUID((tmp_path / "thinq_client_id").read_text(encoding="utf-8").strip())


def test_fake_cloud_mode_is_mock_and_never_sends_the_pat(sdk, thinq_env):
    from rpi.api.thinq_wiring import get_thinq_client
    from rpi.tools.fake_thinq_cloud import FakeThinqCloud

    fake = FakeThinqCloud()  # 모의 클라우드 전용 토큰
    fake.start()
    try:
        thinq_env.setenv("SIMPLELAY_THINQ_MODE", "fake_cloud")
        thinq_env.setenv("SIMPLELAY_THINQ_FAKE_CLOUD_URL", fake.base_url)
        thinq_env.setenv("SIMPLELAY_THINQ_PAT", TOKEN)  # 있어도 모의 클라우드로는 보내지 않는다
        client = get_thinq_client()
        assert client.execution_mode is ExecutionMode.MOCK and client.redirected is True
        assert len(client.list_devices()) == 3
        assert fake.requests()[0]["token_ok"] is True
    finally:
        fake.stop()

def test_server_startup_is_refused_in_real_mode_without_sdk(thinq_env):
    """uvicorn 기동(lifespan)에서 거절한다 -- 첫 요청까지 기다리지 않는다."""
    from fastapi.testclient import TestClient

    from rpi.main import app

    thinq_env.setenv("SIMPLELAY_THINQ_MODE", "real")
    thinq_env.setenv("SIMPLELAY_THINQ_PAT", TOKEN)
    thinq_env.setitem(sys.modules, "thinqconnect", None)
    with pytest.raises(RuntimeError, match=r"\.\[thinq\]"):
        with TestClient(app):
            pass