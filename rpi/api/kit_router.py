"""누름 장치 세트 API.

  GET  /kit        세트를 찾았나, 모션·콘센트·원점 상태, 맡은 가전
  POST /kit/bind   세트를 가전에 잇기 {appliance_id, confirm_release}

'찾았다'는 설정된 링크의 세트가 ``kit_id``로 답했다는 뜻이다 — 네트워크를 뒤지지 않는다.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from rpi.commands import ControlRoute
from rpi.josa import quoted_josa
from rpi.services.control_arbiter import ControlFaultedError

from .deps import get_appliance_registry, get_service

router = APIRouter()

KIT_NOT_FOUND_DETAIL = "누름 장치 세트를 찾지 못했어요. 세트 전원과 연결을 확인해 주세요."
KIT_OLD_DETAIL = "누름 장치 세트의 프로그램이 예전 버전이에요. 본체와 같은 버전으로 올려 주세요."
KIT_BUSY_DETAIL = "누름 장치가 일하는 중이에요. 끝난 뒤 다시 해 주세요."


class KitBindRequest(BaseModel):
    appliance_id: str = Field(min_length=1, max_length=128)
    #: 세트가 다른 가전을 맡고 있을 때, 그 연결을 풀어도 된다고 사람이 확인했나.
    confirm_release: bool = False


def _report(service, status: dict | None) -> dict | None:
    """링크 보고를 공개 필드로. ``kit_id``가 없으면 찾은 것이 아니다."""
    if status is None or not status.get("kit_id"):
        return None
    return {key: status.get(key) for key in (
        "kit_id", "motion", "motion_present", "outlet", "outlet_present", "estop_button")} | {
            "homed": status.get("motion_homed"), "stale": status.get("stale") is True}


def kit_view(service, registry) -> dict:
    status = service.kit_status()
    report = _report(service, status)
    found = report is not None
    bound = service.kit_bound(report["kit_id"] if found else None)
    appliance = registry.get(bound.appliance_id) if bound.appliance_id else None
    reason = None
    if not found:
        reason = KIT_OLD_DETAIL if service.kit_old_executor() else KIT_NOT_FOUND_DETAIL
    return {
        "found": found,
        "kit_id": report["kit_id"] if found else None,
        "motion": report["motion"] if found else None,
        "motion_present": report["motion_present"] is True if found else False,
        "outlet": report["outlet"] if found else None,
        "outlet_present": report["outlet_present"] is True if found else False,
        "estop_button": report["estop_button"] if found else None,
        "homed": report["homed"] if found else None,
        "stale": report["stale"] if found else False,
        "bound_appliance": bound.appliance_id if appliance is not None else None,
        "name": appliance.name if appliance is not None else None,
        "verified": bound.verified if appliance is not None else False,
        "reason": reason,
    }


@router.get("/kit")
def get_kit(service=Depends(get_service), registry=Depends(get_appliance_registry)) -> dict:
    return kit_view(service, registry)


@router.post("/kit/bind")
def bind_kit(body: KitBindRequest, service=Depends(get_service), registry=Depends(get_appliance_registry)) -> dict:
    appliance = registry.get(body.appliance_id)
    if appliance is None:
        raise HTTPException(status_code=404, detail="appliance not found")
    if appliance.control_path is not ControlRoute.PHYSICAL:
        raise HTTPException(status_code=422, detail="LG 가전은 누름 장치 세트를 쓰지 않아요")
    report = _report(service, service.kit_status())
    if report is None:
        raise HTTPException(status_code=409,
                            detail=KIT_OLD_DETAIL if service.kit_old_executor() else KIT_NOT_FOUND_DETAIL)
    kit_id = report["kit_id"]
    current = service.kit_bound(kit_id)
    holder = registry.get(current.appliance_id) if current.appliance_id else None
    if holder is not None and holder.appliance_id != appliance.appliance_id and not body.confirm_release:
        raise HTTPException(status_code=409, detail=f"이 세트는 {holder.name}에 연결돼 있어요. 연결을 풀면 "
                                                    f"{quoted_josa(holder.name, '은', '는')} 다시 연결할 때까지 쓸 수 없어요.")
    try:
        service.bind_kit(kit_id, appliance.appliance_id)
    except ControlFaultedError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=KIT_BUSY_DETAIL) from exc
    return kit_view(service, registry)
