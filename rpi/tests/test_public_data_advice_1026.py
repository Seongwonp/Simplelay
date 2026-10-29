"""공감지능 덜 묻기 2단계(2026-10-26) — 등록된 가전만 고르는 온습도 카드, 자연스러운 소리 문장, 조언 카드(실행 없음),
에어코리아 바깥 미세먼지·천문연 공휴일/해 뜨고 짐·기상청 자외선.

외부 API는 손으로 만든 응답(``fixtures/public_data`` — 공개 활용 가이드의 모양)으로만 본다. 실제 호출 없음.
모든 시각은 고정(2026-10, KST). 2026-10-05는 월요일(대체공휴일)이다.
"""

from __future__ import annotations

import json
import logging
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

import pytest

from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand
from rpi.intent.environment import (
    QUESTION_AIRCON_COOL,
    QUESTION_AIRCON_DRY,
    QUESTION_DEHUMIDIFIER,
    EnvironmentalSuggester,
    EnvironmentTarget,
)
from rpi.intent.habit_timing import day_matches, set_holiday_lookup
from rpi.intent.habit_words import day_kind
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.suggestions import (
    KIND_ADVICE,
    AdviceNotExecutableError,
    ProactiveSuggestionService,
    speech_of,
)
from rpi.services.context_suggestions import (
    ADVICE_VENTILATE,
    VENTILATE_TITLE,
    WINDOWS_CLOSED_TITLE,
    ContextSignals,
    ContextSuggestionMonitor,
)
from rpi.services.weather import public_data as pd
from rpi.services.weather.kma import KmaError

KST = timezone(timedelta(hours=9))
FIX = Path(__file__).parent / "fixtures" / "public_data"
KEY = "secret-test-key+/="


def _body(name: str) -> bytes:
    return (FIX / name).read_bytes()


# ── 1. 온습도 카드: 등록돼 있고 지금 실행할 수 있는 가전만 ─────────────────────────────────

DEHUMIDIFIER = EnvironmentTarget("dehumidifier", "other", ("제습기 켜줘", "제습기 꺼줘"), "DEVICE_DEHUMIDIFIER", True)
AIRCON_DRY = EnvironmentTarget("ac1", "air_conditioner", ("제습 모드",), None, True)
AIRCON_COOL = EnvironmentTarget("ac2", "air_conditioner", ("에어컨 켜줘",), None, True)


def _env(reading, *targets):
    return EnvironmentalSuggester(lambda: reading, targets=lambda: targets)


def test_humid_prefers_registered_dehumidifier():
    c = _env((24.0, 74.0), AIRCON_DRY, DEHUMIDIFIER).candidate()
    assert (c.appliance_id, c.purpose, c.question) == ("dehumidifier", "제습기 켜줘", QUESTION_DEHUMIDIFIER)
    assert c.reason == "지금 실내 습도가 74%로 꽤 습해요."
    assert "—" not in c.reason
    assert c.signals == (("습도 74%", True),)  # 칩은 그대로


def test_humid_without_dehumidifier_uses_aircon_dry_mode():
    c = _env((24.0, 74.0), AIRCON_DRY).candidate()
    assert (c.appliance_id, c.purpose, c.question) == ("ac1", "제습 모드", QUESTION_AIRCON_DRY)


def test_no_matching_device_means_no_card():
    assert _env((24.0, 74.0)).candidate() is None
    assert _env((24.0, 74.0), AIRCON_COOL).candidate() is None  # 냉방만 있는 에어컨으로 습도 카드를 내지 않는다
    not_ready = EnvironmentTarget("dehumidifier", "other", ("제습기 켜줘",), "DEVICE_DEHUMIDIFIER", False)
    assert _env((24.0, 74.0), not_ready).candidate() is None
    assert _env((31.0, 50.0), DEHUMIDIFIER).candidate() is None  # 더위에 제습기를 권하지 않는다


