"""평소 화면 안내 — 인사말, 안내 한 줄의 우선순위, 시간대 예보 4칸."""

import dataclasses
import pathlib
from datetime import datetime, timezone

import pytest

from rpi.services.weather import (
    AttentionItem,
    HourlyForecast,
    WeatherConfig,
    WeatherSnapshot,
    build_ambient,
    greeting,
    hourly_strip,
    weather_tip,
)
from rpi.services.weather import kma

FIX = pathlib.Path(__file__).parent / "fixtures" / "kma"
KST = kma.KST
CFG = WeatherConfig(mode="real", service_key="K", nx=60, ny=127)


def _at(h, m=0, day=30):
    return datetime(2026, 9, day, h, m, tzinfo=KST)


def _fixture_forecast():
    return kma.parse_response(
        200,
        (FIX / "vilage_fcst_ok.json").read_bytes(),
        source="kma",
        fetched_at=_at(8, 20).astimezone(timezone.utc),
    )


def _snap(forecast=None, stale=False, source="kma"):
    if forecast is None:
        return WeatherSnapshot("none")
    return WeatherSnapshot(source, forecast, forecast.fetched_at, stale)


def _flat(hours, **kw):
    return tuple(HourlyForecast(_at(h), **kw) for h in hours)


@pytest.mark.parametrize(
    "hour, text",
    [
        (5, "좋은 아침이에요."),
        (10, "좋은 아침이에요."),
        (11, "좋은 오후예요."),
        (16, "좋은 오후예요."),
        (17, "편안한 저녁 보내세요."),
        (21, "편안한 밤 보내세요."),
        (2, "편안한 밤 보내세요."),
    ],
)
def test_greeting_by_time_of_day(hour, text):
    assert greeting(_at(hour)) == text


def test_rain_tip_names_the_start_hour():
    tip = weather_tip(_fixture_forecast().slots, _at(9, 5), CFG)
    assert tip == {
        "kind": "rain",
        "text": "오후 3시부터 비 예보가 있어요. 우산 챙기세요.",
        "icon": "rain",
    }


def test_rain_now():
    tip = weather_tip(_fixture_forecast().slots, _at(16, 30), CFG)
    assert tip["text"] == "지금 비가 와요. 나갈 때 우산 챙기세요."


def test_rain_beyond_window_is_not_mentioned():
    cfg = WeatherConfig(mode="real", tip_hours=3)
    assert weather_tip(_fixture_forecast().slots, _at(9, 5), cfg) is None


def test_tomorrow_prefix():
    slots = (
        HourlyForecast(_at(22), 15, 10, 0, 1),
        HourlyForecast(datetime(2026, 10, 1, 6, tzinfo=KST), 14, 70, 1, 4),
    )
    tip = weather_tip(slots, _at(21, 30), CFG)
    assert tip["text"] == "내일 오전 6시부터 비 예보가 있어요. 우산 챙기세요."


def test_snow_tip():
    slots = _flat(range(9, 13), tmp=-1, pop=30, pty=0, sky=4) + (
        HourlyForecast(_at(13), -2, 70, 3, 4),
    )
    tip = weather_tip(slots, _at(9), CFG)
    assert tip["kind"] == "snow" and tip["icon"] == "snow"
    assert tip["text"] == "오후 1시부터 눈 예보가 있어요. 길이 미끄러울 수 있어요."


def test_pop_alone_counts_as_rain():
    slots = _flat(range(9, 12), tmp=20, pop=10, pty=0, sky=3) + (
        HourlyForecast(_at(12), 20, 60, 0, 4),
    )
    assert weather_tip(slots, _at(9), CFG)["text"].startswith("낮 12시부터 비")


def test_heat_and_cold_thresholds_from_config():
    hot = _flat(range(9, 18), tmp=34, pop=0, pty=0, sky=1)
    assert weather_tip(hot, _at(9), CFG)["kind"] == "heat"
    assert weather_tip(hot, _at(9), WeatherConfig(mode="real", heat_c=35)) is None
    cold = _flat(range(9, 18), tmp=-7, pop=0, pty=0, sky=1)
    tip = weather_tip(cold, _at(9), CFG)
    assert tip["kind"] == "cold" and tip["text"] == "최저 -7도까지 내려가 추워요. 따뜻하게 입으세요."


