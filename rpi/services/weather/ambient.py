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


def current_slot(
    slots: Sequence[HourlyForecast], now: datetime
) -> HourlyForecast | None:
    """'지금' 칸 하나 — 키오스크 예보 줄 '지금' 칸과 날씨 안내 문장이 **같은 정의**를 쓴다(평가 15차 10/18).

    지금 시각이 든 1시간 칸(지난 정시 칸, 예: 14:21이면 14시 칸)을 먼저 쓴다. 그 칸이 예보에 없으면 앞뒤 30분 안의
    칸만(14:35면 15시 칸). 그 밖은 None — 39분 뒤 15시 칸을 '지금'으로 그리면 오후 2:21에 '지금' 칸은 비인데 안내는
    '오후 3시부터 비'라고 말해 앞뒤가 맞지 않았다(15차 평가 실패널). 기온이 없는 칸은 '지금' 칸으로 쓰지 않는다.
    """
    now = now.astimezone(KST)
    hour_mark = now.replace(minute=0, second=0, microsecond=0)
    best = None
    for slot in slots:
        if slot.tmp is None:
            continue
        at = slot.at.astimezone(KST)
        if at == hour_mark:
            return slot
        gap = abs((at - now).total_seconds())
        if gap > 30 * 60:
            continue
        if best is None or gap < best[0]:
            best = (gap, slot)
    return None if best is None else best[1]


def weather_tip(
    slots: Sequence[HourlyForecast], now: datetime, config: WeatherConfig
) -> dict | None:
    """비·눈 → 더위 → 추위 순으로 하나만.

    '지금'은 [current_slot]과 같은 칸이다(평가 15차 10/18). 그 칸에 비·눈(강수형태)이 있으면 '지금 비가 와요',
    그 밖은 '오후 3시부터…'. 지금 칸은 강수형태만 본다 — 키오스크 '지금' 칸 아이콘(하늘 상태, 강수확률은 안 씀)과
    같은 기준이라 '지금 비가 와요' 옆 '지금' 칸이 구름으로 그려지지 않는다. 다만 지금 칸이 지금보다 뒤의 정시 칸이면 그 칸의
    강수확률 비는 '○시부터 비 예보'로 말한다(검토 10/19 #12). 지금 칸이 아닌 지난 정시 칸(기온 없음)은
    지금이라고도 앞으로라고도 말하지 않는다.
    """
    now = now.astimezone(KST)
    window = _window(slots, now, config.tip_hours)
    if not window:
        return None
    current = current_slot(slots, now)

    for slot in window:
        at = slot.at.astimezone(KST)
        is_now = slot is current
        if not is_now and at <= now:
            continue
        kind = slot.precipitation
        # 지금 칸이 지금보다 뒤의 정시 칸(14:35의 15시 칸)이면 그 칸의 강수확률 비도 '○시부터 비 예보'로 말한다
        # (검토 10/19 #12 — 예전에는 지금 칸이라 보지 않고 앞으로 칸도 아니라 아무 데서도 말하지 않았다).
        # '지금 비가 와요'는 종전대로 강수형태가 있을 때만이다(지금 칸 아이콘과 같은 기준).
        says_now = is_now and kind is not None
        if kind is None and (not is_now or at > now) and slot.pop is not None and slot.pop >= config.rain_pop:
            kind = "rain"
        if kind is None:
            continue
        if kind == "snow":
            text = (
                "지금 눈이 와요. 길이 미끄러울 수 있어요."
                if says_now
                else f"{_hour_label(at, now)}부터 눈 예보가 있어요. 길이 미끄러울 수 있어요."
            )
        else:
            text = (
                "지금 비가 와요. 나갈 때 우산 챙기세요."
                if says_now
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


def now_slot(
    slots: Sequence[HourlyForecast], now: datetime, config: WeatherConfig
) -> dict | None:
    """지금 날씨 한 칸 — 키오스크 예보 줄 맨 앞 '지금'(10/18 사용자 요청).

    3시간 칸(``hourly``)은 다음 경계부터라 하루 절반쯤은 지금 값이 없다. 예보의 1시간 칸 중 [current_slot]
    (지난 정시 칸, 없으면 앞뒤 30분 안)만 쓴다 — 날씨 안내 문장과 같은 '지금'이다(평가 15차 10/18, 예전 앞뒤 90분은
    오후 2:21에 3시 칸을 '지금'으로 그렸다). 없으면 None(추측 값을 만들지 않는다 — 키오스크는 '지금' 칸을 두지 않는다).
    """
    slot = current_slot(slots, now)
    if slot is None:
        return None
    at = slot.at.astimezone(KST)
    # 지금 칸은 지금 하늘만 — 강수확률만 높은 칸을 비 아이콘으로 그리면 "지금 비가 오나?"로 읽힌다(11차 평가).
    # 비·눈 아이콘은 강수형태(pty)가 있을 때만. 비 예보는 알림 카드가 말한다.
    return {"time": at.isoformat(), "hour": at.hour, "icon": slot.icon(rain_pop=101), "temp": round(slot.tmp)}


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
        "now": now_slot(slots, now, config) if usable else None,
        "weather_source": weather.source,
        "fetched_at": weather.fetched_at.isoformat() if weather.fetched_at else None,
        "stale": bool(weather.stale),
    }
