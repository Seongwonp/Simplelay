"""가전 추가 5단계용 API — 사진 매핑(②~④)·확인 주행(⑤) (2026-09-30). **실물 미검증.**

  GET  /mapping/frame                         프레임 치수·원점 오프셋·소프트 리밋 설정 상태
  POST /appliances/{id}/mapping/preview       사진 px → mm 미리보기(저장 안 함)
  PUT  /appliances/{id}/mapping               같은 계산 + 저장(버튼 mm·정지 버튼·횟수·보관 위치)
  POST /appliances/{id}/verify-pass           확인 주행 시작(누르지 않고 Z를 올린 채 지나감)
  GET  /appliances/{id}/verify-pass           마지막 확인 주행 상태(버튼별)

사진 파일은 받지 않는다 — 사진 크기와 짚은 좌표만 받는다. 계산·거절 규칙은
``rpi/services/panel_mapping.py``, 정지·보관 검증은 ``rpi/services/stop_park.py``.
"""

from __future__ import annotations

import asyncio
import math
from dataclasses import replace

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator

from rpi.commands import ControlRoute
from rpi.services.appliance_registry import RevisionConflictError
from rpi.services.panel_mapping import (
    MappingInput,
    MappingRejected,
    compute_mapping,
    frame_config,
    verify_targets,
)
from rpi.services.stop_park import STOP_PRESSES_RANGE, _soft_limits, validate_stop_park
from rpi.services.verify_pass import VerifyPassUnavailable, get_verify_runner

from .deps import get_appliance_registry, get_service

router = APIRouter()


def _pair(value: list[float] | None, label: str) -> list[float] | None:
    if value is None:
        return None
    if len(value) != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in value):
        raise ValueError(f"{label} must be [x, y] finite numbers")
    return [float(value[0]), float(value[1])]


class ExtraPoint(BaseModel):
    px: list[float]
    mm: list[float]

    @field_validator("px", "mm")
    @classmethod
    def two_numbers(cls, v: list[float]) -> list[float]:
        return _pair(v, "point")  # type: ignore[return-value]


class MappingRequest(BaseModel):
    """사진 매핑 요청. 좌표는 모두 **사진 px**(왼쪽 위 원점, 아래로 +y)."""

    photo_width: int = Field(ge=16, le=20000)
    photo_height: int = Field(ge=16, le=20000)
    #: 프레임 모서리 4점 — 왼쪽 위 → 오른쪽 위 → 오른쪽 아래 → 왼쪽 아래.
    corners_px: list[list[float]]
    #: 프레임 안쪽 치수(mm). 없으면 서버 설정(SIMPLELAY_FRAME_W_MM·_H_MM).
    frame_w_mm: float | None = Field(default=None, gt=0, le=2000)
    frame_h_mm: float | None = Field(default=None, gt=0, le=2000)
    #: 버튼 id → 사진 px(버튼 중심).
    buttons_px: dict[str, list[float]] = {}
    #: 정지(취소) 버튼 id. 사진 위치는 buttons_px 또는 stop_px로 준다.
    stop_button: str | None = None
    stop_px: list[float] | None = None
    stop_presses: int = 1
    #: 보관 위치(사진 px).
    park_px: list[float] | None = None
    #: 선택 기준점(사진 px ↔ mm). 있으면 잔차 검증을 한다.
    extra_points: list[ExtraPoint] = []
    expected_revision: int | None = None

    @field_validator("corners_px")
    @classmethod
    def four_corners(cls, v: list[list[float]]) -> list[list[float]]:
        if len(v) != 4:
            raise ValueError("corners_px needs exactly 4 points (TL, TR, BR, BL)")
        return [_pair(p, "corner") for p in v]  # type: ignore[misc]

    @field_validator("buttons_px")
    @classmethod
    def button_points(cls, v: dict[str, list[float]]) -> dict[str, list[float]]:
        if len(v) > 60:
            raise ValueError("too many buttons")
        return {k.strip(): _pair(p, f"button {k}") for k, p in v.items()}  # type: ignore[misc]

    @field_validator("stop_px", "park_px")
    @classmethod
    def optional_point(cls, v: list[float] | None) -> list[float] | None:
        return _pair(v, "point")

    @field_validator("stop_presses")
    @classmethod
    def presses_range(cls, v: int) -> int:
        if not STOP_PRESSES_RANGE[0] <= v <= STOP_PRESSES_RANGE[1]:
            raise ValueError(f"stop_presses must be {STOP_PRESSES_RANGE[0]}..{STOP_PRESSES_RANGE[1]}")
        return v


class VerifyPassRequest(BaseModel):
    #: 확인할 버튼 id 순서. 없으면 보정된 버튼 전부(등록 순서) → 보관 위치.
    button_ids: list[str] | None = None


@router.get("/mapping/frame")
def mapping_frame() -> dict:
    limits = _soft_limits()
    return {
        **frame_config().as_dict(),
        "soft_limits": None if limits is None else {
            "x_min_mm": limits.x_min_mm, "x_max_mm": limits.x_max_mm,
            "y_min_mm": limits.y_min_mm, "y_max_mm": limits.y_max_mm},
        "corner_order": ["왼쪽 위", "오른쪽 위", "오른쪽 아래", "왼쪽 아래"],
        "note": "사진 파일은 서버에 올리지 않아요. 사진 크기와 짚은 좌표만 보내 주세요.",
    }


