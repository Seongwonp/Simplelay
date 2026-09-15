import asyncio
import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import PlainTextResponse, StreamingResponse

from rpi.controller import ExecutionResult
from rpi.intent.rules import UnknownIntentError
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError

from rpi.services import DangerAlertStore, NodeRegistry
from rpi.services.history import history_csv
from rpi.services.readiness import (
    ApplianceReadiness,
    ReadinessCheck,
    ReadinessRegistry,
)

from rpi.services import ApplianceButtonDef, ApplianceDef, BuiltinApplianceError
from rpi.services.appliance_registry import (
    ApplianceCategory,
    RevisionConflictError,
    category_from_legacy_icon,
)

from .deps import (
    get_presence_state_machine,
    get_clock,
    get_readiness_registry,
    get_wellness_pause,
    EnvironmentOverride,
    get_alert_store,
    get_appliance_registry,
    get_care_events,
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
    ApplianceCalibrationRequest,
    ApplianceCalibrationResponse,
    PresenceDistanceRequest,
    PresenceStateResponse,
    PresenceTransitionModel,
    ApplianceButtonModel,
    ApplianceRegisterRequest,
    ApplianceResponse,
    CareEventResponse,
    DemoCareEventRequest,
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
    ReadinessReportRequest,
    WellnessPauseRequest,
    WellnessPauseResponse,
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
from .service import (
    LlmNotConfiguredError,
    SimpleLayService,
    UnknownApplianceError,
)

log = logging.getLogger(__name__)

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


# 실행 대상 가전 게이트는 SimpleLayService._controller_for로 옮겼다 (R1).
# 라우터마다 검사를 붙이면 진입점이 늘 때마다 같은 구멍이 다시 생긴다 --
# 실제로 제안 승인 경로가 그렇게 빠져 있었다. 여기서는 서비스가 던진
# UnknownApplianceError를 HTTP 404로 옮기기만 한다.


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


# ── 가전 레지스트리 — 폰·키오스크가 공유하는 가전 정의 ──────────────────────


def _to_appliance_response(a, service=None, nodes=None) -> ApplianceResponse:
    # 준비 상태는 **노드로 라우팅되는 가전**의 계약이다. 노드가 없는
    # 내장 가전은 종전대로 로컬에서 실행되므로 can_execute는 True다 --
    # 화면이 실행 버튼을 막을지 정할 때는 readiness가 아니라 이 값을 본다.
    readiness = (
        service.readiness_of(a.appliance_id) if service is not None else None
    )
    # 화면이 보는 값과 서버가 실제로 거절하는 기준은 **같은 규칙**이어야
    # 한다. 어긋나면 누를 수 있는데 안 되는 버튼(또는 그 반대)이 생긴다.
    has_node = nodes is not None and nodes.get(a.appliance_id) is not None
    runs_locally = (
        service.runs_locally(a.appliance_id) if service is not None else True
    )
    return ApplianceResponse(
        id=a.appliance_id,
        name=a.name,
        # 종류가 진실원천이고, icon은 거기서 파생한 호환 출력이다.
        category=a.category.value,
        icon=a.icon,
        rows=a.rows,
        cols=a.cols,
        is_custom=a.is_custom,
        buttons=[
            ApplianceButtonModel(
                id=b.id,
                label=b.label,
                x=b.x,
                y=b.y,
                kind=b.kind.value,
                detents=b.detents,
                press_ms=b.press_ms,
                x_mm=b.x_mm,
                y_mm=b.y_mm,
            )
            for b in a.buttons
        ],
        revision=a.revision,
        functions={name: list(steps) for name, steps in a.functions},
        calibration_version=a.calibration_version,
        readiness=(
            "operable"
            if (not has_node and runs_locally)
            else readiness.state.value
            if readiness is not None
            else "disconnected"
        ),
        readiness_reasons=(
            []
            if (not has_node and runs_locally)
            else list(readiness.blocking_reasons)
            if readiness is not None
            else []
        ),
        can_execute=(
            (readiness.can_execute if readiness is not None else False)
            if has_node
            # 노드가 없으면 정당한 로컬 대상일 때만 실행할 수 있다.
            # 노드도 없고 로컬 대상도 아니면 누를 액추에이터가 없다.
            else runs_locally
        ),
    )


@router.post("/demo/care-event", response_model=CareEventResponse)
async def demo_care_event(
    body: DemoCareEventRequest,
    store=Depends(get_care_events),
) -> CareEventResponse:
    # 리허설 장치 — 시연에서 보호자 알림함·배지 장면을 원하는 시점에 연출
    default_messages = {
        "execution_failed": "'우유 데워줘' 실행이 완료되지 못했어요. 가전을 확인해 주세요.",
        "emergency_stop": "'우유 데워줘' 실행을 긴급 정지로 멈췄어요.",
        "danger_sound": "위험할 수 있는 신호음이 감지되었어요. 안부를 확인해 주세요.",
        "quiet_routine": "평소 저녁 시간대의 '우유 데워줘' 사용이 오늘은 없었어요. "
        "안부 전화 한번 어떨까요?",
    }
    event = store.append(
        body.kind,
        body.message.strip() or default_messages[body.kind],
        purpose=body.purpose,
    )
    return CareEventResponse(
        id=event.event_id,
        kind=event.kind,
        message=event.message,
        purpose=event.purpose,
        occurred_at=event.occurred_at,
    )


@router.get("/care-events", response_model=list[CareEventResponse])
async def list_care_events(
    limit: int = 50,
    store=Depends(get_care_events),
) -> list[CareEventResponse]:
    """보호자 알림 — 실패·위험소리·긴급정지·안부 신호를 최신순으로.
    폰 앱의 알림함이 주기 폴링으로 읽는다."""
    return [
        CareEventResponse(
            id=e.event_id,
            kind=e.kind,
            message=e.message,
            purpose=e.purpose,
            occurred_at=e.occurred_at,
        )
        for e in store.recent(limit=max(1, min(limit, 200)))
    ]


@router.get("/appliances", response_model=list[ApplianceResponse])
async def list_appliances(
    registry=Depends(get_appliance_registry),
    service: SimpleLayService = Depends(get_service),
    nodes: NodeRegistry = Depends(get_node_registry),
) -> list[ApplianceResponse]:
    """내장 + 커스텀 가전 전체. 폰에서 등록한 가전이 키오스크에 뜨는 경로.

    준비 상태(F1)도 여기 함께 실어 보낸다 -- 폰과 키오스크가 **같은**
    상태와 같은 사유를 보게 하려면 한 곳에서 나와야 한다.
    """
    return [
        _to_appliance_response(a, service, nodes) for a in registry.list()
    ]


@router.get("/wellness-pause", response_model=WellnessPauseResponse)
async def wellness_pause_state(
    pause=Depends(get_wellness_pause),
    clock=Depends(get_clock),
) -> WellnessPauseResponse:
    """안부 확인을 쉬고 있는가 (F5).

    끝난 일시 중지의 날짜는 내보내지 않는다. 지난 날짜를 그대로 주면
    화면이 "7월 23일까지 쉬어요"라고 말하는데 서버는 이미 안부 신호를
    다시 보내고 있는 상태가 된다.
    """
    today = clock.now().date()
    active = pause.is_active(today)
    return WellnessPauseResponse(
        paused=active, until=pause.until if active else None
    )


@router.post("/wellness-pause", response_model=WellnessPauseResponse)
async def set_wellness_pause(
    body: WellnessPauseRequest,
    pause=Depends(get_wellness_pause),
    clock=Depends(get_clock),
) -> WellnessPauseResponse:
    """집을 비운 것을 **아는** 날들 동안 안부 신호를 쉰다.

    실행 실패·위험소리·긴급정지 알림은 그대로 간다 -- 사람이 집을 비웠다는
    것은 조용한 것이 정상이라는 뜻이지, 가전이 고장 나도 된다는 뜻이 아니다.
    """
    today = clock.now().date()
    try:
        pause.set_until(body.until, today=today)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return WellnessPauseResponse(paused=True, until=pause.until)


@router.delete("/wellness-pause", response_model=WellnessPauseResponse)
async def clear_wellness_pause(
    pause=Depends(get_wellness_pause),
) -> WellnessPauseResponse:
    pause.clear()
    return WellnessPauseResponse(paused=False)


@router.post("/readiness/{appliance_id}", response_model=OkResponse)
async def report_readiness(
    appliance_id: str,
    body: ReadinessReportRequest,
    registry=Depends(get_appliance_registry),
    readiness=Depends(get_readiness_registry),
    clock=Depends(get_clock),
) -> OkResponse:
    """노드(또는 설치 도구)가 자기 준비 상태를 보고한다 (F1).

    서버가 스스로 판정하지 않는 이유: 전송이 살아 있다는 사실만으로는
    모터가 홈을 잡았는지, 센서가 기준값을 잡았는지 알 수 없다. 그건
    노드만 안다. 실제 판정 구현은 하드웨어가 붙은 뒤 노드 쪽에 붙는다.
    """
    if registry.get(appliance_id) is None:
        raise HTTPException(status_code=404, detail="appliance not found")
    readiness.report(
        ApplianceReadiness.of(
            appliance_id,
            {
                ReadinessCheck.TRANSPORT: body.transport,
                ReadinessCheck.MOTION: body.motion,
                ReadinessCheck.SENSOR: body.sensor,
                ReadinessCheck.CALIBRATION: body.calibration,
            },
            reasons={
                ReadinessCheck(k): v
                for k, v in body.reasons.items()
                if k in {c.value for c in ReadinessCheck}
            },
            checked_at=clock.now(),
            calibration_profile_version=body.calibration_profile_version,
        )
    )
    return OkResponse()


@router.put("/appliances/{appliance_id}", response_model=ApplianceResponse)
async def register_appliance(
    appliance_id: str,
    body: ApplianceRegisterRequest,
    registry=Depends(get_appliance_registry),
) -> ApplianceResponse:
    # 같은 id로 다시 부르면 교체(폰 편집기의 저장 버튼과 1:1) — 노드 등록과
    # 같은 upsert 관례.
    try:
        body.validate_layout()
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    appliance = ApplianceDef(
        appliance_id=appliance_id.strip(),
        name=body.name,
        # category가 오면 그걸 쓰고, 없으면 구버전이 보낸 icon에서
        # **명시적인 표로만** 되살린다. 이름으로 추측하지 않는다.
        category=(
            ApplianceCategory.parse(body.category)
            if body.category is not None
            else category_from_legacy_icon(body.icon)
        ),
        rows=body.rows,
        cols=body.cols,
        buttons=body.button_defs(),
        is_custom=True,
        functions=tuple(
            (name.strip(), tuple(steps))
            for name, steps in (body.functions or {}).items()
        ),
    )
    if not appliance.appliance_id:
        raise HTTPException(status_code=422, detail="appliance id must not be blank")
    try:
        saved = registry.register(
            appliance, expected_revision=body.expected_revision
        )
    except BuiltinApplianceError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RevisionConflictError as exc:
        # 자동 병합도, 자동 덮어쓰기도 하지 않는다 -- 서버 내용을 유지한 채
        # 거절하고, 무엇을 살릴지는 사용자가 정하게 한다.
        raise HTTPException(
            status_code=409,
            detail="다른 기기에서 먼저 변경되었어요",
            headers={"X-Current-Revision": str(exc.current_revision)},
        ) from exc
    return _to_appliance_response(saved)


@router.put(
    "/appliances/{appliance_id}/calibration",
    response_model=ApplianceCalibrationResponse,
)
async def calibrate_appliance(
    appliance_id: str,
    body: ApplianceCalibrationRequest,
    registry=Depends(get_appliance_registry),
) -> ApplianceCalibrationResponse:
    """기준점으로 변환 행렬을 구하고, 버튼 중심을 갠트리 mm로 바꿔 저장한다.

    검증에 실패하면 **아무것도 저장하지 않는다** -- 틀린 좌표를 남기는 것보다
    보정 전 상태가 안전하다. 거절 문장은 어느 기준점이 문제인지 밝힌다.
    """
    from rpi.calibration import (  # noqa: PLC0415
        CalibrationRejected,
        PointPair,
        calibrate,
        map_button_centers,
    )
    from rpi.services.appliance_registry import MM_RANGE  # noqa: PLC0415

    appliance = registry.get(appliance_id)
    if appliance is None:
        raise HTTPException(status_code=404, detail="appliance not found")
    known = {b.id for b in appliance.buttons}
    unknown = sorted(set(body.button_centers) - known)
    if unknown:
        raise HTTPException(
            status_code=422,
            detail=f"이 가전에 없는 버튼입니다: {', '.join(unknown)}",
        )
    options = {}
    if body.max_rms_mm is not None:
        options["max_rms_mm"] = body.max_rms_mm
    if body.max_point_error_mm is not None:
        options["max_point_error_mm"] = body.max_point_error_mm
    try:
        result = calibrate(
            [PointPair(p.source, p.target) for p in body.points],
            kind=body.kind,
            **options,
        )
        coords = map_button_centers(result, body.button_centers)
    except CalibrationRejected as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    lo, hi = MM_RANGE
    outside = sorted(
        bid for bid, (x, y) in coords.items() if not (lo <= x <= hi and lo <= y <= hi)
    )
    if outside:
        raise HTTPException(
            status_code=422,
            detail=f"변환된 좌표가 프레임({lo:g}~{hi:g}mm) 밖입니다: {', '.join(outside)}",
        )
    try:
        saved = registry.apply_calibration(
            appliance_id,
            version=result.version,
            coords=coords,
            expected_revision=body.expected_revision,
        )
    except RevisionConflictError as exc:
        raise HTTPException(
            status_code=409,
            detail="다른 기기에서 먼저 변경되었어요",
            headers={"X-Current-Revision": str(exc.current_revision)},
        ) from exc
    except LookupError as exc:
        raise HTTPException(status_code=404, detail="appliance not found") from exc
    return ApplianceCalibrationResponse(
        appliance=_to_appliance_response(saved),
        version=result.version,
        kind=result.transform.kind,
        point_count=result.point_count,
        redundant_points=result.redundant_points,
        rms_error_mm=result.rms_error_mm,
        max_error_mm=result.max_error_mm,
        unmapped_buttons=[b.id for b in saved.buttons if not b.calibrated],
    )


@router.delete("/appliances/{appliance_id}", response_model=OkResponse)
async def delete_appliance(
    appliance_id: str,
    expected_revision: int | None = None,
    registry=Depends(get_appliance_registry),
    nodes: NodeRegistry = Depends(get_node_registry),
    suggestions: ProactiveSuggestionService = Depends(get_suggestion_service),
    readiness: ReadinessRegistry = Depends(get_readiness_registry),
) -> OkResponse:
    try:
        found = registry.delete(
            appliance_id, expected_revision=expected_revision
        )
    except BuiltinApplianceError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RevisionConflictError as exc:
        # 오래된 삭제가 남의 수정을 지우지 않게 한다. 수정과 같은 규칙이다.
        raise HTTPException(
            status_code=409,
            detail="다른 기기에서 먼저 변경되었어요",
            headers={"X-Current-Revision": str(exc.current_revision)},
        ) from exc
    if not found:
        raise HTTPException(status_code=404, detail="appliance not found")

    _cleanup_after_delete(appliance_id, nodes, suggestions, readiness)
    return OkResponse()


def _cleanup_after_delete(
    appliance_id: str,
    nodes: NodeRegistry,
    suggestions: ProactiveSuggestionService,
    readiness: ReadinessRegistry,
) -> None:
    """삭제가 확정된 뒤의 뒷정리.

    **각 단계를 독립적으로 시도한다.** 한 단계가 던져도 나머지는 반드시
    수행한다 -- 한 단계에 묶어두면 부가 작업 하나의 실패가 안전 정리까지
    막고, 지운 가전의 '조작 가능'이 남아 같은 id 재등록 때 확인한 적 없는
    판정을 물려받는다.

    예외는 삼키지 않는다. 호출자는 뒷정리가 덜 끝났다는 것을 알아야 한다.
    여럿이 실패하면 **첫 예외**를 전달하고 나머지는 로그로 남긴다 -- 마지막
    것을 던지면 먼저 무너진 자리를 잃는다.
    """
    steps = (
        # 연결 노드 — 남겨두면 유령 노드에 긴급 정지가 계속 가고, 같은 id
        # 재등록 시 예전 주소가 조용히 재사용된다 (교차 리뷰 #4)
        ("node", lambda: nodes.unregister(appliance_id)),
        # 그 가전을 대상으로 하던 제안 카드 (R1) — 남겨두면 실행할 수 없는
        # 것을 계속 권유하고, 승인하면 404로 거절된다.
        ("suggestions", lambda: suggestions.drop_for_appliance(appliance_id)),
        # 준비 판정 — 셋 중 **안전에 직접 걸린** 것이다.
        ("readiness", lambda: readiness.forget(appliance_id)),
    )
    first: Exception | None = None
    for name, step in steps:
        try:
            step()
        except Exception as exc:  # noqa: BLE001 - 각 단계는 서로 독립이다
            log.exception(
                "cleanup step %r failed for appliance %r", name, appliance_id
            )
            if first is None:
                first = exc
    if first is not None:
        raise first


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
        appliance_id=snapshot.appliance_id,
        last_appliance_id=snapshot.last_appliance_id,
    )


