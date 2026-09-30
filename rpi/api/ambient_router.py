"""키오스크 평소 화면용 읽기 API — ``GET /ambient``·``GET /connections``.

인증은 다른 읽기 경로와 같다(main.py가 ``require_api_key``를 붙인다 --
키오스크는 루프백이라 키 없이 통과). 두 경로 모두 네트워크·장치 상태와
상관없이 200으로 답하고, 모르는 것은 모른다고 적는다.
설계와 문구 규칙은 docs/devlog_2026-09-30-ambient-api.md.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from datetime import datetime, timezone
from functools import lru_cache

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from rpi.controller.models import ExecutionOutcome, outcome_of
from rpi.services.connections import (
    network_item,
    plug_item,
    press_item,
    press_link_from_frames,
    read_interface_state,
)
from rpi.services.weather import (
    AttentionItem,
    WeatherConfig,
    WeatherService,
    build_ambient,
)

from .deps import get_alert_store, get_appliance_registry, get_db, get_service

log = logging.getLogger(__name__)

router = APIRouter()


@lru_cache(maxsize=1)
def get_weather_service() -> WeatherService:
    """날씨 캐시 싱글턴. 설정은 기동 때 환경 변수에서 한 번 읽는다."""
    config = WeatherConfig.from_env()
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


def _attention(service, registry, alerts) -> list[AttentionItem]:
    """확인이 필요한 일 -- 위험 소리 경보, 마지막 실행이 끝까지 되지 않은 가전.

    마지막 실행 실패는 다음 실행이 시작될 때까지 남는다(실행 기록에 시각이
    필요 없는 가장 단순한 규칙).
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
            items.append(
                AttentionItem(
                    "appliance",
                    f"{name} 확인이 필요해요. 마지막 작업이 끝까지 되지 않았어요.",
                )
            )
    except Exception:  # noqa: BLE001
        log.exception("service status unavailable for ambient tip")
    return items


@router.get("/ambient", response_model=AmbientResponse)
async def ambient(
    service=Depends(get_service),
    registry=Depends(get_appliance_registry),
    alerts=Depends(get_alert_store),
    weather: WeatherService = Depends(get_weather_service),
) -> dict:
    now = datetime.now(timezone.utc)
    # 기상청 호출(최대 timeout초)이 이벤트 루프를 막지 않게 스레드로 넘긴다.
    snapshot = await asyncio.to_thread(weather.snapshot, now)
    return build_ambient(now, snapshot, _attention(service, registry, alerts), weather.config)


# ── /connections ────────────────────────────────────────────────────────────


def _press_link(service) -> str:
    from rpi.services.link_tap import get_link_tap  # noqa: PLC0415

    try:
        controller = getattr(service, "_controller", None)
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
