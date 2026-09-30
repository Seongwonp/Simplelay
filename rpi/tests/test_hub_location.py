"""허브 위치 API — 폰 "현재 위치로 설정"이 날씨 격자를 정한다(2026-09-30)."""

import pytest
from fastapi.testclient import TestClient

import rpi.api.ambient_router as ambient_router
import rpi.api.deps as deps
from rpi.main import app


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    for name in ("SIMPLELAY_WEATHER_MODE", "SIMPLELAY_KMA_SERVICE_KEY", "SIMPLELAY_WEATHER_NX",
                 "SIMPLELAY_WEATHER_NY", "SIMPLELAY_WEATHER_LAT", "SIMPLELAY_WEATHER_LON"):
        monkeypatch.delenv(name, raising=False)
    deps.get_db.cache_clear() if hasattr(deps.get_db, "cache_clear") else None
    ambient_router._memory_location.clear()
    ambient_router.get_weather_service.cache_clear()
    yield TestClient(app)
    ambient_router._memory_location.clear()
    ambient_router.get_weather_service.cache_clear()


def test_no_location_by_default(client):
    assert client.get("/hub/location").json()["source"] == "none"


def test_put_rounds_to_about_1km_and_returns_grid(client):
    body = client.put("/hub/location", json={"lat": 37.566535, "lon": 126.977969}).json()
    assert body == {"source": "app", "lat": 37.57, "lon": 126.98, "nx": 60, "ny": 127}
    assert client.get("/hub/location").json()["source"] == "app"


def test_stored_location_wins_over_env_grid(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_WEATHER_MODE", "real")
    monkeypatch.setenv("SIMPLELAY_KMA_SERVICE_KEY", "test-key")
    monkeypatch.setenv("SIMPLELAY_WEATHER_NX", "1")
    monkeypatch.setenv("SIMPLELAY_WEATHER_NY", "1")
    client.put("/hub/location", json={"lat": 37.57, "lon": 126.98})
    cfg = ambient_router.get_weather_service().config
    assert (cfg.nx, cfg.ny) == (60, 127)
    assert cfg.mode == "real"


def test_location_enables_real_mode_when_env_has_no_grid(client, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_WEATHER_MODE", "real")
    monkeypatch.setenv("SIMPLELAY_KMA_SERVICE_KEY", "test-key")
    assert ambient_router.get_weather_service().config.mode == "off"
    client.put("/hub/location", json={"lat": 37.57, "lon": 126.98})
    assert ambient_router.get_weather_service().config.mode == "real"


def test_outside_korea_is_rejected_in_plain_korean(client):
    r = client.put("/hub/location", json={"lat": 48.85, "lon": 2.35})
    assert r.status_code == 422
    assert "국내" in r.json()["detail"]


def test_delete_clears_location(client):
    client.put("/hub/location", json={"lat": 37.57, "lon": 126.98})
    assert client.delete("/hub/location").json()["source"] == "none"
