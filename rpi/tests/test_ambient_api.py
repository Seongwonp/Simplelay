"""GET /ambient · GET /connections — 라우트 배선, 인증, 오프라인, 확인 필요 우선."""

import pathlib
from datetime import timezone

import pytest
from fastapi.testclient import TestClient

import rpi.api.ambient_router as ambient_router
import rpi.api.deps as deps
from rpi.main import app
from rpi.services.act_client import AlertEvent
from rpi.services.weather import WeatherConfig, WeatherService
from rpi.services.weather import kma

FIX = pathlib.Path(__file__).parent / "fixtures" / "kma"


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    for name in ("SIMPLELAY_WEATHER_MODE", "SIMPLELAY_KMA_SERVICE_KEY", "SIMPLELAY_L3_MODE", "SIMPLELAY_ACT_MODE"):
        monkeypatch.delenv(name, raising=False)
    caches = (
        ambient_router.get_weather_service,
        deps.get_service,
        deps.get_appliance_registry,
        deps.get_alert_store,
    )
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    app.dependency_overrides.clear()
    for dep in caches:
        dep.cache_clear()


def _use_weather(service):
    app.dependency_overrides[ambient_router.get_weather_service] = lambda: service


def test_ambient_weather_off_by_default(client):
    body = client.get("/ambient").json()
    assert body["weather_source"] == "none"
    assert body["hourly"] == [] and body["tip"] is None
    assert body["stale"] is False and body["fetched_at"] is None
    assert body["greeting"].endswith(("에요.", "세요.", "예요."))


