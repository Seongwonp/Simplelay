"""키오스크 평소 화면의 인사말·안내 한 줄·시간대 예보 4칸 — 순수 함수.

UI 확정 §3-1: 안내는 한 번에 하나. 우선순위는 확인이 필요한 가전 → 날씨 →
(안내 없음, 인사말만). 인터넷이 없거나 예보가 오래됐으면 날씨는 빠진다.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Sequence

from .config import WeatherConfig
from .kma import KST, HourlyForecast
from .service import WeatherSnapshot

HOURLY_SLOTS = 4
HOURLY_STEP_HOURS = 3


@dataclass(frozen=True)
class AttentionItem:
    """확인이 필요한 일 하나. ``text``는 사용자에게 그대로 보이는 문장이다."""

    kind: str  # "appliance" | "alert" | "routine"(루틴 안내, 2026-10-06)
    text: str
    icon: str = "attention"


def greeting(now: datetime) -> str:
    hour = now.astimezone(KST).hour
    if 5 <= hour < 11:
        return "좋은 아침이에요."
    if 11 <= hour < 17:
        return "좋은 오후예요."
    if 17 <= hour < 21:
        return "편안한 저녁 보내세요."
    return "편안한 밤 보내세요."


def _hour_label(at: datetime, now: datetime) -> str:
    h = at.hour
    if h == 0:
        text = "밤 12시"
    elif h < 12:
        text = f"오전 {h}시"
    elif h == 12:
        text = "낮 12시"
    else:
        text = f"오후 {h - 12}시"
    days = (at.date() - now.date()).days
    if days == 1:
        return f"내일 {text}"
    if days >= 2:
        return f"모레 {text}"
    return text


def _window(slots: Sequence[HourlyForecast], now: datetime, hours: int):
    start = now.replace(minute=0, second=0, microsecond=0)
    end = now + timedelta(hours=hours)
    return [s for s in slots if start <= s.at.astimezone(KST) < end]


def weather_tip(
    slots: Sequence[HourlyForecast], now: datetime, config: WeatherConfig
) -> dict | None:
    """비·눈 → 더위 → 추위 순으로 하나만."""
    now = now.astimezone(KST)
    window = _window(slots, now, config.tip_hours)
    if not window:
        return None

    for slot in window:
        kind = slot.precipitation
        if kind is None and slot.pop is not None and slot.pop >= config.rain_pop:
            kind = "rain"
        if kind is None:
            continue
        at = slot.at.astimezone(KST)
        current = at <= now
        if kind == "snow":
            text = (
                "지금 눈 소식이 있어요. 길이 미끄러울 수 있어요."
                if current
                else f"{_hour_label(at, now)}부터 눈 예보가 있어요. 길이 미끄러울 수 있어요."
            )
        else:
            text = (
                "지금 비 소식이 있어요. 나갈 때 우산 챙기세요."
                if current
                else f"{_hour_label(at, now)}부터 비 예보가 있어요. 우산 챙기세요."
            )
        return {"kind": kind, "text": text, "icon": kind}

    temps = [s.tmp for s in window if s.tmp is not None]
    if temps:
        hottest, coldest = max(temps), min(temps)
        if hottest >= config.heat_c:
            return {
                "kind": "heat",
                "text": f"최고 {round(hottest)}도까지 올라 더워요. 물을 자주 드세요.",
                "icon": "hot",
            }
        if coldest <= config.cold_c:
            return {
                "kind": "cold",
                "text": f"최저 {round(coldest)}도까지 내려가 추워요. 따뜻하게 입으세요.",
                "icon": "cold",
            }
    return None


def hourly_strip(
    slots: Sequence[HourlyForecast], now: datetime, config: WeatherConfig
) -> list[dict]:
    """다음 3시간 단위 정시부터 4칸(예: 8:20이면 9·12·15·18시)."""
    now = now.astimezone(KST)
    start = now.replace(minute=0, second=0, microsecond=0)
    if start < now:
        start += timedelta(hours=1)
    start += timedelta(hours=(-start.hour) % HOURLY_STEP_HOURS)
    by_time = {s.at.astimezone(KST): s for s in slots}
    out: list[dict] = []
    at = start
    for _ in range(HOURLY_SLOTS * 2):  # 빈 칸이 있으면 조금 더 뒤까지 찾는다
        if len(out) == HOURLY_SLOTS:
            break
        slot = by_time.get(at)
        if slot is not None:
            icon = slot.icon(config.rain_pop)
            out.append(
                {
                    "time": at.isoformat(),
                    "hour": at.hour,
                    "label": f"{at.hour}시",
                    "icon": icon,
                    "temp": None if slot.tmp is None else round(slot.tmp),
                    "pop": slot.pop,
                    "precip": icon in ("rain", "snow"),
                }
            )
        at += timedelta(hours=HOURLY_STEP_HOURS)
    return out


def build_ambient(
    now: datetime,
    weather: WeatherSnapshot,
    attention: Sequence[AttentionItem],
    config: WeatherConfig,
) -> dict:
    """GET /ambient 본문."""
    now = now.astimezone(KST)
    usable = weather.usable
    slots = weather.forecast.slots if usable and weather.forecast else ()

    tip = None
    if attention:
        first = attention[0]
        tip = {"kind": first.kind, "text": first.text, "icon": first.icon}
    elif usable:
        tip = weather_tip(slots, now, config)

    return {
        "greeting": greeting(now),
        "tip": tip,
        "hourly": hourly_strip(slots, now, config) if usable else [],
        "weather_source": weather.source,
        "fetched_at": weather.fetched_at.isoformat() if weather.fetched_at else None,
        "stale": bool(weather.stale),
    }