def test_hot_uses_registered_cooling_aircon():
    c = _env((31.0, 75.0), AIRCON_COOL, DEHUMIDIFIER).candidate()
    assert (c.appliance_id, c.purpose, c.question) == ("ac2", "에어컨 켜줘", QUESTION_AIRCON_COOL)
    assert c.reason == "지금 실내 온도가 31도로 꽤 더워요. 습도도 75%로 높아요."


def test_hot_and_humid_with_only_dehumidifier_speaks_only_of_humidity():
    c = _env((31.0, 75.0), DEHUMIDIFIER).candidate()
    assert c.question == QUESTION_DEHUMIDIFIER and "더워요" not in c.reason


# ── 2. 소리로 읽을 말: "<근거 문장> <묻는 말>" ─────────────────────────────────────────

BANDS = (TimeBand("아침", time(6), time(11)), TimeBand("점심", time(11), time(14)),
         TimeBand("오후", time(14), time(17)), TimeBand("저녁", time(17), time(21)),
         TimeBand("야간", time(21), time(6)))


def _service(now, *, environmental=None, limit=None, presence=None):
    clock = FixedClock(now)
    detector = PatternDetector(InMemoryUsageLog([]), clock, PatternConfig(3, BANDS))
    return clock, ProactiveSuggestionService(detector, clock, MockPurposeExecutor(), environmental=environmental,
                                             daily_ask_limit=limit, presence_gate=presence)


NOON = datetime(2026, 10, 26, 12, 0, tzinfo=KST)


def test_environment_card_speech_is_reason_then_question():
    _, service = _service(NOON, environmental=_env((24.0, 74.0), DEHUMIDIFIER))
    card, = service.create_suggestions()
    assert speech_of(card) == "지금 실내 습도가 74%로 꽤 습해요. 제습기를 켤까요?"
    assert "하시려면" not in speech_of(card)


def test_speech_puts_habit_question_last_and_scenario_question_after_reason():
    from rpi.intent.models import ProactiveSuggestion

    habit = ProactiveSuggestion("s1", "데우기", "저녁", 3, NOON, question="평소처럼 '저녁 데우기' 할까요?",
                                reason="평소처럼 '저녁 데우기' 할까요? 최근 28일 중 5일, 오후 7시쯤 하셨어요")
    assert speech_of(habit) == "최근 28일 중 5일, 오후 7시쯤 하셨어요. 평소처럼 '저녁 데우기' 할까요?"
    plain = ProactiveSuggestion("s2", "데우기", "저녁", 3, NOON, reason="최근 28일 중 5일")
    assert speech_of(plain) is None  # 묻는 말은 화면이 기능 이름으로 만든다


# ── 3. 조언 카드: 실행 없음, '알겠어요'·'괜찮아요', 하루 상한에 센다 ─────────────────────────


def test_advice_card_is_not_executable_and_closes_with_acknowledge():
    _, service = _service(NOON)
    card = service.create_advice(title=VENTILATE_TITLE, text="실내 습도가 74%로 꽤 습해요.",
                                 signals=(("집에 계심", True),))
    assert card.kind == KIND_ADVICE and card.appliance_id is None and card.commands == ()
    assert speech_of(card) == "실내 습도가 74%로 꽤 습해요."
    with pytest.raises(AdviceNotExecutableError):
        service.approve_submit(card.suggestion_id)
    assert service.pending()[0].status.value == "pending"  # 승인 시도가 카드를 소비하지 않는다
    service.reject(card.suggestion_id, reason="acknowledged")
    assert service.pending() == ()
    actions = [e["action"] for e in service.feedback_events()["events"]]
    assert "acknowledged" in actions


def test_acknowledge_is_only_for_advice_cards():
    _, service = _service(NOON, environmental=_env((24.0, 74.0), DEHUMIDIFIER))
    card, = service.create_suggestions()
    with pytest.raises(ValueError):
        service.reject(card.suggestion_id, reason="acknowledged")


