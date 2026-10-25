"""기상특보(10/25) — 특보코드조회 발표 목록에서 우리 지역에 지금 걸린 주의보·경보만 고른다."""
from datetime import datetime, timedelta, timezone

from rpi.services.weather import WeatherConfig, WeatherService
from rpi.services.weather import kma
from rpi.services.weather.warnings import active_warnings

SEOUL = ("L1100",)


def _it(area, var, stress, command, tm, seq=1, cancel="0"):
    return {"areaCode": area, "warnVar": var, "warnStress": stress, "command": str(command),
            "tmFc": tm, "tmSeq": seq, "cancel": cancel}


def test_only_our_area_and_only_still_active():
    items = [
        _it("L1100100", 1, 0, 1, 202610250900),          # 서울동남권 강풍주의보 발표 → 걸림
        _it("L1110130", 3, 0, 1, 202610250900),          # 인천 한파 — 다른 지역
        _it("L1170120", 12, 0, 1, 202610250900),         # 세종 — 'L11'로 시작하지만 서울 아님
        _it("L1100200", 2, 0, 1, 202610240900),          # 호우주의보 발표했다가
        _it("L1100200", 2, 0, 2, 202610241500),          # 해제 → 안 걸림
        _it("L1100300", 8, 0, 1, 202610250800, cancel="1"),  # 취소된 특보
    ]
    out = active_warnings(items, SEOUL)
    assert [w["title"] for w in out] == ["강풍주의보"]
    assert "조심" in out[0]["advice"]


def test_strongest_level_first_and_one_per_kind():
    items = [
        _it("L1100100", 12, 0, 1, 202610250900),
        _it("L1100200", 12, 1, 1, 202610251000),   # 폭염경보(다른 구역) — 종류마다 센 것 하나
        _it("L1100100", 1, 0, 1, 202610250900),
    ]
    assert [w["title"] for w in active_warnings(items, SEOUL)] == ["폭염경보", "강풍주의보"]


def test_change_release_ends_the_old_level():
    items = [
        _it("L1100100", 2, 0, 1, 202610250600),
        _it("L1100100", 2, 0, 8, 202610250900, seq=2),   # 주의보 변경해제
        _it("L1100100", 2, 1, 7, 202610250900, seq=2),   # 경보 변경발표
    ]
    assert [w["title"] for w in active_warnings(items, SEOUL)] == ["호우경보"]


def _service(fetch, areas=SEOUL, mode="real"):
    cfg = WeatherConfig(mode=mode, service_key="K", nx=60, ny=127, warn_areas=areas)
    return WeatherService(cfg, fetch=lambda **kw: None, fetch_warnings=fetch)


def test_service_refreshes_every_30_minutes_and_survives_failure():
    calls = []
    now = datetime(2026, 10, 25, 3, 0, tzinfo=timezone.utc)

    def fetch(key, at, timeout):
        calls.append(at)
        if len(calls) == 2:
            raise kma.KmaError("http", "403", "x")
        return [_it("L1100100", 1, 0, 1, 202610251100)]

    svc = _service(fetch)
    assert [w["title"] for w in svc.warnings(now)] == ["강풍주의보"]
    assert svc.warnings(now + timedelta(minutes=10))  # 캐시
    assert len(calls) == 1
    assert svc.warnings(now + timedelta(minutes=31))  # 실패해도 직전 값
    assert len(calls) == 2
    assert svc.warnings(now + timedelta(hours=4)) == [] or len(calls) == 3


def test_off_without_areas_or_real_mode():
    def boom(*a):
        raise AssertionError("must not call")

    assert _service(boom, areas=()).warnings() == []
    assert _service(boom, mode="mock").warnings() == []


def test_config_reads_area_prefixes():
    cfg = WeatherConfig.from_env({"SIMPLELAY_WEATHER_WARN_AREAS": " l1100 , L1010 "})
    assert cfg.warn_areas == ("L1100", "L1010")


def test_area_comes_from_hub_location():
    """서울 고정이 아니라 폰 앱이 저장한 허브 위치로 구역을 정한다(10/25 사용자)."""
    from rpi.services.weather.warnings import zones_for_location

    seoul = zones_for_location(37.5779, 126.8906)        # 상암동
    assert "L1100400" in seoul and all(c.startswith("L1100") for c in seoul)
    assert zones_for_location(37.2636, 127.0286) == ("L1011900",)   # 수원시
    paju = zones_for_location(37.76, 126.78)
    assert "L1013700" in paju and "L1013710" in paju                  # 세부 구역 함께
    gangneung = zones_for_location(37.75, 128.88)
    assert "L1022520" not in gangneung                                 # 산지 구역은 따로
    assert zones_for_location(None, None) == ()
    assert zones_for_location(33.0, 124.0) == ()                       # 바다 위


def test_service_uses_location_when_no_env_areas():
    cfg = WeatherConfig(mode="real", service_key="K", nx=60, ny=127, lat=37.2636, lon=127.0286)
    items = [_it("L1011900", 3, 0, 1, 202610250900), _it("L1100400", 1, 0, 1, 202610250900)]
    svc = WeatherService(cfg, fetch=lambda **kw: None, fetch_warnings=lambda *a: items)
    assert [w["title"] for w in svc.warnings(datetime(2026, 10, 25, 3, 0, tzinfo=timezone.utc))] == ["한파주의보"]
