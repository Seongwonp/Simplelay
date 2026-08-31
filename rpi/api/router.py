import asyncio
import json

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse

from rpi.controller import ExecutionResult
from rpi.intent.rules import UnknownIntentError
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError

from rpi.services import DangerAlertStore, NodeRegistry

from .deps import (
    EnvironmentOverride,
    get_alert_store,
    get_actuator_status,
    get_demo_failure_state,
    get_dht22,
    get_environment_override,
    get_job_history,
    get_node_registry,
    get_presence_store,
    get_service,
    get_suggestion_service,
)
from .schemas import (
    AlertResponse,
    ButtonStep,
    DemoEnvironmentRequest,
    DemoInjectFailureRequest,
    DemoSuggestRequest,
    DndRequest,
    ExecuteButtonsRequest,
    ExecuteForApplianceRequest,
    ExecuteRequest,
    ExecuteResponse,
    HistoryButton,
    HistoryEntryResponse,
    JobAcceptedResponse,
    NodeRegisterRequest,
    NodeResponse,
    OkResponse,
    RejectSuggestionRequest,
    PresenceRequest,
    PresenceResponse,
    SensorResponse,
    StatusResponse,
    StopResponse,
    SuggestionResponse,
    SuppressionListResponse,
    UnmuteRequest,
)
from .service import LlmNotConfiguredError, SimpleLayService

router = APIRouter()


def _to_steps(result: ExecutionResult) -> list[ButtonStep]:
    return [
        ButtonStep(button=b.button, success=b.status.value == "succeeded")
        for b in result.buttons
    ]


# 실행 엔드포인트 3종은 모두 비동기 job 모델: 의도 해석(즉시 실패 가능)만
# 요청 안에서 끝내고, 물리 실행은 백그라운드로 넘긴 뒤 job_id를 즉시 반환한다.
# 진행·완료는 GET /status 폴링 + job_id 대조로 확인한다. (동기 실행은
# 실기기의 수 초~수십 초 시퀀스가 클라이언트 타임아웃(폰 8초·키오스크 4초)을
# 항상 초과하는 구조적 문제가 있었다.)


@router.post("/execute", response_model=JobAcceptedResponse)
async def execute(
    body: ExecuteRequest,
    service: SimpleLayService = Depends(get_service),
) -> JobAcceptedResponse:
    try:
        job_id = await asyncio.to_thread(
            service.submit_purpose, body.text, body.appliance_id
        )
    except UnknownIntentError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return JobAcceptedResponse(job_id=job_id)


@router.post("/execute-buttons", response_model=JobAcceptedResponse)
async def execute_buttons(
    body: ExecuteButtonsRequest,
    service: SimpleLayService = Depends(get_service),
) -> JobAcceptedResponse:
    # 의도 해석 규칙이 없는 사용자 정의 가전용 — 목적 문자열 없이 버튼을 직접 실행.
    try:
        job_id = await asyncio.to_thread(
            service.submit_buttons, tuple(body.buttons), body.appliance_id
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return JobAcceptedResponse(job_id=job_id)


@router.post("/execute-for-appliance", response_model=JobAcceptedResponse)
async def execute_for_appliance(
    body: ExecuteForApplianceRequest,
    service: SimpleLayService = Depends(get_service),
) -> JobAcceptedResponse:
    # 사용자 정의 가전용 음성 명령 — 요청에 실린 버튼 어휘를 기준으로 LLM이
    # 자유발화를 해석한다. LLM이 서버에 설정 안 돼 있으면 503.
    try:
        job_id = await asyncio.to_thread(
            service.submit_purpose_for_appliance,
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
    return JobAcceptedResponse(job_id=job_id)


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
        job_id=snapshot.job_id,
        last_job_id=snapshot.last_job_id,
        total_steps=snapshot.total_steps,
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
            reason=s.reason,
        )
        for s in svc.pending()
    ]


