"""기상청 단기예보 클라이언트 — 격자 변환·발표 시각·키 인코딩·응답 해석.

네트워크는 쓰지 않는다. 응답은 공개 활용가이드 형식대로 쓴 fixtures/kma/ 파일이다.
"""

import pathlib
import urllib.parse
from datetime import datetime, timedelta, timezone

import pytest

from rpi.services.weather import WeatherConfig, latlon_to_grid
from rpi.services.weather import kma

FIX = pathlib.Path(__file__).parent / "fixtures" / "kma"
KST = kma.KST


def _read(name: str) -> bytes:
    return (FIX / name).read_bytes()


# ── 격자 변환 ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "lat, lon, expected",
    [
        (38.0, 126.0, (43, 136)),  # 투영 기준점
        (37.5665, 126.9780, (60, 127)),  # 서울시청
        (35.1798, 129.0750, (98, 76)),  # 부산시청
        (36.3504, 127.3845, (67, 100)),  # 대전시청
        (33.4996, 126.5312, (53, 38)),  # 제주시청
    ],
)
def test_latlon_to_grid_known_points(lat, lon, expected):
    assert latlon_to_grid(lat, lon) == expected


def test_latlon_out_of_range_rejected():
    with pytest.raises(ValueError):
        latlon_to_grid(95.0, 127.0)


def test_config_converts_latlon_when_nx_ny_missing():
    cfg = WeatherConfig.from_env(
        {
            "SIMPLELAY_WEATHER_MODE": "real",
            "SIMPLELAY_KMA_SERVICE_KEY": "k",
            "SIMPLELAY_WEATHER_LAT": "37.5665",
            "SIMPLELAY_WEATHER_LON": "126.9780",
        }
    )
    assert (cfg.mode, cfg.nx, cfg.ny) == ("real", 60, 127)


def test_config_nx_ny_win_over_latlon():
    cfg = WeatherConfig.from_env(
        {
            "SIMPLELAY_WEATHER_MODE": "real",
            "SIMPLELAY_KMA_SERVICE_KEY": "k",
            "SIMPLELAY_WEATHER_NX": "98",
            "SIMPLELAY_WEATHER_NY": "76",
            "SIMPLELAY_WEATHER_LAT": "37.5665",
            "SIMPLELAY_WEATHER_LON": "126.9780",
        }
    )
    assert (cfg.nx, cfg.ny) == (98, 76)


@pytest.mark.parametrize(
    "env",
    [
        {"SIMPLELAY_WEATHER_MODE": "real", "SIMPLELAY_WEATHER_NX": "60", "SIMPLELAY_WEATHER_NY": "127"},
        {"SIMPLELAY_WEATHER_MODE": "real", "SIMPLELAY_KMA_SERVICE_KEY": "k"},
        {"SIMPLELAY_KMA_SERVICE_KEY": "k", "SIMPLELAY_WEATHER_NX": "60", "SIMPLELAY_WEATHER_NY": "127"},
        {"SIMPLELAY_WEATHER_MODE": "sunny"},
    ],
)
def test_config_falls_back_to_off(env):
    assert WeatherConfig.from_env(env).mode == "off"


def test_config_repr_hides_key():
    cfg = WeatherConfig.from_env(
        {"SIMPLELAY_WEATHER_MODE": "mock", "SIMPLELAY_KMA_SERVICE_KEY": "SECRET123"}
    )
    assert "SECRET123" not in repr(cfg)


# ── 발표 시각 ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "local, expected",
    [
        ((2026, 9, 30, 8, 9), ("20260930", "0500")),  # 08시 발표는 08:10부터
        ((2026, 9, 30, 8, 10), ("20260930", "0800")),
        ((2026, 9, 30, 14, 59), ("20260930", "1400")),
        ((2026, 9, 30, 23, 30), ("20260930", "2300")),
        ((2026, 9, 30, 2, 9), ("20260929", "2300")),  # 자정 넘어 02:10 전은 전날 23시
        ((2026, 10, 1, 0, 30), ("20260930", "2300")),
        ((2026, 1, 1, 1, 0), ("20251231", "2300")),  # 해 넘김
    ],
)
def test_base_params_follow_issue_hours_and_delay(local, expected):
    now = datetime(*local, tzinfo=KST)
    assert kma.base_params(now) == expected


def test_base_params_accept_utc_input():
    # 2026-09-29 23:15 UTC == 2026-09-30 08:15 KST
    now = datetime(2026, 9, 29, 23, 15, tzinfo=timezone.utc)
    assert kma.base_params(now) == ("20260930", "0800")


# ── 서비스키 인코딩 ──────────────────────────────────────────────────────────

DECODED = "abc+def/ghi=="
ENCODED = "abc%2Bdef%2Fghi%3D%3D"


