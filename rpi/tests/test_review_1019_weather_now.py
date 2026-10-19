"""검토 10/19(클라우드) #12 — 날씨 '지금' 칸이 지금보다 뒤의 정시 칸(14:35의 15시 칸)이면 그 칸의 강수확률 비 예보를
아무 데서도 말하지 않던 것. 그 칸이 지금보다 뒤면 '○시부터 비 예보'로 말한다(지금 칸 아이콘은 종전대로 강수형태만).
"""

from __future__ import annotations

import dataclasses
from datetime import datetime

from rpi.services.weather import HourlyForecast, WeatherConfig, weather_tip
from rpi.services.weather import kma

CFG = WeatherConfig(mode="real", service_key="K", nx=60, ny=127)
KST = kma.KST


def _slot(hour, **kw):
    return HourlyForecast(at=datetime(2026, 10, 19, hour, tzinfo=KST), tmp=18.0, **kw)


def test_pop_rain_in_a_future_now_slot_is_announced_from_that_hour():
    # 14:35, 14시 칸 없음 → 15시 칸(25분 뒤)이 '지금'. 강수형태 없음·강수확률 80%, 그 뒤로는 비 없음.
    slots = [_slot(15, pop=80, pty=0)] + [_slot(h, pop=10, pty=0) for h in range(16, 24)]
    tip = weather_tip(slots, datetime(2026, 10, 19, 14, 35, tzinfo=KST), CFG)
    assert tip is not None and tip["kind"] == "rain"
    assert tip["text"] == "오후 3시부터 비 예보가 있어요. 우산 챙기세요."


def test_pop_rain_in_a_past_hour_now_slot_is_still_not_called_rain():
    # 14:20, 지금 칸은 14시(지난 정시) — 강수확률만 높으면 비라고 하지 않는다(종전 그대로).
    slots = [_slot(14, pop=80, pty=0)] + [_slot(h, pop=10, pty=0) for h in range(15, 24)]
    tip = weather_tip(slots, datetime(2026, 10, 19, 14, 20, tzinfo=KST), CFG)
    assert tip is None or tip["kind"] != "rain"


def test_precipitation_in_a_future_now_slot_still_says_raining_now():
    slots = [dataclasses.replace(_slot(15, pop=80), pty=1)] + [_slot(h, pop=10, pty=0) for h in range(16, 24)]
    tip = weather_tip(slots, datetime(2026, 10, 19, 14, 40, tzinfo=KST), CFG)
    assert tip["text"] == "지금 비가 와요. 나갈 때 우산 챙기세요."