def test_rain_beats_heat():
    slots = _flat(range(9, 15), tmp=34, pop=0, pty=0, sky=1) + (
        HourlyForecast(_at(15), 30, 80, 4, 4),
    )
    assert weather_tip(slots, _at(9), CFG)["kind"] == "rain"


def test_hourly_strip_three_hour_steps():
    strip = hourly_strip(_fixture_forecast().slots, _at(8, 20), CFG)
    assert [s["hour"] for s in strip] == [9, 12, 15, 18]
    assert [s["icon"] for s in strip] == ["clear", "partly", "rain", "rain"]
    assert [s["precip"] for s in strip] == [False, False, True, True]
    assert strip[0] == {
        "time": "2026-09-30T09:00:00+09:00",
        "hour": 9,
        "label": "9시",
        "icon": "clear",
        "temp": 21,
        "pop": 20,
        "precip": False,
    }


def test_hourly_strip_on_the_hour_starts_now():
    strip = hourly_strip(_fixture_forecast().slots, _at(12, 0), CFG)
    assert [s["hour"] for s in strip] == [12, 15, 18, 21]


def test_hourly_strip_skips_missing_hours():
    strip = hourly_strip(_fixture_forecast().slots, _at(16, 10), CFG)
    # 픽스처는 23시까지라 18·21시만 있다.
    assert [s["hour"] for s in strip] == [18, 21]


def test_priority_appliance_before_weather():
    attention = [AttentionItem("appliance", "전자레인지 작업이 멈췄어요 · 기계를 봐 주세요")]
    body = build_ambient(_at(9, 5), _snap(_fixture_forecast()), attention, CFG)
    assert body["tip"] == {
        "kind": "appliance",
        "text": "전자레인지 작업이 멈췄어요 · 기계를 봐 주세요",
        "icon": "attention",
    }
    # 예보 4칸은 그대로 보인다 -- 안내만 하나다.
    assert len(body["hourly"]) == 4


def test_priority_weather_then_none():
    body = build_ambient(_at(9, 5), _snap(_fixture_forecast()), [], CFG)
    assert body["tip"]["kind"] == "rain"
    assert body["weather_source"] == "kma" and body["stale"] is False
    assert body["greeting"] == "좋은 아침이에요."

    calm = _flat(range(9, 22), tmp=20, pop=10, pty=0, sky=1)
    fc = kma.Forecast("kma", _at(8, 20).astimezone(timezone.utc), "202609300800", calm)
    assert build_ambient(_at(9, 5), _snap(fc), [], CFG)["tip"] is None


def test_stale_weather_shows_greeting_only():
    body = build_ambient(_at(9, 5), _snap(_fixture_forecast(), stale=True), [], CFG)
    assert body["tip"] is None and body["hourly"] == []
    assert body["stale"] is True and body["fetched_at"] is not None


def test_no_weather_shows_greeting_and_still_appliance_tip():
    attention = [AttentionItem("alert", "위험할 수 있는 소리가 들렸어요. 주변을 확인해 주세요.")]
    body = build_ambient(_at(20), _snap(None), attention, CFG)
    assert body["weather_source"] == "none" and body["fetched_at"] is None
    assert body["hourly"] == [] and body["tip"]["kind"] == "alert"
    assert body["greeting"] == "편안한 저녁 보내세요."


def test_only_first_attention_is_shown():
    attention = [
        AttentionItem("alert", "첫째"),
        AttentionItem("appliance", "둘째"),
    ]
    body = build_ambient(_at(9), _snap(None), attention, CFG)
    assert body["tip"]["text"] == "첫째"


# ── 지금 날씨 한 칸(10/18 — 키오스크 날짜 옆) ────────────────────────────────