@router.post("/stop", response_model=StopResponse)
async def emergency_stop(
    service: SimpleLayService = Depends(get_service),
) -> StopResponse:
    # 노드 정지 브로드캐스트는 응답 없는 노드를 전체 상한까지 기다리는 동기
    # 호출이다. 이벤트 루프에서 직접 부르면 그동안 /status·SSE·다른 API가
    # 전부 멈춘다 — 스레드로 넘긴다.
    #
    # 개발자 세션도 같은 버튼으로 멈춘다 — 긴급 정지는 "누가 제어 중인가"를
    # 가리지 않는다. 모드가 꺼져 있으면 no-op이고, 개발자 쪽 정지 실패는
    # fault로 잠근 뒤 삼킨다(일반 정지 응답을 막지 않는다). 노드 브로드캐스트를
    # 기다렸다 보내지 않고 동시에 보낸다: 두 경로는 서로의 락을 잡지 않는다.
    from rpi.api.deps import stop_developer_session_if_any  # noqa: PLC0415

    report, _ = await asyncio.gather(
        asyncio.to_thread(service.emergency_stop_report),
        asyncio.to_thread(stop_developer_session_if_any, "emergency_stop"),
    )
    return StopResponse(
        was_running=report.was_running,
        nodes_requested=len(report.nodes_acknowledged)
        + len(report.nodes_unconfirmed),
        nodes_acknowledged=list(report.nodes_acknowledged),
        nodes_unconfirmed=list(report.nodes_unconfirmed),
    )


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
            appliance_id=s.appliance_id,
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
    except UnknownIntentError as exc:
        # 실행 상한 초과 등 해석 결과 거절 — ValueError 계열이라 잡지 않으면 500
        raise HTTPException(status_code=422, detail=str(exc)) from exc
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
    registry=Depends(get_appliance_registry),
) -> SuggestionResponse:
    # 시연용 수동 트리거 — 패턴 감지를 우회해 제안을 즉시 만든다.
    # DND 중에는 실사용과 동일하게 거부(409)해서 데모 중 혼선을 막는다.
    # 대상 가전은 실제 실행과 같은 기준으로 검증한다(B10) — 오타 난 대상으로
    # 만들면 "승인해도 실행 안 되는 카드"가 리허설 화면에 남는다.
    if registry.get(body.appliance_id) is None:
        raise UnknownApplianceError(
            f"appliance '{body.appliance_id}' not found -- 삭제되었거나 "
            "등록되지 않은 가전입니다"
        )
    suggestion = svc.create_demo_suggestion(
        body.purpose, appliance_id=body.appliance_id
    )
    if suggestion is None:
        raise HTTPException(status_code=409, detail="DND is active")
    return SuggestionResponse(
        id=suggestion.suggestion_id,
        purpose=suggestion.purpose,
        time_band=suggestion.time_band,
        occurrences=suggestion.occurrences,
        steps=list(suggestion.steps),
        reason=suggestion.reason,
        appliance_id=suggestion.appliance_id,
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
            appliance_id=s.appliance_id,
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
            appliance_id=e.appliance_id,
            execution_mode=e.execution_mode.value,
            termination=e.termination.value,
            # timedelta(0)은 falsy다 — mock 실행이 시계 한 틱 안에 끝나면
            # 진짜 0.0초 기록이 '기록 없음'(None)으로 둔갑한다. None 비교로만
            # 가른다(실측 표본에서 0초와 결측은 다른 데이터다).
            duration_seconds=(
                e.duration.total_seconds() if e.duration is not None else None
            ),
            buttons=[
                HistoryButton(
                    button=b.button, success=b.success, attempts=b.attempts
                )
                for b in e.buttons
            ],
        )
        for e in store.recent(limit)
    ]