@router.post("/suggestions/{suggestion_id}/approve", response_model=JobAcceptedResponse)
async def approve_suggestion(
    suggestion_id: str,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> JobAcceptedResponse:
    # 승인도 job 모델 — 게이트를 닫고 실행을 제출한 뒤 즉시 job_id 반환.
    try:
        job_id = await asyncio.to_thread(svc.approve_submit, suggestion_id)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return JobAcceptedResponse(job_id=job_id)


@router.post("/suggestions/{suggestion_id}/reject", response_model=OkResponse)
async def reject_suggestion(
    suggestion_id: str,
    body: RejectSuggestionRequest | None = None,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    try:
        svc.reject(suggestion_id, mute=body.mute if body is not None else False)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    return OkResponse()


@router.get("/suppressions", response_model=SuppressionListResponse)
async def list_suppressions(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> SuppressionListResponse:
    return SuppressionListResponse(purposes=list(svc.muted_purposes()))


@router.post("/suppressions/unmute", response_model=OkResponse)
async def unmute_suppression(
    body: UnmuteRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    svc.unmute(body.purpose)
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
        reason=suggestion.reason,
    )


@router.post("/demo/environment", response_model=list[SuggestionResponse])
async def demo_environment(
    body: DemoEnvironmentRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
    override: EnvironmentOverride = Depends(get_environment_override),
) -> list[SuggestionResponse]:
    override.set(body.temperature, body.humidity)
    created = await asyncio.to_thread(svc.create_suggestions)
    return [
        SuggestionResponse(
            id=s.suggestion_id,
            purpose=s.purpose,
            time_band=s.time_band,
            occurrences=s.occurrences,
            steps=list(s.steps),
            reason=s.reason,
        )
        for s in created
    ]


@router.post("/presence", response_model=PresenceResponse)
async def report_presence(
    body: PresenceRequest,
    store=Depends(get_presence_store),
) -> PresenceResponse:
    # 공간 존재 감지기(RPi4 카메라)가 판정을 보고하는 지점 — 실기기 날에는
    # 감지기 프로세스가 이 엔드포인트만 호출하면 공간 맥락 배선이 완성된다.
    store.set_present(body.present, body.source)
    state = store.current()
    return PresenceResponse(
        present=state.present, source=state.source, updated_at=state.updated_at
    )


@router.get("/presence", response_model=PresenceResponse)
async def presence(
    store=Depends(get_presence_store),
) -> PresenceResponse:
    state = store.current()
    return PresenceResponse(
        present=state.present, source=state.source, updated_at=state.updated_at
    )


@router.get("/history", response_model=list[HistoryEntryResponse])
async def history(
    limit: int = 50,
    store=Depends(get_job_history),
) -> list[HistoryEntryResponse]:
    # 실행 이력(최신순) — 공감지능의 근거 데이터와 폐루프 재시도 기록을
    # 사용자에게 그대로 보여준다. limit은 1~200으로 클램프.
    limit = max(1, min(limit, 200))
    return [
        HistoryEntryResponse(
            job_id=e.job_id,
            finished_at=e.finished_at,
            purpose=e.purpose,
            status=e.status,
            retry_count=e.retry_count,
            buttons=[
                HistoryButton(
                    button=b.button, success=b.success, attempts=b.attempts
                )
                for b in e.buttons
            ],
        )
        for e in store.recent(limit)
    ]


@router.post("/demo/inject-failure", response_model=OkResponse)
async def demo_inject_failure(
    body: DemoInjectFailureRequest,
    state=Depends(get_demo_failure_state),
    service: SimpleLayService = Depends(get_service),
) -> OkResponse:
    # 리허설 장치 — 다음 실행의 지정 버튼 검증을 강제 실패시켜 재시도/
    # 안전 정지 장면을 원할 때 연출한다. 무장은 실행 직전에 할 것(1회용).
    # 로컬 상태 무장 + (UART 모드면) RPi4로도 전달 — 검증이 어느 쪽에서
    # 일어나든 같은 API 한 번으로 리허설이 성립한다.
    state.arm(body.button_index, body.attempts)
    service.forward_demo_failure(body.button_index, body.attempts)
    return OkResponse()


@router.delete("/demo/inject-failure", response_model=OkResponse)
async def demo_clear_failure(
    state=Depends(get_demo_failure_state),
    service: SimpleLayService = Depends(get_service),
) -> OkResponse:
    state.disarm()
    service.clear_forwarded_demo_failure()
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


_MOCK_TEMP = 26.5
_MOCK_HUM = 58.0


@router.get("/sensors", response_model=SensorResponse)
async def sensors(
    dht22=Depends(get_dht22),
    override: EnvironmentOverride = Depends(get_environment_override),
) -> SensorResponse:
    forced = override.current()
    if forced is not None:
        return SensorResponse(
            temperature=forced[0], humidity=forced[1], mocked=True
        )
    temp, hum, mocked = await _read_dht22(dht22)
    return SensorResponse(temperature=temp, humidity=hum, mocked=mocked)


async def _read_dht22(dht22) -> tuple[float, float, bool]:
    import asyncio  # noqa: PLC0415

    temp, hum = await asyncio.to_thread(dht22.read)
    mocked = temp is None or hum is None
    return (
        temp if temp is not None else _MOCK_TEMP,
        hum if hum is not None else _MOCK_HUM,
        mocked,
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


# SSE 이벤트 변화 감지 주기(서버 내부) — 클라이언트 체감은 "즉시".
# 기존 3초 폴링 대비 위험 경보 지연을 사실상 0으로 줄인다.
_SSE_CHECK_INTERVAL = 0.3
_SSE_KEEPALIVE_EVERY = 50  # 0.3s * 50 = 15초마다 keepalive 주석


async def sse_event_lines(
    is_disconnected,
    alert_payload,
    status_payload,
    check_interval: float = _SSE_CHECK_INTERVAL,
    keepalive_every: int = _SSE_KEEPALIVE_EVERY,
):
    """SSE 라인 제너레이터 — 위험 경보(alert)와 실행 상태(status)의 '변화'만
    푸시한다. 콜러블 주입 구조라 무한 스트림을 실제 HTTP 없이 단위
    테스트할 수 있다(TestClient는 무한 스트림 종료에서 hang하는 제약).

    - 연결 직후 현재 alert/status를 1회 보낸다(초기 스냅샷)
    - 이후에는 값이 바뀔 때만 이벤트를 보낸다
    - keepalive 주석을 주기적으로 흘려 프록시·클라이언트 유휴 타임아웃 방지
    """
    last_alert: dict | None = None
    last_status: dict | None = None
    ticks = 0
    while not await is_disconnected():
        alert = alert_payload()
        if alert != last_alert:
            last_alert = alert
            yield f"event: alert\ndata: {json.dumps(alert, ensure_ascii=False)}\n\n"
        status_now = status_payload()
        if status_now != last_status:
            last_status = status_now
            yield (
                "event: status\n"
                f"data: {json.dumps(status_now, ensure_ascii=False)}\n\n"
            )
        ticks += 1
        if ticks % keepalive_every == 0:
            yield ": keepalive\n\n"
        await asyncio.sleep(check_interval)


def alert_event_payload(store: DangerAlertStore) -> dict:
    s = store.current()
    return {
        "active": s.active,
        "kind": s.kind,
        "band_energy_ratio": s.band_energy_ratio,
        "mean_period_seconds": s.mean_period_seconds,
    }


def status_event_payload(service: SimpleLayService) -> dict:
    snap = service.status()
    progress = snap.progress
    return {
        "running": snap.running,
        "job_id": snap.job_id,
        "last_job_id": snap.last_job_id,
        "last_status": snap.last_result.status.value if snap.last_result else None,
        # 진행 필드 — GET /status와 같은 의미(실행 중일 때만 값). 이게 없으면
        # SSE만 보는 클라이언트는 "몇 번째 버튼을 재시도 중인지"를 위해 결국
        # 폴링을 병행해야 했다(교차 리뷰 #13). 버튼 진행·재시도 시마다
        # payload가 달라지므로 변화 푸시로 즉시 흘러간다 — 키오스크의
        # "status 이벤트 → 즉시 /status 폴링" 패턴이 진행바에도 적용된다.
        "current_button": progress.button if progress else None,
        "current_attempt": progress.attempt if progress else None,
        "completed_steps": progress.completed_steps if progress else None,
        "total_steps": snap.total_steps,
    }


@router.get("/events")
async def events(
    request: Request,
    store: DangerAlertStore = Depends(get_alert_store),
    service: SimpleLayService = Depends(get_service),
) -> StreamingResponse:
    """SSE 스트림 — 폴링을 대체하는 게 아니라 지연을 없애는 상위 채널:
    클라이언트(키오스크)는 이 스트림을 우선 사용하고, 끊기면 기존 폴링으로
    계속 동작한다. 추가 의존성 없이 내부 300ms 변화 감지 루프로 구현 —
    인메모리 읽기라 비용이 무시할 수준이다."""
    return StreamingResponse(
        sse_event_lines(
            request.is_disconnected,
            lambda: alert_event_payload(store),
            lambda: status_event_payload(service),
        ),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


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