def test_now_slot_uses_the_closest_hourly_slot_even_between_3h_marks():
    # 7:08 — 3시간 칸(hourly)은 9시부터라 지금 값이 없던 시각. 1시간 칸 7시를 쓴다.
    slots = tuple(HourlyForecast(_at(h), tmp=10.0 + h) for h in range(6, 12))
    body = build_ambient(_at(7, 8), _snap(_forecast_of(slots)), [], CFG)
    assert body["hourly"][0]["hour"] == 9
    assert body["now"]["hour"] == 7
    assert body["now"]["temp"] == 17


def test_now_slot_is_none_without_a_close_slot_or_temperature():
    far = (HourlyForecast(_at(12), tmp=20.0),)
    assert build_ambient(_at(7, 8), _snap(_forecast_of(far)), [], CFG)["now"] is None
    no_temp = (HourlyForecast(_at(7)),)
    assert build_ambient(_at(7, 8), _snap(_forecast_of(no_temp)), [], CFG)["now"] is None
    assert build_ambient(_at(7, 8), _snap(None), [], CFG)["now"] is None


def _forecast_of(slots):
    base = _fixture_forecast()
    return dataclasses.replace(base, slots=slots)


def test_now_slot_icon_is_current_sky_not_rain_probability():
    # 강수확률만 높고 강수형태는 없는 칸 — 날짜 옆 지금 아이콘은 비가 아니라 하늘 상태(11차 평가).
    slots = (HourlyForecast(_at(11), tmp=20.0, pop=70, pty=0, sky=4),)
    assert build_ambient(_at(11, 15), _snap(_forecast_of(slots)), [], CFG)["now"]["icon"] == "cloudy"
    rain = (HourlyForecast(_at(11), tmp=20.0, pop=70, pty=1, sky=4),)
    assert build_ambient(_at(11, 15), _snap(_forecast_of(rain)), [], CFG)["now"]["icon"] == "rain"


def test_weather_tip_and_today_range_are_kept_even_when_attention_wins():
    """날씨 자세히 창(10/25) — 확인할 일이 tip을 차지해도 비 안내와 오늘 최고·최저는 따로 온다."""
    slots = tuple(HourlyForecast(_at(h), tmp=10 + h, pop=80 if h == 15 else 10, pty=0, sky=1) for h in range(9, 22))
    forecast = kma.Forecast("kma", _at(8, 20).astimezone(timezone.utc), "202609300800", slots)
    out = build_ambient(_at(9, 10), _snap(forecast), [AttentionItem("alert", "약 드실 시간이에요")], CFG)
    assert out["tip"]["kind"] == "alert"
    assert out["weather_tip"]["kind"] == "rain" and "우산" in out["weather_tip"]["text"]
    assert out["today"] == {"high": 31, "low": 19}
    assert build_ambient(_at(9, 10), _snap(), [], CFG)["today"] is None


def test_outdoor_humidity_is_parsed_and_old_cache_still_loads():
    """10/26 — 기상청 예보의 습도(REH)도 받는다(환기 권유용). 습도 칸이 없던 옛 저장본도 그대로 읽힌다."""
    import json

    body = {"response": {"header": {"resultCode": "00"}, "body": {"items": {"item": [
        {"baseDate": "20260930", "baseTime": "0800", "category": c, "fcstDate": "20260930", "fcstTime": "0900", "fcstValue": v}
        for c, v in (("TMP", "21"), ("POP", "10"), ("PTY", "0"), ("SKY", "1"), ("REH", "45"))]}}}}
    f = kma.parse_response(200, json.dumps(body).encode(), source="kma", fetched_at=_at(8, 20).astimezone(timezone.utc))
    assert f.slots[0].reh == 45
    assert kma.Forecast.from_json(f.to_json()).slots[0].reh == 45
    old = json.loads(f.to_json())
    old["slots"] = [row[:5] for row in old["slots"]]
    assert kma.Forecast.from_json(json.dumps(old)).slots[0].reh is None