def test_advice_counts_toward_daily_ask_limit_and_respects_quiet_and_presence():
    clock, service = _service(NOON, limit=1)
    first = service.create_advice(title=VENTILATE_TITLE, text="환기해 보세요.")
    service.reject(first.suggestion_id)  # '괜찮아요'
    clock.set(NOON + timedelta(hours=2))
    assert service.create_advice(title=WINDOWS_CLOSED_TITLE, text="창문은 닫아 두세요.") is None  # 오늘 하나 물었다
    assert service.asked_today() == 1

    _, quiet = _service(NOON)
    quiet.set_quiet_schedule(lambda: True)
    assert quiet.create_advice(title=VENTILATE_TITLE, text="환기해 보세요.") is None
    _, away = _service(NOON, presence=lambda: False)
    assert away.create_advice(title=VENTILATE_TITLE, text="환기해 보세요.") is None


def test_advice_backs_off_after_two_ignored_days():
    clock, service = _service(datetime(2026, 10, 20, 12, 0, tzinfo=KST))
    for day in (20, 21):
        clock.set(datetime(2026, 10, day, 12, 0, tzinfo=KST))
        assert service.create_advice(title=VENTILATE_TITLE, text="환기해 보세요.") is not None
        clock.set(datetime(2026, 10, day, 13, 0, tzinfo=KST))
        assert service.pending() == ()  # 30분 지나 무시로 만료
    clock.set(datetime(2026, 10, 22, 12, 0, tzinfo=KST))
    assert service.create_advice(title=VENTILATE_TITLE, text="환기해 보세요.") is None
    clock.set(datetime(2026, 10, 23, 12, 0, tzinfo=KST))
    assert service.create_advice(title=VENTILATE_TITLE, text="환기해 보세요.") is not None


# ── 3-1. 환기·창문 닫기 규칙 ─────────────────────────────────────────────────────

DAY = datetime(2026, 10, 26, 14, 0, tzinfo=KST)


def _vent(**kw):
    base = dict(local_now=DAY, presence="present", indoor_temp=24.0, indoor_humidity=74.0, outdoor_temp=18.0,
                outdoor_humidity=55, outdoor_pty=0, outdoor_pop=20, outdoor_air="보통")
    base.update(kw)
    return ContextSignals(**base)


def _advice_monitor(signals, result=object()):
    box = {"s": signals, "advice": []}

    def advise(*, title, text, signals=()):
        box["advice"].append((title, text, signals))
        return result

    monitor = ContextSuggestionMonitor(lambda: box["s"], lambda *a, **k: None, advise=advise)
    return monitor, box


def test_ventilation_advice_text_and_chips():
    monitor, box = _advice_monitor(_vent())
    assert "ventilate:offered" in monitor.check_once()
    title, text, chips = box["advice"][0]
    assert title == VENTILATE_TITLE
    assert text == ("실내 습도가 74%로 꽤 습해요. 바깥은 18도로 선선하니 잠깐 창문을 열어 환기해 보시는 건 어떨까요?")
    assert [label for label, _ in chips][0] == "집에 계심"
    assert "바깥 미세먼지 보통" in [label for label, _ in chips]
    assert "ventilate:done" in monitor.check_once()  # 하루 한 번
    assert len(box["advice"]) == 1


@pytest.mark.parametrize("change, outcome", [
    (dict(outdoor_pty=1), "ventilate:rain"),
    (dict(outdoor_pop=40), "ventilate:rain"),
    (dict(presence="away"), "ventilate:absent"),
    (dict(local_now=DAY.replace(hour=21)), "ventilate:not_daytime"),
    (dict(local_now=DAY.replace(hour=7)), "ventilate:not_daytime"),
    (dict(outdoor_air=None), "ventilate:outdoor_air_unknown"),
    (dict(dust_warning=True), "ventilate:dust_warning"),
    (dict(indoor_humidity=60.0, indoor_temp=20.0), "ventilate:indoor_ok"),
    (dict(outdoor_humidity=70, indoor_temp=20.0), "ventilate:indoor_ok"),  # 바깥도 습하다
    (dict(outdoor_temp=5.0), "ventilate:cold_outside"),
])
def test_ventilation_advice_needs_every_condition(change, outcome):
    monitor, box = _advice_monitor(_vent(**change))
    assert outcome in monitor.check_once()
    assert not [a for a in box["advice"] if a[0] == VENTILATE_TITLE]


