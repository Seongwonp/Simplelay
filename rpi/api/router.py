import asyncio

from fastapi import APIRouter, Depends, HTTPException

from rpi.controller import ExecutionResult
from rpi.intent.rules import UnknownIntentError
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError

from rpi.services import DangerAlertStore, NodeRegistry

from .deps import get_alert_store, get_actuator_status, get_dht22, get_node_registry, get_service, get_suggestion_service
from .schemas import (
    AlertResponse,
    ApproveResponse,
    ButtonStep,
    DemoSuggestRequest,
    DndRequest,
    ExecuteButtonsRequest,
    ExecuteForApplianceRequest,
    ExecuteRequest,
    ExecuteResponse,
    NodeRegisterRequest,
    NodeResponse,
    OkResponse,
    SensorResponse,
    StatusResponse,
    StopResponse,
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
        result = await asyncio.to_thread(
            service.execute_purpose, body.text, body.appliance_id
        )
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
        result = await asyncio.to_thread(
            service.execute_buttons, tuple(body.buttons), body.appliance_id
        )
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
            body.appliance_id,
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


@router.post("/stop", response_model=StopResponse)
async def emergency_stop(
    service: SimpleLayService = Depends(get_service),
) -> StopResponse:
    was_running = service.emergency_stop()
    return StopResponse(was_running=was_running)


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
    try:
        svc.reject(suggestion_id)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    return OkResponse()


@router.post("/demo/suggest", response_model=SuggestionResponse)
async def demo_suggest(
    body: DemoSuggestRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> SuggestionResponse:
    # 시연용 수동 트리거 — 패턴 감지를 우회해 제안을 즉시 만든다.
    # DND 중에는 실사용과 동일하게 거부(409)해서 데모 중 혼선을 막는다.
    suggestion = svc.create_demo_suggestion(body.purpose)
    if suggestion is None:
        raise HTTPException(status_code=409, detail="DND is active")
    return SuggestionResponse(
        id=suggestion.suggestion_id,
        purpose=suggestion.purpose,
        time_band=suggestion.time_band,
        occurrences=suggestion.occurrences,
        steps=list(suggestion.steps),
    )


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


_MOCK_TEMP = 26.5
_MOCK_HUM = 58.0


@router.get("/sensors", response_model=SensorResponse)
async def sensors(
    dht22=Depends(get_dht22),
) -> SensorResponse:
    temp, hum = await _read_dht22(dht22)
    return SensorResponse(temperature=temp, humidity=hum)


async def _read_dht22(dht22) -> tuple[float, float]:
    import asyncio  # noqa: PLC0415

    temp, hum = await asyncio.to_thread(dht22.read)
    return (
        temp if temp is not None else _MOCK_TEMP,
        hum if hum is not None else _MOCK_HUM,
    )


@router.get("/nodes", response_model=list[NodeResponse])
async def list_nodes(
    registry: NodeRegistry = Depends(get_node_registry),
) -> list[NodeResponse]:
    return [
        NodeResponse(appliance_id=appliance_id, base_url=registry.base_url(appliance_id))
        for appliance_id in registry.list_appliance_ids()
    ]


@router.post("/nodes/{appliance_id}", response_model=NodeResponse)
async def register_node(
    appliance_id: str,
    body: NodeRegisterRequest,
    registry: NodeRegistry = Depends(get_node_registry),
) -> NodeResponse:
    # 같은 appliance_id로 다시 부르면 주소가 교체된다(재등록) — 노드가 재부팅돼서
    # DHCP로 IP가 바뀐 경우 등을 위해 의도적으로 덮어쓰기 허용.
    registry.register(appliance_id, body.base_url)
    return NodeResponse(appliance_id=appliance_id, base_url=body.base_url)


@router.delete("/nodes/{appliance_id}", response_model=OkResponse)
async def unregister_node(
    appliance_id: str,
    registry: NodeRegistry = Depends(get_node_registry),
) -> OkResponse:
    registry.unregister(appliance_id)
    return OkResponse()


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
