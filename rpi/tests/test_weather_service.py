"""날씨 캐시 — 새 발표 때만 받기, 실패 뒤 쉬기, 오래된 예보, 오프라인, 영속."""

import pathlib
from datetime import datetime, timedelta, timezone

from rpi.services.weather import WeatherConfig, WeatherService
from rpi.services.weather import kma

FIX = pathlib.Path(__file__).parent / "fixtures" / "kma"
KST = kma.KST
REAL = WeatherConfig(mode="real", service_key="K", nx=60, ny=127, stale_hours=6, retry_minutes=10)


class FakeFetch:
    def __init__(self):
        self.calls = 0
        self.fail: kma.KmaError | None = None

    def __call__(self, key, nx, ny, now, *, timeout):
        self.calls += 1
        if self.fail is not None:
            raise self.fail
        return kma.parse_response(
            200,
            (FIX / "vilage_fcst_ok.json").read_bytes(),
            source="kma",
            fetched_at=now.astimezone(timezone.utc),
        )


class MemoryStore:
    def __init__(self):
        self.values = {}

    def load_setting(self, key):
        return self.values.get(key)

    def save_setting(self, key, value):
        self.values[key] = value


def _at(h, m=0, day=30):
    return datetime(2026, 9, day, h, m, tzinfo=KST)


def test_off_mode_never_fetches():
    fetch = FakeFetch()
    svc = WeatherService(WeatherConfig(mode="off"), fetch=fetch)
    snap = svc.snapshot(_at(9))
    assert snap.source == "none" and not snap.usable and fetch.calls == 0


def test_mock_mode_is_offline_and_fresh():
    fetch = FakeFetch()
    snap = WeatherService(WeatherConfig(mode="mock"), fetch=fetch).snapshot(_at(9))
    assert snap.source == "mock" and snap.usable and fetch.calls == 0


def test_real_mode_fetches_once_per_issue():
    fetch = FakeFetch()
    svc = WeatherService(REAL, fetch=fetch)
    first = svc.snapshot(_at(9, 20))
    assert first.source == "kma" and first.usable and fetch.calls == 1
    svc.snapshot(_at(10, 50))  # 같은 08시 발표 -- 다시 받지 않는다
    assert fetch.calls == 1


def test_new_issue_triggers_refresh():
    fetch = FakeFetch()
    svc = WeatherService(REAL, fetch=fetch)
    svc.snapshot(_at(9, 20))
    # 픽스처의 base는 0800 그대로라 11:15에는 새 발표(1100)를 원한다.
    svc.snapshot(_at(11, 15))
    assert fetch.calls == 2


def test_failure_keeps_last_good_and_backs_off():
    fetch = FakeFetch()
    svc = WeatherService(REAL, fetch=fetch)
    svc.snapshot(_at(9, 20))
    fetch.fail = kma.KmaError("network", None, "URLError")
    snap = svc.snapshot(_at(11, 15))
    assert fetch.calls == 2
    assert snap.usable and snap.last_error == "network"
    svc.snapshot(_at(11, 20))  # 10분 안에는 다시 두드리지 않는다
    assert fetch.calls == 2
    svc.snapshot(_at(11, 26))
    assert fetch.calls == 3


def test_offline_from_start_returns_none_without_raising():
    fetch = FakeFetch()
    fetch.fail = kma.KmaError("network", None, "timeout")
    snap = WeatherService(REAL, fetch=fetch).snapshot(_at(9, 20))
    assert snap.source == "none" and snap.forecast is None and snap.last_error == "network"


def test_unexpected_exception_is_swallowed():
    def boom(*a, **k):
        raise RuntimeError("bug")

    snap = WeatherService(REAL, fetch=boom).snapshot(_at(9, 20))
    assert snap.source == "none"


def test_stale_after_configured_hours():
    fetch = FakeFetch()
    svc = WeatherService(REAL, fetch=fetch)
    svc.snapshot(_at(9, 20))
    fetch.fail = kma.KmaError("network", None, "URLError")
    later = svc.snapshot(_at(15, 21))  # 받은 지 6시간 1분
    assert later.stale and not later.usable and later.source == "kma"
    assert later.fetched_at == _at(9, 20).astimezone(timezone.utc)


def test_cache_persists_across_restart():
    store = MemoryStore()
    fetch = FakeFetch()
    WeatherService(REAL, store=store, fetch=fetch).snapshot(_at(9, 20))
    assert "weather_forecast_cache" in store.values

    offline = FakeFetch()
    offline.fail = kma.KmaError("network", None, "URLError")
    snap = WeatherService(REAL, store=store, fetch=offline).snapshot(_at(9, 40))
    # 같은 발표라 받으러 가지도 않고 저장본으로 답한다.
    assert offline.calls == 0 and snap.usable and snap.source == "kma"


def test_corrupt_persisted_cache_is_ignored():
    store = MemoryStore()
    store.values["weather_forecast_cache"] = "{broken"
    fetch = FakeFetch()
    fetch.fail = kma.KmaError("network", None, "x")
    snap = WeatherService(REAL, store=store, fetch=fetch).snapshot(_at(9, 20))
    assert snap.source == "none"


def test_stale_boundary_uses_fetched_time_not_forecast_time():
    fetch = FakeFetch()
    svc = WeatherService(REAL, fetch=fetch)
    svc.snapshot(_at(9, 20))
    fetch.fail = kma.KmaError("network", None, "x")
    assert not svc.snapshot(_at(9, 20) + timedelta(hours=5, minutes=59)).stale