def _presence_state(machine, transitions) -> PresenceStateResponse:
    profile = machine.profile
    return PresenceStateResponse(
        state=machine.state.value,
        executing=machine.executing,
        arrival_hint=machine.arrival_hint_active(),
        radar=profile.radar,
        node_awake=profile.node_awake,
        screen_on=profile.screen_on,
        actuator_powered=profile.actuator_powered,
        estimated_watts=list(profile.estimated_watts),
        transitions=[
            PresenceTransitionModel(
                at_s=tr.at_s,
                previous=tr.previous.value,
                current=tr.current.value,
                reason=tr.reason,
                actions=list(tr.actions),
            )
            for tr in transitions
        ],
    )


@router.post("/presence/distance", response_model=PresenceStateResponse)
async def presence_distance(
    body: PresenceDistanceRequest,
    machine=Depends(get_presence_state_machine),
) -> PresenceStateResponse:
    # 거리 센서 한 주기 관측. 동작 어휘(screen_on 등)는 돌려줄 뿐 여기서
    # 실행하지 않는다 -- 화면·전원 제어는 받는 쪽(노드)의 몫이다.
    return _presence_state(machine, machine.observe(body.distance_m))


@router.post("/presence/arriving", response_model=PresenceStateResponse)
async def presence_arriving(
    machine=Depends(get_presence_state_machine),
) -> PresenceStateResponse:
    # S0 귀가 신호(폰 지오펜싱). 노드는 깨우지 않고 추천 후보만 미리 계산.
    transition = machine.phone_arriving()
    return _presence_state(machine, [transition] if transition else [])


