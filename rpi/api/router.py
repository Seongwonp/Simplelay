import asyncio

from fastapi import APIRouter, Depends, HTTPException

from rpi.controller import ExecutionResult
from rpi.intent.rules import UnknownIntentError
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError

from rpi.services import DangerAlertStore

from .deps import get_alert_store, get_service, get_suggestion_service
from .schemas import (
    AlertResponse,
    ApproveResponse,
    ButtonStep,
    DndRequest,
    ExecuteButtonsRequest,
    ExecuteForApplianceRequest,
    ExecuteRequest,
    ExecuteResponse,
    OkResponse,
    SensorResponse,
    StatusResponse,
    SuggestionResponse,
)
from .service import LlmNotConfiguredError, SimpleLayService

router = APIRouter()


def _to_steps(result: ExecutionResult) -> list[ButtonStep]:
    return [
        ButtonStep(button=b.button, success=b.status.value == "succeeded")
        for b in result.buttons
    ]


@router.post("/execute", response_model=ExecuteResponse)
async def execute(
    body: ExecuteRequest,
    service: SimpleLayService = Depends(get_service),
) -> ExecuteResponse:
    try:
        result = await asyncio.to_thread(service.execute_purpose, body.text)
    except UnknownIntentError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return ExecuteResponse(status=result.status.value, buttons=_to_steps(result))


@router.post("/execute-buttons", response_model=ExecuteResponse)
async def execute_buttons(
    body: ExecuteButtonsRequest,
    service: SimpleLayService = Depends(get_service),
) -> ExecuteResponse:
    # 의도 해석 규칙이 없는 사용자 정의 가전용 — 목적 문자열 없이 버튼을 직접 실행.
    try:
        result = await asyncio.to_thread(service.execute_buttons, tuple(body.buttons))
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return ExecuteResponse(status=result.status.value, buttons=_to_steps(result))


@router.post("/execute-for-appliance", response_model=ExecuteResponse)
async def execute_for_appliance(
    body: ExecuteForApplianceRequest,
    service: SimpleLayService = Depends(get_service),
) -> ExecuteResponse:
    # 사용자 정의 가전용 음성 명령 — 요청에 실린 버튼 어휘를 기준으로 LLM이
    # 자유발화를 해석한다. LLM이 서버에 설정 안 돼 있으면 503.
    try:
        result = await asyncio.to_thread(
            service.execute_purpose_for_appliance,
            body.text,
            frozenset(body.known_buttons),
        )
    except LlmNotConfiguredError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except UnknownIntentError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return ExecuteResponse(status=result.status.value, buttons=_to_steps(result))


@router.get("/status", response_model=StatusResponse)
async def status(
    service: SimpleLayService = Depends(get_service),
) -> StatusResponse:
    snapshot = service.status()
    progress = snapshot.progress
    verification = progress.verification if progress else None
    return StatusResponse(
        running=snapshot.running,
        last_status=snapshot.last_result.status.value if snapshot.last_result else None,
        last_buttons=_to_steps(snapshot.last_result) if snapshot.last_result else None,
        current_button=progress.button if progress else None,
        current_attempt=progress.attempt if progress else None,
        completed_steps=progress.completed_steps if progress else None,
        verification_confidence=verification.confidence if verification else None,
        verification_detail=verification.detail if verification else None,
    )


@router.post("/stop", response_model=OkResponse)
async def emergency_stop(
    service: SimpleLayService = Depends(get_service),
) -> OkResponse:
    # 실기기 연결 후 controller.emergency_stop() 호출로 교체
    return OkResponse()


@router.get("/suggestions", response_model=list[SuggestionResponse])
async def list_suggestions(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> list[SuggestionResponse]:
    return [
        SuggestionResponse(
            id=s.suggestion_id,
            purpose=s.purpose,
            time_band=s.time_band,
            occurrences=s.occurrences,
            steps=list(s.steps),
        )
        for s in svc.pending()
    ]


@router.post("/suggestions/{suggestion_id}/approve", response_model=ApproveResponse)
async def approve_suggestion(
    suggestion_id: str,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> ApproveResponse:
    try:
        result = await asyncio.to_thread(svc.approve, suggestion_id)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return ApproveResponse(status=result.status.value, buttons=_to_steps(result))


@router.post("/suggestions/{suggestion_id}/reject", response_model=OkResponse)
async def reject_suggestion(
    suggestion_id: str,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    pending = {s.suggestion_id for s in svc.pending()}
    if suggestion_id not in pending:
        raise HTTPException(status_code=404, detail="suggestion not found")
    # pending 목록에서 제거 — approve와 달리 실행 없이 dismiss
    svc._suggestions.pop(suggestion_id, None)
    return OkResponse()


@router.post("/dnd", response_model=OkResponse)
async def set_dnd(
    body: DndRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    svc.set_dnd_for(body.duration_minutes)
    return OkResponse()


@router.delete("/dnd", response_model=OkResponse)
async def clear_dnd(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    svc.clear_dnd()
    return OkResponse()


@router.get("/sensors", response_model=SensorResponse)
async def sensors() -> SensorResponse:
    # DHT22 실기기 연결 시 교체
    return SensorResponse(temperature=26.5, humidity=58.0)


@router.get("/alerts", response_model=AlertResponse)
async def alerts(
    store: DangerAlertStore = Depends(get_alert_store),
) -> AlertResponse:
    # SIMPLELAY_ACT_MODE=uart일 때만 실제로 갱신됨 -- 기본(로컬 mock) 모드에선
    # RPi4가 없으니 항상 active=False.
    state = store.current()
    return AlertResponse(
        active=state.active,
        kind=state.kind,
        band_energy_ratio=state.band_energy_ratio,
        mean_period_seconds=state.mean_period_seconds,
        updated_at=state.updated_at,
    )