@pytest.mark.parametrize("key", [DECODED, ENCODED])
def test_decoded_and_encoded_keys_give_same_url(key):
    now = datetime(2026, 9, 30, 9, 0, tzinfo=KST)
    url = kma.build_url(key, 60, 127, now)
    query = url.split("?", 1)[1]
    assert f"serviceKey={ENCODED}&" in query
    parsed = urllib.parse.parse_qs(query)
    assert parsed["serviceKey"] == [DECODED]
    assert parsed["dataType"] == ["JSON"]
    assert parsed["base_date"] == ["20260930"]
    assert parsed["base_time"] == ["0800"]
    assert parsed["nx"] == ["60"] and parsed["ny"] == ["127"]
    assert parsed["pageNo"] == ["1"] and parsed["numOfRows"] == ["1000"]
    assert url.startswith(kma.ENDPOINT + "?")


# ── 응답 해석 ────────────────────────────────────────────────────────────────

FETCHED = datetime(2026, 9, 30, 0, 20, tzinfo=timezone.utc)


def test_parse_ok_fixture_groups_categories_by_hour():
    fc = kma.parse_response(200, _read("vilage_fcst_ok.json"), source="kma", fetched_at=FETCHED)
    assert fc.base == "202609300800"
    assert len(fc.slots) == 15
    first = fc.slots[0]
    assert first.at == datetime(2026, 9, 30, 9, tzinfo=KST)
    assert (first.tmp, first.pop, first.pty, first.sky) == (21.0, 20, 0, 1)
    three_pm = next(s for s in fc.slots if s.at.hour == 15)
    assert three_pm.precipitation == "rain" and three_pm.icon() == "rain"
    shower = next(s for s in fc.slots if s.at.hour == 19)
    assert shower.pty == 4 and shower.precipitation == "rain"
    assert [s.icon() for s in fc.slots[:5]] == ["clear", "clear", "partly", "partly", "cloudy"]


def test_forecast_json_roundtrip():
    fc = kma.parse_response(200, _read("vilage_fcst_ok.json"), source="kma", fetched_at=FETCHED)
    again = kma.Forecast.from_json(fc.to_json())
    assert again == fc


@pytest.mark.parametrize(
    "name, code",
    [("error_nodata.json", "03"), ("error_invalid_param.json", "10")],
)
def test_api_error_codes_raise(name, code):
    with pytest.raises(kma.KmaError) as info:
        kma.parse_response(200, _read(name), source="kma", fetched_at=FETCHED)
    assert (info.value.kind, info.value.code) == ("api", code)


def test_gateway_xml_error_is_read_even_when_json_requested():
    with pytest.raises(kma.KmaError) as info:
        kma.parse_response(
            200, _read("error_key_not_registered.xml"), source="kma", fetched_at=FETCHED
        )
    assert info.value.kind == "api"
    assert info.value.code == "30"
    assert info.value.message == "SERVICE_KEY_IS_NOT_REGISTERED_ERROR"


@pytest.mark.parametrize(
    "status, body, kind",
    [
        (401, b"Unauthorized", "api"),
        (200, b"", "parse"),
        (200, b"{not json", "parse"),
        (200, b'{"response": {"header": {"resultCode": "00"}}}', "parse"),
        (200, b"<html><body>oops", "parse"),
    ],
)
def test_malformed_bodies_raise_kma_error(status, body, kind):
    with pytest.raises(kma.KmaError) as info:
        kma.parse_response(status, body, source="kma", fetched_at=FETCHED)
    assert info.value.kind == kind


def test_fetch_uses_injected_transport_and_hides_key_on_failure():
    seen = {}

    def fake_get(url, timeout):
        seen["url"], seen["timeout"] = url, timeout
        return 200, _read("vilage_fcst_ok.json")

    now = datetime(2026, 9, 30, 9, 20, tzinfo=KST)
    fc = kma.fetch_forecast("KEY", 60, 127, now, timeout=3.0, http_get=fake_get)
    assert fc.source == "kma" and seen["timeout"] == 3.0
    assert fc.fetched_at == now.astimezone(timezone.utc)

    def broken(url, timeout):
        raise OSError(f"connect failed for {url}")

    with pytest.raises(kma.KmaError) as info:
        kma.fetch_forecast("SECRETKEY", 60, 127, now, http_get=broken)
    assert info.value.kind == "network"
    assert "SECRETKEY" not in str(info.value)


def test_mock_forecast_rains_from_three_pm():
    now = datetime(2026, 9, 30, 9, 0, tzinfo=KST)
    fc = kma.mock_forecast(now)
    assert fc.source == "mock"
    rain_hours = [s.at.hour for s in fc.slots if s.at.date() == now.date() and s.precipitation]
    assert rain_hours[0] == 15
    assert fc.slots[-1].at - fc.slots[0].at == timedelta(hours=47)