@router.get("/presence/state", response_model=PresenceStateResponse)
async def presence_state(
    machine=Depends(get_presence_state_machine),
) -> PresenceStateResponse:
    # 조회도 시간 경과(체류 승격·미감지 강등)를 반영한다.
    return _presence_state(machine, machine.tick())


@router.get("/history.csv")
async def history_export(
    limit: int = 500,
    store=Depends(get_job_history),
) -> PlainTextResponse:
    """실험 기록 내보내기 (F4) — 실기기 검증 기간의 근거 데이터.

    여기서 뽑는 것: 첫 시도 성공률, 재시도 후 최종 성공률, 실행 시간,
    정지 지연, 실제/모의 구분. 마지막 것이 없으면 mock 실행이 실제
    성공률에 섞여 들어간다.

    나가는 열은 history.py의 **허용 목록**이다 -- 주소·API 키·가정
    식별정보·원문 음성은 목록에 없으므로 새 필드가 늘어도 새지 않는다.
    """
    limit = max(1, min(limit, 5000))
    return PlainTextResponse(
        history_csv(store.recent(limit)),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": 'attachment; filename="simplelay-history.csv"'
        },
    )


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
    readiness: ReadinessRegistry = Depends(get_readiness_registry),
) -> NodeResponse:
    # 같은 appliance_id로 다시 부르면 주소가 교체된다(재등록) — 노드가 재부팅돼서
    # DHCP로 IP가 바뀐 경우 등을 위해 의도적으로 덮어쓰기 허용.
    #
    # 판정 무효화를 finally에 두는 이유: `register()`는 메모리 주소를 먼저
    # 바꾸고 store에 저장한다. 저장이 실패하면 **주소는 이미 바뀐 채로**
    # 예외가 나가는데, 그때 앞 기기의 '조작 가능'이 남아 있으면 확인한 적
    # 없는 새 주소로 맡겨도 된다고 말하게 된다. 등록 성공이 불확실한
    # 순간에는 판정을 버리는 쪽(fail-closed)이 안전하다.
    #
    # 입력 검증으로 여기 닿기도 전에 거절된 요청은 아무 상태도 바꾸지
    # 않으므로 해당되지 않는다.
    try:
        registry.register(appliance_id, body.base_url)
    finally:
        # 주소가 바뀌었다면 **다른 기기로 갈아 끼운 것일 수 있다.** 앞
        # 기기에서 맞춘 버튼 좌표가 새 기기에도 맞다고 볼 근거는 없다.
        # 최초 등록도 마찬가지다 -- "등록됐다"는 "맡겨도 된다"가 아니다(F1).
        readiness.forget(appliance_id)
    return NodeResponse(appliance_id=appliance_id, base_url=body.base_url)


@router.delete("/nodes/{appliance_id}", response_model=OkResponse)
async def unregister_node(
    appliance_id: str,
    registry: NodeRegistry = Depends(get_node_registry),
    readiness: ReadinessRegistry = Depends(get_readiness_registry),
) -> OkResponse:
    # 노드 해제가 실패하더라도 판정은 버린다 -- 누를 장치가 없는데 조작
    # 가능이 남아 있는 것이 더 위험하다.
    try:
        registry.unregister(appliance_id)
    finally:
        # 가전 정의는 남아도, 누를 장치가 없으면 조작 가능일 수 없다.
        readiness.forget(appliance_id)
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
        "appliance_id": snap.appliance_id,
        "last_appliance_id": snap.last_appliance_id,
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