def test_warm_indoor_also_suggests_ventilation():
    monitor, box = _advice_monitor(_vent(indoor_humidity=50.0, indoor_temp=29.0, outdoor_temp=20.0))
    monitor.check_once()
    assert box["advice"][0][1].startswith("실내 온도는 29도예요. 바깥은 20도로 선선하니")


@pytest.mark.parametrize('inside,outside', [(21, 13), (20, 10), (26, 20), (27, 15)])
def test_temperature_gap_alone_does_not_mean_the_room_is_hot(inside, outside):
    monitor, box = _advice_monitor(_vent(indoor_humidity=50, indoor_temp=inside, outdoor_temp=outside))
    assert 'ventilate:indoor_ok' in monitor.check_once()
    assert not box['advice']


def test_bad_outdoor_air_says_keep_windows_closed_once():
    purifier = {"operation": {"airPurifierOperationMode": "POWER_ON"},
                "airQualitySensor": {"PM2Level": "GOOD", "totalPollutionLevel": "GOOD"}}
    monitor, box = _advice_monitor(_vent(outdoor_air="나쁨", purifier=purifier))
    out = monitor.check_once()
    assert "ventilate:outdoor_air_bad" in out and "windows:offered" in out
    assert box["advice"] == [(WINDOWS_CLOSED_TITLE, "밖 공기는 나쁜데 집 안은 괜찮아요. 창문은 닫아 두세요.",
                              (("집에 계심", True), ("바깥 미세먼지 나쁨", True), ("실내 습도 74%", True)))]
    assert "windows:done" in monitor.check_once()
    monitor2, box2 = _advice_monitor(_vent(outdoor_air="매우 나쁨"))
    monitor2.check_once()
    assert box2["advice"][0][1] == "밖 공기가 나빠요. 창문은 닫아 두세요."


def test_blocked_advice_is_retried_and_not_marked_done():
    monitor, box = _advice_monitor(_vent(), result=None)
    assert "ventilate:not_offered" in monitor.check_once()
    assert "ventilate:not_offered" in monitor.check_once()
    assert ADVICE_VENTILATE not in monitor._advice_days


def test_arrival_reason_mentions_bad_outdoor_air():
    from rpi.tests.test_context_suggestions import _arrival_signals, _monitor

    monitor, box = _monitor(_arrival_signals(outdoor_air="나쁨"))
    assert monitor.check_once().startswith("sleep:no_lights_off,arrival:offered")
    _, reason, *_ = box["offers"][0]
    assert "바깥 미세먼지도 나빠요." in reason
    monitor2, box2 = _monitor(_arrival_signals(purifier={"operation": {"airPurifierOperationMode": "POWER_OFF"},
                                                         "airQualitySensor": {"totalPollutionLevel": "GOOD"}},
                                               outdoor_air="나쁨"))
    monitor2.check_once()
    assert "바깥 미세먼지가 나빠요." in box2["offers"][0][1]


def test_sleep_rule_does_not_treat_dark_as_night_before_sunset():
    from rpi.services.context_suggestions import ContextRuleConfig
    from rpi.tests.test_context_suggestions import _sleep_signals

    early = DAY.replace(hour=17, minute=0)
    signals = _sleep_signals(local_now=early, sunset=early.replace(hour=17, minute=34))
    monitor = ContextSuggestionMonitor(lambda: signals, lambda *a, **k: object(),
                                       config=ContextRuleConfig(night_start_hour=16, night_end_hour=2))
    assert monitor.check_once().startswith("sleep:before_sunset")


# ── 4. 에어코리아 ────────────────────────────────────────────────────────────────


def test_parse_items_shapes_and_errors():
    assert len(pd.parse_items(200, _body("airkorea_nearby.json"))) == 3
    assert pd.parse_items(200, _body("kasi_holidays_2026_11.json")) == []
    assert pd.parse_items(200, _body("kasi_riseset.json"))[0]["sunrise"].strip() == "0654"
    with pytest.raises(KmaError) as err:
        pd.parse_items(401, _body("error_key.xml"))
    assert err.value.kind == "api" and err.value.code == "30"