def _prepare(appliance_id: str, body: MappingRequest, registry):
    appliance = registry.get(appliance_id)
    if appliance is None:
        raise HTTPException(status_code=404, detail="appliance not found")
    if appliance.control_path is ControlRoute.THINQ:
        raise HTTPException(status_code=422, detail="ThinQ 가전은 누를 조작부가 없어 사진 매핑을 하지 않아요")
    known = {b.id for b in appliance.buttons}
    buttons_px = dict(body.buttons_px)
    if body.stop_button is not None:
        if body.stop_button not in known:
            raise HTTPException(status_code=422, detail=f"정지 버튼 '{body.stop_button}'이 이 가전에 없어요")
        if body.stop_px is not None:
            buttons_px[body.stop_button] = body.stop_px
        if body.stop_button not in buttons_px:
            raise HTTPException(status_code=422, detail="정지 버튼 위치를 사진에서 짚어 주세요")
    unknown = sorted(set(buttons_px) - known)
    if unknown:
        raise HTTPException(status_code=422, detail=f"이 가전에 없는 버튼입니다: {', '.join(unknown)}")
    data = MappingInput(
        photo_w=body.photo_width, photo_h=body.photo_height,
        corners_px=tuple(tuple(p) for p in body.corners_px),  # type: ignore[misc]
        frame=frame_config(body.frame_w_mm, body.frame_h_mm),
        buttons_px={k: tuple(v) for k, v in buttons_px.items()},  # type: ignore[misc]
        park_px=tuple(body.park_px) if body.park_px else None,  # type: ignore[arg-type]
        extra_points=tuple((tuple(p.px), tuple(p.mm)) for p in body.extra_points),  # type: ignore[misc]
    )
    try:
        result = compute_mapping(data)
    except MappingRejected as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    candidate = replace(
        appliance,
        buttons=tuple(replace(b, x_mm=result.buttons_mm[b.id][0], y_mm=result.buttons_mm[b.id][1])
                      if b.id in result.buttons_mm else replace(b, x_mm=None, y_mm=None)
                      for b in appliance.buttons),
        stop_button=body.stop_button,
        stop_presses=body.stop_presses,
        park_xy=result.park_mm,
        panel_mapping=result.record,
    )
    try:
        check = validate_stop_park(candidate)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return appliance, candidate, result, check


def _response(candidate, result, check, *, saved: bool, appliance_response=None) -> dict:
    return {
        "saved": saved,
        "version": result.version,
        "quality": result.quality,
        "frame": result.record["frame"],
        "buttons_mm": {k: list(v) for k, v in result.buttons_mm.items()},
        "stop_button": candidate.stop_button,
        "stop_presses": candidate.stop_presses,
        "park_xy": None if result.park_mm is None else list(result.park_mm),
        "stop_park_check": check.as_dict(),
        "unmapped_buttons": [b.id for b in candidate.buttons if not b.calibrated],
        "appliance": appliance_response,
    }


@router.post("/appliances/{appliance_id}/mapping/preview")
def mapping_preview(appliance_id: str, body: MappingRequest, registry=Depends(get_appliance_registry)) -> dict:
    _, candidate, result, check = _prepare(appliance_id, body, registry)
    return _response(candidate, result, check, saved=False)


@router.put("/appliances/{appliance_id}/mapping")
def mapping_save(appliance_id: str, body: MappingRequest, registry=Depends(get_appliance_registry)) -> dict:
    from .router import _to_appliance_response  # noqa: PLC0415 - 같은 응답 모양

    _, candidate, result, check = _prepare(appliance_id, body, registry)
    try:
        saved = registry.apply_calibration(
            appliance_id,
            version=result.version,
            coords=result.buttons_mm,
            expected_revision=body.expected_revision,
            stop_park={"stop_button": candidate.stop_button, "stop_presses": candidate.stop_presses,
                       "park_xy": candidate.park_xy, "panel_mapping": candidate.panel_mapping},
        )
    except RevisionConflictError as exc:
        raise HTTPException(status_code=409, detail="다른 기기에서 먼저 변경되었어요",
                            headers={"X-Current-Revision": str(exc.current_revision)}) from exc
    except LookupError as exc:
        raise HTTPException(status_code=404, detail="appliance not found") from exc
    return _response(saved, result, check, saved=True,
                     appliance_response=_to_appliance_response(saved).model_dump())


@router.post("/appliances/{appliance_id}/verify-pass", status_code=202)
async def verify_pass_start(appliance_id: str, body: VerifyPassRequest | None = None,
                            registry=Depends(get_appliance_registry), service=Depends(get_service)) -> dict:
    # 가전 목록 잠금은 등록·보정의 DB 쓰기 동안 잡힌다 — 이벤트 루프에서 기다리지 않는다(2026-10-14 HIGH 재확인 H-R2).
    appliance = await asyncio.to_thread(registry.get, appliance_id)
    if appliance is None:
        raise HTTPException(status_code=404, detail="appliance not found")
    try:
        targets = verify_targets(appliance, body.button_ids if body else None)
    except MappingRejected as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if service.status().running:
        raise HTTPException(status_code=409, detail="다른 일을 하는 중이에요. 끝난 뒤 다시 해 주세요.")
    if not service.runs_locally(appliance_id):
        raise HTTPException(status_code=409, detail="이 가전은 이 허브의 갠트리에 연결되지 않았어요")
    try:
        # 실행기 최초 생성도 스레드 안에서(인자로 부르면 루프에서 만든다 — 지금은 메모리뿐이지만 같은 모양을 남기지 않는다)
        return await asyncio.to_thread(lambda: get_verify_runner().start(appliance_id, targets, service._controller))
    except VerifyPassUnavailable as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/appliances/{appliance_id}/verify-pass")
def verify_pass_status(appliance_id: str) -> dict:
    doc = get_verify_runner().status(appliance_id)
    if doc is None:
        raise HTTPException(status_code=404, detail="확인 주행 기록이 없어요")
    return doc
