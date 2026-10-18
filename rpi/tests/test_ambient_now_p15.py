"""평가 15차(10/18) — 키오스크 '지금' 칸과 날씨 안내 문장이 같은 '지금'을 쓴다.

실패널: 오후 2:21에 예보 줄 '지금' 칸은 비 아이콘(3시 칸을 앞뒤 90분 안이라 '지금'으로 씀)인데 안내 카드는
'오후 3시부터 비 예보가 있어요'였다. '지금'은 지난 정시 칸(없으면 앞뒤 30분 안)만이고, 안내 문장도 그 칸을 '지금'으로 본다.
"""

import dataclasses
import pathlib
from datetime import datetime, timezone

from rpi.services.weather import HourlyForecast, WeatherConfig, WeatherSnapshot, build_ambient, weather_tip
from rpi.services.weather import kma

FIX = pathlib.Path(__file__).parent / "fixtures" / "kma"
KST = kma.KST
CFG = WeatherConfig(mode="real", service_key="K", nx=60, ny=127)


def _at(h, m=0):
    return datetime(2026, 9, 30, h, m, tzinfo=KST)


def _forecast(drop_hours=()):
    base = kma.parse_response(
        200,
        (FIX / "vilage_fcst_ok.json").read_bytes(),
        source="kma",
        fetched_at=_at(8, 20).astimezone(timezone.utc),
    )
    slots = tuple(s for s in base.slots if s.at.astimezone(KST).hour not in drop_hours)
    return dataclasses.replace(base, slots=slots)


def _ambient(now, forecast):
    snap = WeatherSnapshot("kma", forecast, forecast.fetched_at, False)
    return build_ambient(now, snap, [], CFG)


def test_panel_case_2_21_without_2pm_slot_has_no_now_cell_and_tip_says_3pm():
    # 기상청 초단기 칸이 다음 정시부터 와 14시 칸이 없던 실패널 경우 — 15시(39분 뒤)는 '지금'이 아니다.
    body = _ambient(_at(14, 21), _forecast(drop_hours={14}))
    assert body["now"] is None
    assert body["tip"]["text"] == "오후 3시부터 비 예보가 있어요. 우산 챙기세요."


def test_now_is_the_past_hour_mark_slot_even_when_the_next_hour_is_closer():
    # 14:45 — 15시 칸이 15분으로 더 가깝지만 지금은 14시 칸(지난 정시)이다. 안내도 3시부터라고 말한다.
    body = _ambient(_at(14, 45), _forecast())
    assert body["now"]["hour"] == 14
    assert body["now"]["icon"] != "rain"
    assert body["tip"]["text"].startswith("오후 3시부터 비")


def test_next_hour_within_30_minutes_is_now_and_tip_says_raining_now():
    # 14:40, 14시 칸 없음 — 20분 뒤 15시 칸(비)이 '지금'이면 안내도 '지금 비가 와요'(같은 정의).
    body = _ambient(_at(14, 40), _forecast(drop_hours={14}))
    assert body["now"]["hour"] == 15 and body["now"]["icon"] == "rain"
    assert body["tip"]["text"] == "지금 비가 와요. 나갈 때 우산 챙기세요."


def test_now_rain_and_tip_agree_inside_rainy_hour():
    body = _ambient(_at(16, 30), _forecast())
    assert body["now"]["hour"] == 16 and body["now"]["icon"] == "rain"
    assert body["tip"]["text"] == "지금 비가 와요. 나갈 때 우산 챙기세요."


def test_now_slot_pop_only_is_not_called_raining_now():
    # 지금 칸이 강수확률만 높고 강수형태가 없으면 '지금' 칸 아이콘은 하늘이다 — 안내도 '지금 비'라고 하지 않는다.
    slots = (
        HourlyForecast(_at(11), 20.0, 70, 0, 4),
        HourlyForecast(_at(12), 20.0, 10, 0, 3),
        HourlyForecast(_at(13), 20.0, 80, 1, 4),
    )
    tip = weather_tip(slots, _at(11, 10), CFG)
    assert tip["text"] == "오후 1시부터 비 예보가 있어요. 우산 챙기세요."