def test_tm_conversion_origin_and_direction():
    x, y = pd.latlon_to_tm(38.0, 127.0)
    assert abs(x - 200000) < 0.01 and abs(y - 500000) < 0.01
    x, y = pd.latlon_to_tm(37.394, 126.957)  # 안양 근처 — 원점 남서쪽
    assert 195000 < x < 200000 and 430000 < y < 440000


def test_realtime_and_forecast_parsing():
    rt = pd.parse_realtime(pd.parse_items(200, _body("airkorea_realtime.json")))
    assert rt["pm10"] == 62 and rt["pm25"] == 28 and pd.GRADE_WORDS[rt["grade"]] == "보통"
    # 등급 칸이 비면 공개 기준으로 값에서 매긴다
    assert pd.parse_realtime([{"pm10Value": "160", "pm25Value": "-", "pm10Grade": "-"}])["grade"] == 4
    fc = pd.parse_forecast(pd.parse_items(200, _body("airkorea_forecast_pm25.json")), "경기남부")
    assert fc == {"2026-10-26": 3, "2026-10-27": 1, "2026-10-28": 2}  # 같은 날은 늦게 발표한 것
    assert pd.forecast_region("경기 안양시 동안구", 37.39, 126.95) == "경기남부"
    assert pd.forecast_region("경기 고양시", 37.66, 126.83) == "경기북부"
    assert pd.forecast_region("서울 중구 덕수궁길", None, None) == "서울"
    assert pd.forecast_region("강원 강릉시", 37.75, 128.9) == "영동"


class _Http:
    def __init__(self, routes):
        self.routes = routes
        self.urls = []

    def __call__(self, url, timeout):
        assert timeout == 5.0
        self.urls.append(url)
        for marker, body in self.routes.items():
            if marker in url:
                return 200, body() if callable(body) else body
        return 200, _body("kasi_holidays_2026_11.json")  # 자료 없음


def _cfg(**kw):
    base = dict(service_key=KEY, lat=37.394, lon=126.957, timeout_seconds=5.0)
    base.update(kw)
    return pd.PublicDataConfig(**base)


NOW_UTC = datetime(2026, 10, 26, 5, 30, tzinfo=timezone.utc)  # 14:30 KST


def _air_http():
    return _Http({"getNearbyMsrstnList": _body("airkorea_nearby.json"),
                  "getMsrstnAcctoRltmMesureDnsty": _body("airkorea_realtime.json"),
                  "InformCode=PM25": _body("airkorea_forecast_pm25.json"),
                  "InformCode=PM10": _body("airkorea_forecast_pm10.json")})


def test_outdoor_air_snapshot_end_to_end_without_blocking(caplog):
    http = _air_http()
    spawned = []
    air = pd.OutdoorAirService(_cfg(), http_get=http, clock=lambda: NOW_UTC, spawn=spawned.append)
    assert air.snapshot() is None  # 첫 읽기는 캐시만 — 받기는 스레드에 맡긴다
    assert len(spawned) == 1 and http.urls == []
    spawned[0]()
    snap = air.snapshot()
    assert snap == {"station": "부림동", "pm10": 62, "pm25": 28, "grade": "보통",
                    "forecast_today": "나쁨", "forecast_tomorrow": "보통"}
    assert any("stationName=%EB%B6%80%EB%A6%BC%EB%8F%99" in u for u in http.urls)
    assert len(spawned) == 1  # 신선한 동안 다시 받지 않는다
    assert KEY not in caplog.text


def test_outdoor_air_failure_is_silent_and_key_never_logged(caplog):
    caplog.set_level(logging.DEBUG)

    def broken(url, timeout):
        raise OSError(f"boom {url}")

    air = pd.OutdoorAirService(_cfg(), http_get=broken, clock=lambda: NOW_UTC, spawn=lambda fn: fn())
    assert air.snapshot() is None
    assert "secret-test-key" not in caplog.text and "serviceKey" not in caplog.text
    assert pd.OutdoorAirService(_cfg(service_key=None)).snapshot() is None


