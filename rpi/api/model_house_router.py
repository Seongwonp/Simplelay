"""집 모형(ESP8266) 연동 — 본체가 정한 모형 상태를 모형이 읽어 간다.

모형은 같은 망에서 ``GET /model/state``를 주기적으로 읽어 조명·선풍기·실링팬·LCD 두 줄을 그대로 맞춘다.
본체가 모형을 찾아가지 않으므로 모형 주소가 바뀌어도 된다.

**무장(arm)한 동안만 사람 감지를 따른다.** 시연 중에는 관객이 카메라 앞을 오가므로, 발표 슬라이드가 그 장에
들어올 때 ``POST /model/arm``으로 정한 시간만 켠다. 무장 전·만료 뒤에는 모두 꺼진 대기 상태다.
사람 있음/없음은 키오스크와 같은 판단(``/presence/room``)이며, 실행·승인의 근거가 아니다 — 모형은 실제 가전이 아니다.
LCD는 16x2 영문 문자 LCD라 ASCII만 보낸다.
"""

from __future__ import annotations

import threading
import time

from fastapi import APIRouter
from pydantic import BaseModel, Field

router = APIRouter(prefix="/model", tags=["model-house"])

#: 한 번 무장의 상한(s). 슬라이드를 넘기지 않고 오래 두어도 저절로 풀린다.
MAX_ARM_S = 600.0
LCD_WIDTH = 16

_lock = threading.Lock()
_armed_until = 0.0


class ArmRequest(BaseModel):
    seconds: float = Field(default=120.0, gt=0, le=MAX_ARM_S)


class ModelState(BaseModel):
    armed: bool
    armed_left_s: int
    presence: str
    light: bool
    fan: bool
    ceiling_fan: bool
    lcd1: str
    lcd2: str


def _ascii(text: str) -> str:
    return "".join(ch if 32 <= ord(ch) < 127 else " " for ch in text)[:LCD_WIDTH]


def _presence_state() -> str:
    from rpi.api.room_presence_wiring import get_room_presence  # noqa: PLC0415

    room = get_room_presence()
    return "unknown" if room is None else room.snapshot().state


def model_state(now: float | None = None) -> ModelState:
    now = time.monotonic() if now is None else now
    with _lock:
        left = max(0.0, _armed_until - now)
    presence = _presence_state()
    if left <= 0:
        return ModelState(armed=False, armed_left_s=0, presence=presence, light=False, fan=False,
                          ceiling_fan=False, lcd1=_ascii("SimpleLay"), lcd2=_ascii("Standby"))
    here = presence == "present"
    return ModelState(
        armed=True, armed_left_s=int(left), presence=presence, light=here, fan=here, ceiling_fan=here,
        lcd1=_ascii("Welcome home!" if here else "SimpleLay"),
        lcd2=_ascii("Lights & fan ON" if here else "Waiting for you"),
    )


@router.get("/state", response_model=ModelState)
def get_state() -> ModelState:
    return model_state()


@router.post("/arm", response_model=ModelState)
def arm(body: ArmRequest | None = None) -> ModelState:
    global _armed_until
    seconds = (body or ArmRequest()).seconds
    with _lock:
        _armed_until = time.monotonic() + seconds
    return model_state()


@router.post("/disarm", response_model=ModelState)
def disarm() -> ModelState:
    global _armed_until
    with _lock:
        _armed_until = 0.0
    return model_state()