def test_ambient_mock_mode_from_env(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_WEATHER_MODE", "mock")
    ambient_router.get_weather_service.cache_clear()
    body = client.get("/ambient").json()
    assert body["weather_source"] == "mock"
    assert len(body["hourly"]) == 4
    assert {s["icon"] for s in body["hourly"]} <= {"clear", "partly", "cloudy", "rain", "snow"}


def test_ambient_real_mode_offline_does_not_fail(client):
    def offline(*a, **k):
        raise kma.KmaError("network", None, "URLError")

    _use_weather(WeatherService(WeatherConfig(mode="real", service_key="K", nx=60, ny=127), fetch=offline))
    res = client.get("/ambient")
    assert res.status_code == 200
    assert res.json()["weather_source"] == "none"


def test_ambient_real_mode_with_fixture(client):
    def fixture_fetch(key, nx, ny, now, *, timeout):
        return kma.parse_response(
            200, (FIX / "vilage_fcst_ok.json").read_bytes(), source="kma",
            fetched_at=now.astimezone(timezone.utc),
        )

    _use_weather(WeatherService(WeatherConfig(mode="real", service_key="K", nx=60, ny=127), fetch=fixture_fetch))
    body = client.get("/ambient").json()
    assert body["weather_source"] == "kma" and body["fetched_at"]


def test_ambient_alert_takes_priority(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_WEATHER_MODE", "mock")
    ambient_router.get_weather_service.cache_clear()
    deps.get_alert_store().record(AlertEvent(kind="danger_sound", raised=True))
    body = client.get("/ambient").json()
    assert body["tip"] == {
        "kind": "alert",
        "text": "위험할 수 있는 소리가 들렸어요. 주변을 확인해 주세요.",
        "icon": "attention",
    }
    assert len(body["hourly"]) == 4


def test_ambient_failed_appliance_takes_priority(client, monkeypatch):
    from rpi.controller.models import ExecutionOutcome

    class Snap:
        running = False
        last_result = object()
        last_appliance_id = "microwave"

    class FakeService:
        def status(self):
            return Snap()

    monkeypatch.setattr(ambient_router, "outcome_of", lambda _r: ExecutionOutcome.SAFETY_STOP)
    app.dependency_overrides[deps.get_service] = lambda: FakeService()
    body = client.get("/ambient").json()
    assert body["tip"]["kind"] == "appliance"
    assert body["tip"]["text"] == "전자레인지 버튼 누르기가 중간에 멈췄어요. 가전을 봐 주세요."


@pytest.mark.parametrize("outcome_name", ["FAILED", "SAFETY_STOP"])
def test_ambient_unconfirmed_command_is_not_failure(client, monkeypatch, outcome_name):
    """보냈지만 확인 못 한 명령(unconfirmed)을 '끝까지 되지 않았다'로 말하지 않는다."""
    from rpi.controller.models import ExecutionOutcome

    class Snap:
        running = False
        last_result = object()
        last_appliance_id = "air"
        last_command_status = "unconfirmed"

    class FakeService:
        def status(self):
            return Snap()

    class Appliance:
        name = "공기청정기(모의)"

    class Registry:
        def get(self, _id):
            return Appliance()

    monkeypatch.setattr(ambient_router, "outcome_of", lambda _r: getattr(ExecutionOutcome, outcome_name))
    app.dependency_overrides[deps.get_service] = lambda: FakeService()
    app.dependency_overrides[deps.get_appliance_registry] = lambda: Registry()
    tip = client.get("/ambient").json()["tip"]
    assert tip["kind"] == "appliance"
    assert tip["text"] == "공기청정기(모의)가 바뀌었는지 몰라요. 가전을 봐 주세요."


def test_ambient_success_is_not_attention(client, monkeypatch):
    from rpi.controller.models import ExecutionOutcome

    class Snap:
        running = False
        last_result = object()
        last_appliance_id = "microwave"

    class FakeService:
        def status(self):
            return Snap()

    for outcome in (ExecutionOutcome.SUCCESS, ExecutionOutcome.STOPPED):
        monkeypatch.setattr(ambient_router, "outcome_of", lambda _r, o=outcome: o)
        app.dependency_overrides[deps.get_service] = lambda: FakeService()
        assert client.get("/ambient").json()["tip"] is None


def test_connections_default_mock_setup(client, monkeypatch):
    monkeypatch.setattr(ambient_router, "read_interface_state", lambda: "unknown")
    body = client.get("/connections").json()
    assert [i["id"] for i in body["items"]] == ["network", "press", "plug"]
    by_id = {i["id"]: i for i in body["items"]}
    assert by_id["network"]["state"] == "ok"
    assert (by_id["press"]["state"], by_id["press"]["source"]) == ("ok", "mock")
    assert by_id["plug"]["state"] == "not_installed"
    assert body["checked_at"]


def test_connections_plug_mock_when_l3_mock(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_L3_MODE", "mock")
    body = client.get("/connections").json()
    plug = next(i for i in body["items"] if i["id"] == "plug")
    assert (plug["state"], plug["source"]) == ("ok", "mock")


def test_connections_network_warn_when_weather_cannot_reach_internet(client, monkeypatch):
    def offline(*a, **k):
        raise kma.KmaError("network", None, "URLError")

    svc = WeatherService(WeatherConfig(mode="real", service_key="K", nx=60, ny=127), fetch=offline)
    svc.snapshot()
    _use_weather(svc)
    monkeypatch.setattr(ambient_router, "read_interface_state", lambda: "up")
    network = client.get("/connections").json()["items"][0]
    assert network["state"] == "warn" and network["fixes"]


def test_connections_press_uart_reads_frame_tap(client, monkeypatch):
    class Tap:
        def frames(self):
            return [{"kind": "frame", "direction": "hub_to_act", "type": "execute", "t_monotonic_ns": 0}]

    class Controller:
        frame_tap = Tap()

    class FakeService:
        _controller = Controller()

    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    app.dependency_overrides[deps.get_service] = lambda: FakeService()
    press = client.get("/connections").json()["items"][1]
    assert (press["state"], press["title"]) == ("error", "작은 팔이 답하지 않아요")


def test_routes_require_key_on_lan(client, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_API_KEY", "secret-key")
    for path in ("/ambient", "/connections"):
        assert client.get(path).status_code == 401
        assert client.get(path, headers={"X-API-Key": "secret-key"}).status_code == 200


def test_ambient_response_carries_now_slot(client, monkeypatch):
    # 10/18: build_ambient가 만든 'now'를 응답 모델이 걸러 내 키오스크 날짜 옆 날씨가 3시간 칸으로만 보였다.
    monkeypatch.setenv("SIMPLELAY_WEATHER_MODE", "mock")
    ambient_router.get_weather_service.cache_clear()
    body = client.get("/ambient").json()
    assert "now" in body
    if body["now"] is not None:
        assert set(body["now"]) >= {"hour", "icon", "temp"}