def test_station_override_skips_nearby_lookup():
    http = _air_http()
    air = pd.OutdoorAirService(_cfg(station="중구", lat=None, lon=None), http_get=http,
                               clock=lambda: NOW_UTC, spawn=lambda fn: fn())
    air.snapshot()
    assert not any("getNearbyMsrstnList" in u for u in http.urls)
    assert air.snapshot()["station"] == "중구"


# ── 5. 공휴일 ────────────────────────────────────────────────────────────────────


def test_holiday_calendar_and_habit_day_kind():
    http = _Http({"solMonth=10": _body("kasi_holidays_2026_10.json")})
    cal = pd.HolidayCalendar(_cfg(), http_get=http, clock=lambda: NOW_UTC, spawn=lambda fn: fn())
    assert cal.is_holiday(date(2026, 10, 5)) is True  # 받기 뒤 바로 캐시
    assert cal.is_holiday(date(2026, 10, 6)) is False
    days = ("2026-10-05", "2026-10-10", "2026-10-11")  # 대체공휴일 월 · 토 · 일
    assert day_kind(days) is None  # 공휴일 표 없이: 섞임
    try:
        set_holiday_lookup(cal.is_holiday)
        assert day_kind(days) == "weekend"
        assert day_matches("weekend", date(2026, 10, 9)) is True  # 한글날(금)
        assert day_matches("weekday", date(2026, 10, 9)) is False
        assert day_matches("weekday", date(2026, 10, 8)) is True
    finally:
        set_holiday_lookup(None)
    assert day_matches("weekday", date(2026, 10, 9)) is True  # 표가 없으면 평일 규칙만


def test_holiday_lookup_offline_falls_back_to_weekday_logic():
    def broken(url, timeout):
        raise OSError("offline")

    cal = pd.HolidayCalendar(_cfg(), http_get=broken, clock=lambda: NOW_UTC, spawn=lambda fn: fn())
    try:
        set_holiday_lookup(cal.is_holiday)
        assert cal.is_holiday(date(2026, 10, 9)) is None
        assert day_matches("weekday", date(2026, 10, 9)) is True
        assert day_kind(("2026-10-02", "2026-10-05", "2026-10-06")) == "weekday"  # 사이 주말을 건너뜀
    finally:
        set_holiday_lookup(None)


# ── 6. 자외선·해 뜨고 짐 ───────────────────────────────────────────────────────────


def test_uv_advice_only_when_very_high_in_daytime():
    http = _Http({"getUVIdxV5": _body("kma_uv.json")})
    living = pd.LivingWeather(_cfg(), http_get=http, clock=lambda: NOW_UTC, spawn=lambda fn: fn())
    assert living.area_no == "4100000000"  # 안양 → 경기
    noon = datetime(2026, 10, 26, 3, 0, tzinfo=timezone.utc)  # 12:00 KST → h6 칸(9)
    assert living.uv_index(noon) == 9
    assert living.uv_advice(noon) == "자외선이 강해요. 외출하실 때 선크림 바르세요."
    assert any("time=2026102606" in u and "areaNo=4100000000" in u for u in http.urls)
    later = datetime(2026, 10, 26, 6, 30, tzinfo=timezone.utc)  # 15:30 KST → h9 칸(3)
    assert living.uv_advice(later) is None
    evening = datetime(2026, 10, 26, 8, 0, tzinfo=timezone.utc)  # 17:00 KST — 낮 시간 밖
    assert living.uv_advice(evening) is None


def test_sun_times_and_sunset_guard_value():
    http = _Http({"getLCRiseSetInfo": _body("kasi_riseset.json")})
    living = pd.LivingWeather(_cfg(), http_get=http, clock=lambda: NOW_UTC, spawn=lambda fn: fn())
    assert living.sun_times() == ("06:54", "17:34")
    assert any("locdate=20261026" in u and "_type=json" in u for u in http.urls)
    local = datetime(2026, 10, 26, 16, 0, tzinfo=KST)
    assert pd.sunset_at(("06:54", "17:34"), local) == local.replace(hour=17, minute=34)
    assert pd.LivingWeather(_cfg(lat=None, lon=None)).sun_times() == (None, None)


