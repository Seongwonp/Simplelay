"""키오스크 평소 화면용 읽기 API — ``GET /ambient``·``GET /connections``.

인증은 다른 읽기 경로와 같다(main.py가 ``require_api_key``를 붙인다 --
키오스크는 루프백이라 키 없이 통과). 두 경로 모두 네트워크·장치 상태와
상관없이 200으로 답하고, 모르는 것은 모른다고 적는다.
설계와 문구 규칙은 docs/devlog/devlog_2026-09-30-ambient-api.md.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from functools import lru_cache

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from rpi.controller.models import ExecutionOutcome, outcome_of
from rpi.services.connections import (
    network_item,
    plug_item,
    press_item,
    press_link_from_frames,
    read_interface_state,
)
from rpi.services.weather.grid import latlon_to_grid
from rpi.services.weather import (
    AttentionItem,
    WeatherConfig,
    WeatherService,
    build_ambient,
)

from .deps import get_alert_store, get_appliance_registry, get_care_events, get_db, get_service

log = logging.getLogger(__name__)

router = APIRouter()


# ── 허브 위치(2026-09-30) ────────────────────────────────────────────────────
# 폰 앱 "현재 위치로 설정"이 저장한 위치가 환경 변수(LAT/LON·NX/NY)보다 우선한다.
# 5km 격자 예보라 소수 둘째 자리(약 1km)로 줄여 저장한다 -- 정밀 위치는 남기지 않는다.
HUB_LOCATION_KEY = "hub_location"
_memory_location: dict[str, float] = {}


def load_hub_location() -> tuple[float, float] | None:
    db = get_db()
    raw = db.load_setting(HUB_LOCATION_KEY) if db is not None else None
    if raw is None:
        if _memory_location:
            return _memory_location["lat"], _memory_location["lon"]
        return None
    try:
        doc = json.loads(raw)
        return float(doc["lat"]), float(doc["lon"])
    except (ValueError, KeyError, TypeError):
        log.warning("stored hub_location unreadable; ignored")
        return None


def save_hub_location(location: tuple[float, float] | None) -> None:
    db = get_db()
    value = None if location is None else json.dumps({"lat": location[0], "lon": location[1]})
    if db is not None:
        db.save_setting(HUB_LOCATION_KEY, value)
    _memory_location.clear()
    if location is not None:
        _memory_location.update(lat=location[0], lon=location[1])


def _weather_env() -> dict[str, str]:
    env = dict(os.environ)
    stored = load_hub_location()
    if stored is not None:
        env.pop("SIMPLELAY_WEATHER_NX", None)
        env.pop("SIMPLELAY_WEATHER_NY", None)
        env["SIMPLELAY_WEATHER_LAT"] = str(stored[0])
        env["SIMPLELAY_WEATHER_LON"] = str(stored[1])
    return env


@lru_cache(maxsize=1)
def get_weather_service() -> WeatherService:
    """날씨 캐시 싱글턴. 설정은 환경 변수에서 읽되, 앱이 저장한 허브 위치가 있으면
    그 위치가 격자를 정한다. 위치가 바뀌면 캐시를 비워 다시 만든다."""
    config = WeatherConfig.from_env(_weather_env())
    return WeatherService(config, store=get_db() if config.mode == "real" else None)


# ── 응답 모델 ────────────────────────────────────────────────────────────────


class AmbientTip(BaseModel):
    #: appliance | alert | rain | snow | heat | cold
    kind: str
    text: str
    #: attention | rain | snow | hot | cold
    icon: str


class AmbientHourly(BaseModel):
    time: str
    hour: int
    label: str
    #: clear | partly | cloudy | rain | snow
    icon: str
    temp: int | None = None
    pop: int | None = None
    #: 비·눈 칸 -- 키오스크가 강조색으로 칠한다.
    precip: bool = False


class AmbientResponse(BaseModel):
    greeting: str
    tip: AmbientTip | None = None
    hourly: list[AmbientHourly] = []
    #: kma | mock | none
    weather_source: str
    fetched_at: str | None = None
    stale: bool = False


class ConnectionItemModel(BaseModel):
    #: network | press | plug
    id: str
    #: ok | warn | error | not_installed | unknown
    state: str
    title: str
    message: str
    fixes: list[str] = []
    #: 확인용(real | mock | none | sysfs | server). 화면 문구로 쓰지 않는다.
    source: str


class ConnectionsResponse(BaseModel):
    items: list[ConnectionItemModel]
    checked_at: str


# ── /ambient ────────────────────────────────────────────────────────────────


#: 키오스크 안내 한 줄에 올리는 루틴 안내 종류(시연 v3 갭 S5) — 루틴의 ``announce``와 '알림만' 기록.
ROUTINE_TIP_KINDS = ("routine_announce", "routine_notice")
#: 루틴 안내를 안내 한 줄에 남겨 두는 시간. 시연 장면 하나(1~2분)를 넉넉히 덮는 값 -- 실측 아님.
ROUTINE_TIP_MINUTES = 10


def _routine_tip(care_events) -> AttentionItem | None:
    """가장 최근 루틴 안내(``ROUTINE_TIP_MINUTES`` 안). 폰 보호자 알림함에만 가던 것을 키오스크에도 보인다."""
    from .deps import get_clock  # noqa: PLC0415

    now = get_clock().now()
    for event in care_events.recent(limit=20):
        if event.kind not in ROUTINE_TIP_KINDS:
            continue
        if now - event.occurred_at > timedelta(minutes=ROUTINE_TIP_MINUTES):
            return None  # 최신순이라 더 볼 것이 없다
        return AttentionItem("routine", event.message, icon="notice")
    return None


def _subject_particle(name: str) -> str:
    """이/가 — 끝의 괄호 표기("(모의)")는 건너뛰고 마지막 한글 글자의 받침으로 고른다."""
    stem = name.strip()
    while stem.endswith(")") and "(" in stem:
        stem = stem[: stem.rindex("(")].rstrip()
    last = stem[-1:]
    if "가" <= last <= "힣":
        return "이" if (ord(last) - 0xAC00) % 28 else "가"
    return "이"


def _attention(service, registry, alerts, care_events=None) -> list[AttentionItem]:
    """확인이 필요한 일 -- 위험 소리 경보, 마지막 실행이 끝까지 되지 않은 가전, 최근 루틴 안내(순서대로).

    마지막 실행 실패는 다음 실행이 시작될 때까지 남는다(실행 기록에 시각이
    필요 없는 가장 단순한 규칙). 루틴 안내는 ``ROUTINE_TIP_MINUTES`` 동안만 남는다.
    """
    items: list[AttentionItem] = []
    try:
        if alerts.current().active:
            items.append(
                AttentionItem("alert", "위험할 수 있는 소리가 들렸어요. 주변을 확인해 주세요.")
            )
    except Exception:  # noqa: BLE001 - 안내 한 줄 때문에 화면 전체를 막지 않는다
        log.exception("alert state unavailable for ambient tip")
    try:
        snap = service.status()
        if not snap.running and snap.last_result is not None and outcome_of(
            snap.last_result
        ) in (ExecutionOutcome.FAILED, ExecutionOutcome.SAFETY_STOP):
            appliance = (
                registry.get(snap.last_appliance_id) if snap.last_appliance_id else None
            )
            name = appliance.name if appliance is not None else "가전"
            # 보냈지만 확인 못 한 명령(ThinQ ``unconfirmed``)은 실패가 아니다(계약 §3) — 레거시 상태는
            # FAILED로 접혀 있어 명령 경로 상태로 가른다. ``outcome_of``의 의미는 그대로 둔다.
            if getattr(snap, "last_command_status", None) == "unconfirmed":
                # 물리 실행이 연결 끊김으로 끝났으면(2026-10-15 G1) 바뀐 것이 아니라 눌렸는지를 모른다.
                text = (f"{name} — 눌렸는지 확인하지 못했어요 · 가전을 봐 주세요"
                        if getattr(snap, "last_route", None) == "physical"
                        else f"{name}{_subject_particle(name)} 바뀌었는지 확인하지 못했어요")
            else:
                text = f"{name} 작업이 멈췄어요 · 기계를 봐 주세요"
            items.append(AttentionItem("appliance", text))
    except Exception:  # noqa: BLE001
        log.exception("service status unavailable for ambient tip")
    if care_events is not None:
        try:
            tip = _routine_tip(care_events)
            if tip is not None:
                items.append(tip)
        except Exception:  # noqa: BLE001
            log.exception("care events unavailable for ambient tip")
    return items


@router.get("/ambient", response_model=AmbientResponse)
async def ambient(
    service=Depends(get_service),
    registry=Depends(get_appliance_registry),
    alerts=Depends(get_alert_store),
    weather: WeatherService = Depends(get_weather_service),
    care_events=Depends(get_care_events),
) -> dict:
    now = datetime.now(timezone.utc)
    # 기상청 호출(최대 timeout초)이 이벤트 루프를 막지 않게 스레드로 넘긴다.
    snapshot = await asyncio.to_thread(weather.snapshot, now)
    return build_ambient(now, snapshot, _attention(service, registry, alerts, care_events), weather.config)


# ── /connections ────────────────────────────────────────────────────────────


def _press_link(service) -> str:
    from rpi.services.link_tap import get_link_tap  # noqa: PLC0415

    try:
        controller = getattr(service, "_controller", None)
        # 링크 끊김·첫 연결 전(2026-10-06 인계 §6)이 프레임 기록보다 먼저다 — 지난 프레임이 정상이어도 지금은 못 누른다.
        link_status = getattr(controller, "link_status", None)
        if callable(link_status) and link_status().get("link_up") is False:
            return "down"
        tap = getattr(controller, "frame_tap", None) or get_link_tap()
        return press_link_from_frames(tap.frames(), time.monotonic_ns())
    except Exception:  # noqa: BLE001
        log.exception("press link state unavailable")
        return "never"


@router.get("/connections", response_model=ConnectionsResponse)
async def connections(
    service=Depends(get_service),
    weather: WeatherService = Depends(get_weather_service),
) -> dict:
    act_mode = os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower()
    interface = await asyncio.to_thread(read_interface_state)
    if weather.config.mode == "real":
        internet = "failed" if weather.last_error == "network" else "ok"
    else:
        internet = "unknown"
    link = _press_link(service) if act_mode == "uart" else "ok"
    items = [
        network_item(interface, internet),
        press_item(act_mode, link),
        plug_item(os.environ.get("SIMPLELAY_L3_MODE", "off")),
    ]
    return {
        "items": [item.to_dict() for item in items],
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


# ── 허브 위치 API ────────────────────────────────────────────────────────────


class HubLocationRequest(BaseModel):
    lat: float
    lon: float


class HubLocationResponse(BaseModel):
    #: app(폰에서 저장) | env(환경 변수) | none
    source: str
    lat: float | None = None
    lon: float | None = None
    nx: int | None = None
    ny: int | None = None


# 기상청 단기예보 격자가 덮는 대략의 범위(한반도 주변). 밖이면 예보를 받을 수 없다.
_LAT_RANGE = (32.0, 39.5)
_LON_RANGE = (124.0, 132.0)


@router.get("/hub/location", response_model=HubLocationResponse)
def get_hub_location() -> HubLocationResponse:
    stored = load_hub_location()
    if stored is not None:
        nx, ny = latlon_to_grid(*stored)
        return HubLocationResponse(source="app", lat=stored[0], lon=stored[1], nx=nx, ny=ny)
    cfg = WeatherConfig.from_env()
    if cfg.nx is not None and cfg.ny is not None:
        return HubLocationResponse(source="env", nx=cfg.nx, ny=cfg.ny)
    return HubLocationResponse(source="none")


@router.put("/hub/location", response_model=HubLocationResponse)
def put_hub_location(body: HubLocationRequest) -> HubLocationResponse:
    if not (_LAT_RANGE[0] <= body.lat <= _LAT_RANGE[1] and _LON_RANGE[0] <= body.lon <= _LON_RANGE[1]):
        raise HTTPException(
            status_code=422,
            detail="날씨 예보를 받을 수 없는 위치예요. 국내에서 다시 설정해 주세요.",
        )
    location = (round(body.lat, 2), round(body.lon, 2))
    save_hub_location(location)
    get_weather_service.cache_clear()
    nx, ny = latlon_to_grid(*location)
    return HubLocationResponse(source="app", lat=location[0], lon=location[1], nx=nx, ny=ny)


@router.delete("/hub/location", response_model=HubLocationResponse)
def delete_hub_location() -> HubLocationResponse:
    save_hub_location(None)
    get_weather_service.cache_clear()
    return get_hub_location()