# ── 7. API: /ambient · /suggestions · 인사 ───────────────────────────────────────────


class _FakePublic:
    def __init__(self):
        self.air = type("A", (), {"snapshot": lambda self: {
            "station": "부림동", "pm10": 62, "pm25": 28, "grade": "보통",
            "forecast_today": "나쁨", "forecast_tomorrow": None}})()
        self.living = type("L", (), {"sun_times": lambda self: ("06:54", "17:34"),
                                     "uv_advice": lambda self: pd.UV_ADVICE})()


def test_ambient_exposes_outdoor_air_and_sun(monkeypatch):
    from fastapi.testclient import TestClient

    from rpi.api import ambient_router
    from rpi.main import app

    monkeypatch.setattr(ambient_router, "get_public_data", lambda: _FakePublic())
    body = TestClient(app).get("/ambient").json()
    assert body["outdoor_air"]["station"] == "부림동" and body["outdoor_air"]["grade"] == "보통"
    assert body["outdoor_air"]["forecast_today"] == "나쁨"
    assert (body["sunrise"], body["sunset"]) == ("06:54", "17:34")


def test_ambient_without_key_has_null_outdoor_air(monkeypatch):
    from fastapi.testclient import TestClient

    from rpi.api import ambient_router
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_WEATHER_MODE", raising=False)
    ambient_router.get_public_data.cache_clear()
    body = TestClient(app).get("/ambient").json()
    assert body["outdoor_air"] is None and body["sunrise"] is None


def test_greeting_line_adds_uv_advice(monkeypatch):
    from rpi.api import ambient_router, router

    monkeypatch.setattr(router, "_greeting_forecast_line", lambda: "지금 비가 와요. 나갈 때 우산 챙기세요.")
    monkeypatch.setattr(ambient_router, "uv_advice_now", lambda: pd.UV_ADVICE)
    assert router._greeting_weather_line() == "지금 비가 와요. 나갈 때 우산 챙기세요. " + pd.UV_ADVICE
    monkeypatch.setattr(router, "_greeting_forecast_line", lambda: None)
    assert router._greeting_weather_line() == pd.UV_ADVICE


from rpi.tests.test_context_suggestions import api  # noqa: E402,F401


def test_api_environment_card_picks_registered_dehumidifier(api):  # noqa: F811
    """모의 LG 가전에 제습기가 있다 — 습하면 '제습기를 켤까요?', 소리 문장은 근거 + 질문."""
    created = api.post("/demo/environment", json={"temperature": 24.0, "humidity": 75.0}).json()
    card, = [c for c in created if c["time_band"] == "환경"]
    assert card["appliance_id"] == "dehumidifier" and card["purpose"] == "제습기 켜줘"
    assert card["question"] == "제습기를 켤까요?"
    assert card["speech"] == "시연 데이터예요. 지금 실내 습도가 75%로 꽤 습해요. 제습기를 켤까요?"
    assert card["kind"] == "action"


def test_api_advice_card_kind_and_acknowledge(api):  # noqa: F811
    from rpi.api import deps

    card = deps.get_suggestion_service().create_advice(title=VENTILATE_TITLE, text="환기해 보세요.",
                                                         signals=(("집에 계심", True),))
    listed, = [c for c in api.get("/suggestions").json() if c["id"] == card.suggestion_id]
    assert listed["kind"] == "advice" and listed["speech"] == "환기해 보세요." and listed["can_mark_done"] is False
    assert listed["appliance_id"] is None and listed["commands"] == []
    assert api.post(f"/suggestions/{card.suggestion_id}/approve").status_code == 409
    assert api.post(f"/suggestions/{card.suggestion_id}/reject", json={"reason": "acknowledged"}).status_code == 200
    assert [c for c in api.get("/suggestions").json() if c["id"] == card.suggestion_id] == []
