import asyncio
import json
import logging
import os
import time
from collections import deque
from dataclasses import replace

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse

from rpi.controller import ExecutionResult, outcome_of
from rpi.intent.rules import UnknownIntentError, UnrecognizedPurposeError
from rpi.intent.stop_words import is_stop_phrase
from rpi.intent.suggestions import ProactiveSuggestionService, UnknownSuggestionError

from rpi.services import DangerAlertStore, NodeRegistry
from rpi.services.act_client import AlertEvent
from rpi.services.history import history_csv
from rpi.services.person_acks import FAILURE_CARE_KINDS, base_job_id, legacy_failures_seen_until
from rpi.services.stop_confirm import stop_level_confirmed
from rpi.services.thinq.wording import dispatch_of
from rpi.services.readiness import (
    ApplianceReadiness,
    ReadinessCheck,
    ReadinessRegistry,
)

from rpi.commands import ControlRoute
from rpi.services import ApplianceButtonDef, ApplianceDef, BuiltinApplianceError
from rpi.services.appliance_registry import (
    ApplianceCategory,
    RevisionConflictError,
    category_from_legacy_icon,
)

from .deps import (
    builtin_appliances_visible,
    developer_mode_enabled,
    get_panel_scanner,
    get_presence_state_machine,
    get_clock,
    get_readiness_registry,
    get_wellness_pause,
    EnvironmentOverride,
    get_alert_store,
    get_appliance_registry,
    get_care_events,
    get_person_acks,
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
    PanelScanButtonModel,
    PanelScanCalibrationModel,
    PanelScanRequest,
    PanelScanResponse,
    ApplianceCalibrationRequest,
    ApplianceCalibrationResponse,
    PresenceDistanceRequest,
    PresenceStateResponse,
    PresenceTransitionModel,
    ApplianceButtonModel,
    ApplianceRegisterRequest,
    ApplianceResponse,
    AckRequest,
    AcksResponse,
    CareEventResponse,
    DemoCareEventRequest,
    ButtonStep,
    DemoAlertRequest,
    DemoOutletEstopRequest,
    DemoOutletEstopResponse,
    DemoApplianceDoneRequest,
    DemoApplianceDoneResponse,
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
    ReviseSuggestionRequest,
    PresenceRequest,
    PresenceResponse,
    SensorResponse,
    SettingSavedResponse,
    StatusResponse,
    StopResponse,
    EstopAckResponse,
    SuggestionResponse,
    LearningStatusResponse,
    SuggestionEventsResponse,
    SuppressionListResponse,
    UnmuteRequest,
)
from .service import (
    LlmNotConfiguredError,
    SimpleLayService,
    UnknownApplianceError,
)
from .readiness_view import readiness_view
from .stop_lane import resolve_without_shared_pool, run_on_stop_lane
from .thinq_router import command_payloads
from .thinq_router import router as thinq_router

log = logging.getLogger(__name__)

# 동기 DB·파일·네트워크 입출력을 하는 라우터는 ``def``(스레드풀)로 둔다 — ``async def`` 안에서 직접 부르면 단일 이벤트
# 루프가 그동안 멈춰 ``/stop`` 요청 자체가 처리되지 않는다(2026-10-14 HIGH 재확인 H-R2). async로 두려면 ``asyncio.to_thread``.
router = APIRouter()


def _to_steps(result: ExecutionResult) -> list[ButtonStep]:
    return [
        ButtonStep(button=b.button, success=b.status.value == "succeeded", attempts=b.attempts)
        for b in result.buttons
    ]


def result_detail_fields(result: ExecutionResult | None) -> dict:
    """/status·SSE 공통 — 재시도 합과 L3 판정(G1·G2, 2026-09-29).

    버튼 결과가 없으면(ThinQ 단계·예외 종료) 재시도 수를 0으로 지어내지 않고 None.
    """
    if result is None:
        return {"last_retry_count": None, "last_operation_confirmed": None,
                "last_operation_source": None, "last_operation_detail": None, "last_abort_reason": None}
    operation = getattr(result, "operation", None)
    return {
        "last_retry_count": (
            sum(max(0, b.attempts - 1) for b in result.buttons) if result.buttons else None
        ),
        "last_operation_confirmed": operation.passed if operation is not None else None,
        "last_operation_source": (
            ("mock" if getattr(operation, "mock", False) else "real")
            if operation is not None else None
        ),
        "last_operation_detail": (operation.detail or None) if operation is not None else None,
        # 2026-10-14: 모션 걸림 등으로 재시도 없이 멈춘 원인 — 눌림 확인 실패와 가른다.
        # 관측 미확인은 모션 알람이 아니다. 기존 폰의 '누르지 못함' 분류를 피한다.
        "last_abort_reason": (None if result.abort_reason == "press_unconfirmed" else result.abort_reason),
    }


# 실행 엔드포인트 3종은 모두 비동기 job 모델: 의도 해석(즉시 실패 가능)만
# 요청 안에서 끝내고, 물리 실행은 백그라운드로 넘긴 뒤 job_id를 즉시 반환한다.
# 진행·완료는 GET /status 폴링 + job_id 대조로 확인한다. (동기 실행은
# 실기기의 수 초~수십 초 시퀀스가 클라이언트 타임아웃(폰 8초·키오스크 4초)을
# 항상 초과하는 구조적 문제가 있었다.)


# 실행 대상 가전 게이트는 SimpleLayService._controller_for로 옮겼다 (R1).
# 라우터마다 검사를 붙이면 진입점이 늘 때마다 같은 구멍이 다시 생긴다 --
# 실제로 제안 승인 경로가 그렇게 빠져 있었다. 여기서는 서비스가 던진
# UnknownApplianceError를 HTTP 404로 옮기기만 한다.


async def _stop_phrase_response(service: SimpleLayService) -> JobAcceptedResponse:
    """정지어(G7) — ``POST /stop``과 같은 일을 하고 그 결과를 싣는다. 버튼은 누르지 않고 새 job도 만들지 않는다.

    ``job_id``는 멈춘 실행의 job(실행 중이었을 때 — 폰은 그 job의 정지 결과를 따라간다), 없으면 빈 문자열이다."""
    stop = await stop_everything(service)
    return JobAcceptedResponse(job_id=stop.stop_job_id or "", status="stopped", stop=stop)


def _not_understood_response(exc: UnknownIntentError):
    """해석 실패 422. 못 알아들은 말이면(2026-10-19) ``detail`` 옆에 후보·동작 목록을 싣는다::

        {"detail": "'공기청전기 켜 줘'를 알아듣지 못했어요",
         "suggestion": {"purpose": "공기청정기 켜줘", "label": "공기청정기 전원 켜기"} | null,
         "choices": [{"purpose": "공기청정기 켜줘", "label": "공기청정기 전원 켜기"}, ...]}

    ``suggestion``·``choices``는 **실행하지 않은 후보**다 — 고르면 클라이언트가 그 ``purpose``로 기존 경로(확인 → /execute)를
    다시 탄다. 그 밖의 해석 거절(상한 초과·정지어 등)은 종전처럼 ``detail``만."""
    if isinstance(exc, UnrecognizedPurposeError):
        return JSONResponse(status_code=422, content=exc.body())
    raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/execute", response_model=JobAcceptedResponse)
async def execute(
    body: ExecuteRequest,
    service: SimpleLayService = Depends(get_service),
) -> JobAcceptedResponse:
    # 안전 보고 G7(2026-10-16): 해석 **맨 앞**에서 정지어를 본다. 발화 전체가 "멈춰"·"그만"·"정지해줘" 같은 정지어면
    # POST /stop의 뜻이다 — 예전에는 규칙 별칭이 전자레인지 '취소' 버튼 누름으로 풀어 쉬는 중이면 실제로 눌렀다.
    # 판정 규칙(전체 일치·폰과 같은 목록·'취소'는 버튼 그대로)은 rpi/intent/stop_words.py 머리말.
    if is_stop_phrase(body.text):
        return await _stop_phrase_response(service)
    try:
        job_id = await asyncio.to_thread(
            service.submit_purpose, body.text, body.appliance_id
        )
    except UnknownIntentError as exc:
        return _not_understood_response(exc)
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
    # 정지어는 LLM보다 먼저 — POST /stop의 뜻(G7, /execute와 같다). LLM이 없어도 정지는 된다.
    if is_stop_phrase(body.text):
        return await _stop_phrase_response(service)
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
        return _not_understood_response(exc)
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return JobAcceptedResponse(job_id=job_id)


# ── 가전 레지스트리 — 폰·키오스크가 공유하는 가전 정의 ──────────────────────


def _to_appliance_response(a, service=None, nodes=None) -> ApplianceResponse:
    # 준비 상태는 **노드로 라우팅되는 가전**의 계약이다. 노드가 없는
    # 내장 가전은 종전대로 로컬에서 실행되므로 can_execute는 True다 --
    # 화면이 실행 버튼을 막을지 정할 때는 readiness가 아니라 이 값을 본다.
    # 화면이 보는 값과 서버가 실제로 거절하는 기준은 **같은 규칙**이어야
    # 한다. 어긋나면 누를 수 있는데 안 되는 버튼(또는 그 반대)이 생긴다.
    # GET /readiness도 같은 함수를 쓴다(2026-10-13).
    state, reasons, can_execute = readiness_view(a, service, nodes)
    return _appliance_response_base(
        a, readiness=state, readiness_reasons=reasons, can_execute=can_execute
    )


def _stop_park_fields(a) -> dict:
    """정지 대기·보관 필드(2026-09-30). 검증 결과를 함께 싣는다 — 저장 뒤 설정(리밋)이
    바뀌었으면 여기서 드러난다."""
    from rpi.services.stop_park import validate_stop_park  # noqa: PLC0415

    try:
        check = validate_stop_park(a).as_dict()
    except ValueError as exc:
        check = {"status": "invalid", "notes": [str(exc)]}
    return {
        "stop_button": a.stop_button,
        "stop_presses": a.stop_presses,
        "park_xy": None if a.park_xy is None else [a.park_xy[0], a.park_xy[1]],
        "stop_park_check": check,
        "panel_mapping": a.panel_mapping,
    }


def _appliance_response_base(
    a, *, readiness: str, readiness_reasons: list[str], can_execute: bool
) -> ApplianceResponse:
    return ApplianceResponse(
        id=a.appliance_id,
        name=a.name,
        # 종류가 진실원천이고, icon은 거기서 파생한 호환 출력이다.
        category=a.category.value,
        icon=a.icon,
        rows=a.rows,
        cols=a.cols,
        is_custom=a.is_custom,
        control_path=a.control_path.value,
        buttons=[
            ApplianceButtonModel(
                id=b.id,
                label=b.label,
                x=b.x,
                y=b.y,
                kind=b.kind.value,
                detents=b.detents,
                press_ms=b.press_ms,
                behavior=b.behavior,
                x_mm=b.x_mm,
                y_mm=b.y_mm,
            )
            for b in a.buttons
        ],
        revision=a.revision,
        functions={name: list(steps) for name, steps in a.functions},
        calibration_version=a.calibration_version,
        **_stop_park_fields(a),
        location=getattr(a, "location", None),
        readiness=readiness,
        readiness_reasons=readiness_reasons,
        can_execute=can_execute,
    )


@router.post("/demo/care-event", response_model=CareEventResponse)
def demo_care_event(
    body: DemoCareEventRequest,
    store=Depends(get_care_events),
) -> CareEventResponse:
    # 리허설 장치 — 시연에서 보호자 알림함·배지 장면을 원하는 시점에 연출
    default_messages = {
        "execution_failed": "'즉석밥 데워줘' 실행이 완료되지 못했어요. 가전을 확인해 주세요.",
        "emergency_stop": "'즉석밥 데워줘' 실행을 긴급 정지로 멈췄어요.",
        "danger_sound": "위험할 수 있는 신호음이 감지되었어요. 안부를 확인해 주세요.",
        "quiet_routine": "평소 저녁 시간대의 '즉석밥 데워줘' 사용이 오늘은 없었어요. "
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
def list_care_events(
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


def _acks_response(snap, care) -> AcksResponse:
    return AcksResponse(
        care_seen_id=snap.care_seen_id,
        failures_seen_id=snap.failures_seen_id,
        # 옛 앱 호환 시각 — 안 본 못 한 일을 덮지 않게 알림 목록으로 만든다(person_acks 머리말).
        failures_seen_until=legacy_failures_seen_until(snap, care.recent(limit=CARE_ACK_SCAN)),
        job_answers=dict(snap.job_answers),
    )


@router.get("/acks", response_model=AcksResponse)
def get_acks(acks=Depends(get_person_acks), care=Depends(get_care_events)) -> AcksResponse:
    """사람이 확인한 것(2026-10-19) — 폰 홈 못 한 일 경고·설정 탭 배지·키오스크 지난 일·가전 칸 표시가 같은 값을 읽는다."""
    return _acks_response(acks.snapshot(), care)


def _clamp_to_newest_care(event_id: int | None, care) -> int | None:
    """아직 없는 번호까지 '봤다'고 하면 앞으로 올 알림이 미리 지워진다 — 본체에 있는 가장 새 번호까지만."""
    if event_id is None:
        return None
    newest = care.recent(limit=1)
    return min(event_id, newest[0].event_id) if newest else 0


def _seen_jobs(body: AckRequest, history) -> list[str]:
    """화면에 보인 실행 기록만(검토 2026-10-19 #3). 커서 없는 옛 ``failures_seen``만 최근 기록 전체(호환)."""
    seen: list[str] = list(body.seen_job_ids or ())
    if body.seen_until_job_id is not None:
        recent = history.recent(limit=JOB_ACK_SCAN)
        mark = body.seen_until_job_id
        start = next((i for i, e in enumerate(recent)
                      if e.job_id == mark or base_job_id(e.job_id) == mark), None)
        # 본체 기록에 없는 번호면 아무것도 적지 않는다(무엇을 봤는지 모른다 — 다시 보이는 쪽).
        if start is not None:
            seen.extend(e.job_id for e in recent[start:])
    elif body.failures_seen and body.seen_job_ids is None:
        seen.extend(e.job_id for e in history.recent(limit=JOB_ACK_SCAN))
    return seen


@router.post("/acks", response_model=AcksResponse)
def post_acks(
    body: AckRequest,
    acks=Depends(get_person_acks),
    care=Depends(get_care_events),
    history=Depends(get_job_history),
) -> AcksResponse:
    """사람이 봤다·답했다를 적는다(모든 기기에서 사라지게). 화면에 보인 것만 — 새 실패는 아직 확인 전이라 다시 뜬다."""
    if (body.care_seen_id is None and not body.failures_seen and body.failures_seen_id is None
            and body.seen_job_ids is None and body.seen_until_job_id is None and body.job_id is None):
        raise HTTPException(status_code=422, detail="확인할 것을 하나 이상 보내 주세요")
    if body.answer is not None and body.job_id is None:
        raise HTTPException(status_code=422, detail="답에는 실행 번호(job_id)가 필요해요")
    failures_id = body.failures_seen_id
    if failures_id is None and body.failures_seen:
        # 옛 폰(커서 없음) 호환 — 본체에 있는 가장 새 못 한 일까지. 새 앱은 화면에 보인 번호를 싣는다.
        newest_failure = next((e for e in care.recent(limit=CARE_ACK_SCAN) if e.kind in FAILURE_CARE_KINDS), None)
        failures_id = newest_failure.event_id if newest_failure is not None else None
    snap = acks.change(
        care_seen_id=_clamp_to_newest_care(body.care_seen_id, care),
        failures_seen_id=_clamp_to_newest_care(failures_id, care),
        seen_job_ids=_seen_jobs(body, history),
        job_id=body.job_id,
        answer=body.answer,
    )
    return _acks_response(snap, care)


#: '기록 보기'가 '봤다'로 적는 최근 실행 기록 수(``person_acks.JOB_LIMIT``와 같은 폭).
JOB_ACK_SCAN = 200
#: 못 한 일 번호·옛 앱 호환 시각을 고를 때 보는 보호자 알림 수(``CareEventStore.MEMORY_LIMIT``와 같은 폭).
CARE_ACK_SCAN = 200


@router.get("/appliances", response_model=list[ApplianceResponse])
def list_appliances(
    registry=Depends(get_appliance_registry),
    service: SimpleLayService = Depends(get_service),
    nodes: NodeRegistry = Depends(get_node_registry),
) -> list[ApplianceResponse]:
    """내장 + 커스텀 가전 전체. 폰에서 등록한 가전이 키오스크에 뜨는 경로.

    준비 상태(F1)도 여기 함께 실어 보낸다 -- 폰과 키오스크가 **같은**
    상태와 같은 사유를 보게 하려면 한 곳에서 나와야 한다.

    서버 구성 가전 중 ThinQ 가전도 여기 함께 실어 보낸다(G5) --
    ``control_path``로 경로를 밝히므로 화면이 버튼 격자가 없는 가전을
    구분할 수 있다. ThinQ 연동이 꺼져 있으면 등록 자체가 없어 목록도
    종전과 같다.
    """
    from rpi.services.appliance_registry import BUILTIN_APPLIANCES  # noqa: PLC0415

    # 내장 가전은 개발자 모드·리허설 런처에서만 보인다(UI 확정 §1-6).
    hidden = (
        frozenset()
        if builtin_appliances_visible()
        else frozenset(b.appliance_id for b in BUILTIN_APPLIANCES)
    )
    return [
        _to_appliance_response(a, service, nodes)
        for a in tuple(x for x in registry.list() if x.appliance_id not in hidden)
        + tuple(
            # 서버 구성 가전 중 ThinQ 경로만 얹는다(G5). 모의 물리 가전(선풍기 등)은
            # 폰 편집기가 덮거나 지울 수 없는 것이라 종전대로 숨긴다.
            s for s in registry.system_appliances()
            if s.control_path is ControlRoute.THINQ
        )
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
def set_wellness_pause(
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
def clear_wellness_pause(
    pause=Depends(get_wellness_pause),
) -> WellnessPauseResponse:
    pause.clear()
    return WellnessPauseResponse(paused=False)


@router.post("/readiness/{appliance_id}", response_model=OkResponse)
def report_readiness(
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
def register_appliance(
    appliance_id: str,
    body: ApplianceRegisterRequest,
    registry=Depends(get_appliance_registry),
    service: SimpleLayService = Depends(get_service),
    nodes: NodeRegistry = Depends(get_node_registry),
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
        stop_button=body.stop_button,
        stop_presses=body.stop_presses if body.stop_presses is not None else 1,
        park_xy=(
            (float(body.park_xy[0]), float(body.park_xy[1]))
            if body.park_xy is not None and len(body.park_xy) == 2
            else None
        ),
    )
    if not appliance.appliance_id:
        raise HTTPException(status_code=422, detail="appliance id must not be blank")
    # 정지 대기·보관 검증(2026-09-30) — 저장될 모양(보정 좌표·정지 설정 이어받기 뒤)으로 본다.
    from rpi.services.appliance_registry import merge_for_save  # noqa: PLC0415
    from rpi.services.stop_park import validate_stop_park  # noqa: PLC0415

    if body.park_xy is not None and len(body.park_xy) != 2:
        raise HTTPException(status_code=422, detail="park_xy는 [x, y] 두 값이어야 해요")
    try:
        existing = registry.get(appliance.appliance_id)
        # 놓인 곳(방): 보낸 값이 이긴다(빈 문자열은 지움). 보내지 않은 옛 폰은 저장된 값을 이어받는다(2026-10-19).
        if "location" in body.model_fields_set:
            appliance = replace(appliance, location=body.location or None)
        elif existing is not None and existing.is_custom:
            appliance = replace(appliance, location=existing.location)
        validate_stop_park(
            merge_for_save(existing if existing is not None and existing.is_custom else None, appliance)
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
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
    # 목록(GET /appliances)과 같은 규칙으로 준비 상태를 싣는다 — 서비스 없이 만들면 '실행 가능'으로
    # 나가 놓고 승인하면 412가 났다(2026-10-06, 시연 v3 갭 S2).
    return _to_appliance_response(saved, service, nodes)


@router.put(
    "/appliances/{appliance_id}/calibration",
    response_model=ApplianceCalibrationResponse,
)
def calibrate_appliance(
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
    # 요청은 기준을 **더 엄격하게만** 할 수 있다. 상한을 올릴 수 있으면
    # 큰 값을 보내는 것만으로 오차 검증이 사라져, 잘못 찍은 기준점으로 만든
    # 좌표가 그대로 저장된다.
    from rpi.calibration.transform import (  # noqa: PLC0415
        DEFAULT_MAX_POINT_ERROR_MM,
        DEFAULT_MAX_RMS_MM,
    )

    # 0이나 음수는 기본값으로 갈아끼우지 않는다 -- 잘못된 값을 조용히 고치면
    # 호출부는 자기가 보낸 기준으로 저장됐다고 믿는다. transform이 거절(422)한다.
    options = {
        "max_rms_mm": (
            min(body.max_rms_mm, DEFAULT_MAX_RMS_MM)
            if body.max_rms_mm is not None
            else DEFAULT_MAX_RMS_MM
        ),
        "max_point_error_mm": (
            min(body.max_point_error_mm, DEFAULT_MAX_POINT_ERROR_MM)
            if body.max_point_error_mm is not None
            else DEFAULT_MAX_POINT_ERROR_MM
        ),
    }
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


class _PanelScanGate:
    """사진 인식은 한 번에 하나만, 그리고 한 시간에 정해진 횟수까지만.

    - 한 번에 하나: 두 번 누르면 크레딧만 두 번 나간다.
    - 시간당 상한: API 키가 기본으로 꺼져 있어 같은 망의 누구든 반복 호출로
      공유 크레딧을 소진시킬 수 있다. 인식 서비스로 **보내려 한 시도**를 센다 --
      연결 실패·서비스 오류도 포함한다(실패를 반복해 상한을 우회하지 못하게).
      상한 0은 '끔'이다.

    프로세스 안의 상태라 워커가 여럿이면 워커마다 따로 센다(서버는 단일 워커 전제).
    """

    WINDOW_SECONDS = 3600.0
    DEFAULT_MAX_PER_HOUR = 20

    def __init__(self, clock=time.monotonic) -> None:
        self.busy = False
        self.clock = clock
        self._sent: deque[float] = deque()

    def max_per_hour(self) -> int:
        """0이면 끔. 비었거나 음수·숫자가 아니면 기본값.

        0을 기본값으로 바꾸면 끄려고 적은 설정이 오히려 시간당 20번을 연다.
        """
        raw = os.environ.get("SIMPLELAY_VISION_MAX_PER_HOUR", "").strip()
        try:
            value = int(raw) if raw else self.DEFAULT_MAX_PER_HOUR
        except ValueError:
            return self.DEFAULT_MAX_PER_HOUR
        return value if value >= 0 else self.DEFAULT_MAX_PER_HOUR

    def reserve(self) -> bool:
        """이번 요청을 한도 안에서 예약한다. 한도를 넘었으면 False."""
        now = self.clock()
        while self._sent and now - self._sent[0] >= self.WINDOW_SECONDS:
            self._sent.popleft()
        if len(self._sent) >= self.max_per_hour():
            return False
        self._sent.append(now)
        return True

    def reset(self) -> None:
        self.busy = False
        self._sent.clear()


_panel_scan_gate = _PanelScanGate()

#: 사진 인식 초안에는 누를 자리가 아직 없다 — 다음 단계에서 버튼판 네 귀퉁이를 고르면 정해진다.
PANEL_SCAN_NO_POSITION_NOTE = "누를 자리는 아직 정하지 않았어요 — 다음 단계에서 사진 속 버튼판 네 귀퉁이를 고르면 정해져요"


@router.post("/panel-scan", response_model=PanelScanResponse)
async def panel_scan(
    body: PanelScanRequest,
    scanner=Depends(get_panel_scanner),
) -> PanelScanResponse:
    """조작부 사진 → 버튼맵 **초안**. 저장하지 않는다 — 사람이 확인한 뒤 PUT /appliances/{id}.

    설치 때 한 번 쓰는 선택 기능이라 설정이 없으면 503으로 꺼져 있음을 알린다.
    인식 서비스 응답은 믿지 않는 입력으로 검증한다(rpi/vision/panel_scan.py).
    사진은 저장하거나 로그에 남기지 않는다.
    """
    from rpi.calibration import CalibrationRejected, PointPair  # noqa: PLC0415
    from rpi.services.appliance_registry import MM_RANGE  # noqa: PLC0415
    from rpi.vision import (  # noqa: PLC0415
        PanelScanError,
        VisionUnavailable,
        build_draft,
        map_draft_to_mm,
        parse_controls,
    )

    if scanner is None:
        raise HTTPException(
            status_code=503,
            detail="사진 인식이 꺼져 있어요 — 서버에 인식 서비스 설정이 필요해요",
        )
    image, mime = body.image()
    # 확인과 표시 사이에 await가 없어 이벤트 루프 안에서 원자적이다
    if _panel_scan_gate.max_per_hour() == 0:
        raise HTTPException(
            status_code=503,
            detail="사진 인식이 설정으로 꺼져 있어요 — 서버의 호출 상한이 0이에요",
        )
    if _panel_scan_gate.busy:
        raise HTTPException(
            status_code=409,
            detail="이미 사진을 인식하는 중이에요 — 끝난 뒤 다시 시도해 주세요",
        )
    if not _panel_scan_gate.reserve():
        raise HTTPException(
            status_code=429,
            detail=(
                f"사진 인식은 한 시간에 {_panel_scan_gate.max_per_hour()}번까지예요"
                " — 잠시 후 다시 시도해 주세요"
            ),
        )
    _panel_scan_gate.busy = True
    try:
        raw = await asyncio.to_thread(scanner.describe_panel, image, mime)
    except VisionUnavailable as exc:
        # 연결 불가·크레딧·한도는 '지금은 못 쓴다'(503), 인증·서비스 오류는 게이트웨이 문제(502)
        status = 503 if exc.status in (None, 402, 429) else 502
        raise HTTPException(status_code=status, detail=str(exc)) from exc
    finally:
        _panel_scan_gate.busy = False

    try:
        controls, dropped = parse_controls(raw)
        draft = build_draft(controls, dropped)
    except PanelScanError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    mapped: dict[str, tuple[float, float]] = {}
    calibration = None
    if body.reference_points:
        try:
            result, mapped = map_draft_to_mm(
                draft,
                [PointPair(p.source, p.target) for p in body.reference_points],
                kind=body.kind,
                mm_range=MM_RANGE,
            )
        except (CalibrationRejected, PanelScanError, ValueError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        calibration = PanelScanCalibrationModel(
            version=result.version,
            kind=result.transform.kind,
            point_count=result.point_count,
            redundant_points=result.redundant_points,
            rms_error_mm=result.rms_error_mm,
            max_error_mm=result.max_error_mm,
        )

    notes = ["인식 결과는 초안이에요 — 이름과 위치를 확인한 뒤 저장해 주세요"]
    unnamed = sum(1 for b in draft.buttons if not b.label_from_model)
    if unnamed:
        notes.append(f"이름을 읽지 못한 버튼 {unnamed}개에 임시 이름을 붙였어요")
    dials = [b.label for b in draft.buttons if b.kind == "dial"]
    if dials:
        notes.append(f"다이얼({', '.join(dials)})은 딸깍 수를 입력해야 저장할 수 있어요")
    if not mapped:
        # 폰에 그대로 보인다 — '좌표(mm)·기준점 보정' 대신 다음 단계(버튼판 귀퉁이 고르기)를 말한다(2026-10-19).
        notes.append(PANEL_SCAN_NO_POSITION_NOTE)

    return PanelScanResponse(
        rows=draft.rows,
        cols=draft.cols,
        buttons=[
            PanelScanButtonModel(
                id=b.id,
                label=b.label,
                x=b.x,
                y=b.y,
                kind=b.kind,
                box=list(b.box),
                center=list(b.center),
                label_from_model=b.label_from_model,
                x_mm=mapped[b.id][0] if b.id in mapped else None,
                y_mm=mapped[b.id][1] if b.id in mapped else None,
            )
            for b in draft.buttons
        ],
        dropped=list(draft.dropped),
        notes=notes,
        model=scanner.model,
        calibration=calibration,
    )


@router.delete("/appliances/{appliance_id}", response_model=OkResponse)
def delete_appliance(
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

    # 가전은 이미 지워졌다 — 뒷정리 실패로 500을 주면 '안 지워졌다'로 읽히고, 다시 지우면 404라 뒷정리를 다시 해 볼 길도
    # 없다(검토 10/19 #9). 실패는 단계마다 로그로 남기고(``_cleanup_after_delete``) 삭제는 성공으로 답한다. 각 단계는 다시
    # 불러도 같은 결과다(없는 노드·카드·판정을 지우는 것).
    try:
        _cleanup_after_delete(appliance_id, nodes, suggestions, readiness)
    except Exception:  # noqa: BLE001
        log.exception("cleanup after deleting appliance %r was incomplete", appliance_id)
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
    response = StatusResponse(
        running=snapshot.running,
        developer_mode=developer_mode_enabled(),
        last_status=snapshot.last_result.status.value if snapshot.last_result else None,
        last_outcome=outcome_of(snapshot.last_result).value if snapshot.last_result else None,
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
        execution_mode=snapshot.execution_mode.value,
        last_execution_mode=snapshot.last_execution_mode.value,
        **result_detail_fields(snapshot.last_result),
    )
    from rpi.routines.wiring import last_auto_run_if_any  # noqa: PLC0415
    from rpi.services.stop_park import hold_status_fields  # noqa: PLC0415

    estop = service.estop_status() or {}
    return response.model_copy(
        update={**command_status_fields(snapshot), **hold_status_fields(service.hold_status()),
                "estop_latched": estop.get("latched"),
                "estop_detail": estop.get("detail") if estop.get("latched") else None,
                "actuator_link_up": service.actuator_link_up(),
                "last_auto_run": last_auto_run_if_any(),
                **_last_stop_fields(service)}
    )


def _last_stop_fields(service: SimpleLayService) -> dict:
    """마지막 긴급 정지의 모션 확인 단계(2026-10-13). 보고 수단이 없는 서비스·대역이면 비운다."""
    reader = getattr(service, "last_motion_stop", None)
    stop = reader() if callable(reader) else None
    if not isinstance(stop, dict):
        return {"last_stop_level": None, "last_stop_ack_ms": None, "last_stop_job_id": None}
    return {"last_stop_level": stop.get("stop_level"), "last_stop_ack_ms": stop.get("ack_ms"),
            "last_stop_job_id": stop.get("job_id")}


@router.post("/stop/ack", response_model=EstopAckResponse)
async def acknowledge_estop(
    service: SimpleLayService = Depends(get_service),
) -> EstopAckResponse:
    """콘센트 모듈 비상정지 걸림 해제 확인(2026-10-05). 사람이 버튼을 풀고 누른다.

    RPi4는 모듈 버튼이 아직 눌려 있으면 풀지 않는다 — 그때는 ok=false·latched=true와 사유를 돌려준다.
    걸림을 보고하지 않는 실행기(로컬 모의 등)면 409, RPi4가 답하지 않으면 504.
    """
    from rpi.services.act_client import ActLinkTimeoutError  # noqa: PLC0415

    try:
        state = await asyncio.to_thread(service.acknowledge_estop)
    except ActLinkTimeoutError as exc:
        raise HTTPException(status_code=504, detail="누름 장치가 해제 확인에 답하지 않았어요") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    latched = state.get("latched") is not False
    reason = state.get("reason") if isinstance(state.get("reason"), str) else None
    detail = state.get("detail") if isinstance(state.get("detail"), str) else None
    return EstopAckResponse(ok=not latched, latched=latched, reason=reason, detail=detail)


async def _stop_service(request: Request) -> SimpleLayService:
    """정지 경로의 서비스 의존성 — 공유 스레드 풀을 쓰지 않는다(HIGH 재확인 2차 H-RR1, ``stop_lane``)."""
    return await resolve_without_shared_pool(request, get_service)


#: ``POST /stop``이 루틴에 붙이는 정지 사유 — 루틴 문장은 "{사유}으로 남은 단계를 보내지 않았어요".
ROUTINE_STOP_REASON = "긴급 정지 요청"


@router.post("/stop", response_model=StopResponse)
async def emergency_stop(
    service: SimpleLayService = Depends(_stop_service),
) -> StopResponse:
    return await stop_everything(service)


async def stop_everything(service: SimpleLayService) -> StopResponse:
    """``POST /stop``의 뜻 그대로 — 실행·개발자 세션·자동 실행·루틴을 멈춘다. 텍스트·홈 음성의 정지어(G7)도 여기로 온다."""
    # 노드 정지 브로드캐스트는 응답 없는 노드를 전체 상한까지 기다리는 동기
    # 호출이다. 이벤트 루프에서 직접 부르면 그동안 /status·SSE·다른 API가
    # 전부 멈춘다 — 스레드로 넘긴다.
    #
    # HIGH 재확인 2차 H-RR1: 그 스레드는 **정지 전용 실행기**(``stop_lane``)다. ``asyncio.to_thread``(루프 기본 실행기)와
    # FastAPI의 ``def`` 의존성(AnyIO 기본 토큰)은 일반 DB 요청과 같이 쓰는 풀이라, DB가 멈춘 동안 그 풀이 차면 정지가
    # 줄을 섰다. 인증(``require_api_key``)과 서비스 의존성(``_stop_service``)도 async라 공유 풀을 쓰지 않는다.
    #
    # 개발자 세션도 같은 버튼으로 멈춘다 — 긴급 정지는 "누가 제어 중인가"를
    # 가리지 않는다. 모드가 꺼져 있으면 no-op이고, 개발자 쪽 정지 실패는
    # fault로 잠근 뒤 삼킨다(일반 정지 응답을 막지 않는다). 노드 브로드캐스트를
    # 기다렸다 보내지 않고 동시에 보낸다: 두 경로는 서로의 락을 잡지 않는다.
    from rpi.api.deps import stop_developer_session_if_any  # noqa: PLC0415

    from rpi.routines.wiring import (  # noqa: PLC0415
        halt_auto_rules_if_any,
        halt_routines_if_any,
        stop_auto_rules_if_any,
        stop_routines_if_any,
    )

    # 진행 중인 루틴에 정지 표시를 **맨 앞에서** 세운다(2026-10-16 안전 보고 G3). 메모리 표시뿐이라 입출력이 없다 —
    # 모션 정지를 늦추지 않는다. 예전에는 루틴 취소가 아래 실행 정지(RPi4 정지 보고를 최대 수 초 기다림) **뒤**라, 구간 사이에
    # 온 정지를 루틴이 못 보고 다음 구간을 보냈다. 루틴은 다음 구간의 실행 시작 게이트에서도 이 표시를 본다(runner.py).
    halt_routines_if_any(ROUTINE_STOP_REASON)
    # 자동 실행 허용 규칙(2026-10-13): 판단은 끝났지만 아직 실행 게이트를 지나지 않은 자동 실행을 먼저 막는다.
    # 세대만 올려 입출력이 없다 — 모션 정지를 늦추지 않는다. 규칙 끄기는 아래에서 함께 한다: 메모리에서 바로 꺼지고
    # DB 쓰기·알림함 기록은 뒤에서 한다(4차 평가 M-N3) — 이 응답은 규칙 DB 쓰기를 기다리지 않는다.
    halt_auto_rules_if_any()
    # 정지 버튼 위 대기 중이면 이 정지는 정지 버튼 누름으로 전달된다(RPi4가 판단·수행).
    hold_before = service.hold_status() or {}
    report, _, _ = await asyncio.gather(
        run_on_stop_lane(service.emergency_stop_report),
        run_on_stop_lane(stop_developer_session_if_any, "emergency_stop"),
        run_on_stop_lane(stop_auto_rules_if_any, "비상정지"),
    )
    # 끝을 기다리던 루틴도 멈춘다 — 해제 뒤 다음 단계가 이어서 나가지 않게(평가 B5). 표시는 맨 앞에서 이미 세웠다 —
    # 여기서는 로그를 남기고, 그 사이 새로 시작한 루틴(카드 승인과 겹침)도 멈춘다.
    await run_on_stop_lane(stop_routines_if_any, ROUTINE_STOP_REASON)
    return StopResponse(
        was_running=report.was_running,
        nodes_requested=len(report.nodes_acknowledged)
        + len(report.nodes_unconfirmed),
        nodes_acknowledged=list(report.nodes_acknowledged),
        nodes_unconfirmed=list(report.nodes_unconfirmed),
        cloud_cancelled=list(report.cloud_cancelled),
        cloud_uncancellable=list(report.cloud_uncancellable),
        appliance_stop_requested=hold_before.get("hold_state") in ("hovering_stop", "stopping"),
        hold_state_at_request=hold_before.get("hold_state"),
        stop_level=report.motion_stop_level,
        stop_ack_ms=report.motion_stop_ack_ms,
        stop_target=report.motion_stop_target,
        stop_confirmed=stop_level_confirmed(report.motion_stop_level),
        stop_detail=report.motion_stop_detail,
        stop_job_id=report.job_id,
    )


@router.get("/suggestions/events", response_model=SuggestionEventsResponse)
async def suggestion_events(
    limit: int = Query(100, ge=1, le=200),
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> dict:
    return await asyncio.to_thread(svc.feedback_events, limit)


@router.get("/learning", response_model=LearningStatusResponse)
async def learning_status(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> dict:
    return await asyncio.to_thread(svc.learning_status)


@router.get("/suggestions", response_model=list[SuggestionResponse])
async def list_suggestions(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> list[SuggestionResponse]:
    pending = await asyncio.to_thread(svc.pending)
    offers = await asyncio.to_thread(_auto_rule_offers, pending)
    return [
        SuggestionResponse(
            auto_rule_offer=offers.get(s.suggestion_id),
            is_demo=s.is_demo or s.time_band == "데모",
            id=s.suggestion_id,
            purpose=s.purpose,
            time_band=s.time_band,
            occurrences=s.occurrences,
            steps=list(s.steps),
            reason=s.reason,
            appliance_id=s.appliance_id,
            scenario_id=s.scenario_id,
            commands=command_payloads(s),
            routine_id=s.routine_id,
            routine_name=s.routine_name,
        )
        for s in pending
    ]


def _auto_rule_offers(pending) -> dict[str, dict]:
    """카드별 '다음부터도 자동으로' 내용. 시나리오 카드가 아니면 묻지도 않는다. 실패는 버튼 없음(목록은 그대로)."""
    if not any(s.scenario_id for s in pending):
        return {}
    try:
        from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

        engine = get_auto_rule_engine()
        return {s.suggestion_id: offer for s in pending
                if s.scenario_id and (offer := engine.offer_payload(s)) is not None}
    except Exception:  # noqa: BLE001
        log.exception("auto rule offers failed")
        return {}


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
def reject_suggestion(
    suggestion_id: str,
    body: RejectSuggestionRequest | None = None,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    try:
        svc.reject(suggestion_id, mute=body.mute if body is not None else False)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    return OkResponse()


@router.post("/suggestions/{suggestion_id}/snooze", response_model=OkResponse)
def snooze_suggestion(
    suggestion_id: str,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    try:
        svc.snooze(suggestion_id)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    return OkResponse()


@router.get("/suggestions/{suggestion_id}/revision-options")
async def suggestion_revision_options(
    suggestion_id: str,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> dict:
    try:
        return {"options": await asyncio.to_thread(svc.revision_options, suggestion_id)}
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")


@router.post("/suggestions/{suggestion_id}/revise", response_model=SuggestionResponse)
async def revise_suggestion(
    suggestion_id: str,
    body: ReviseSuggestionRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> SuggestionResponse:
    try:
        s = await asyncio.to_thread(svc.revise, suggestion_id, body.purpose)
    except UnknownSuggestionError:
        raise HTTPException(status_code=404, detail="suggestion not found")
    except UnknownIntentError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return SuggestionResponse(id=s.suggestion_id, purpose=s.purpose,
                              time_band=s.time_band, occurrences=s.occurrences,
                              steps=list(s.steps), reason=s.reason,
                              appliance_id=s.appliance_id,
                              is_demo=s.is_demo or s.time_band == '데모')


@router.get("/suppressions", response_model=SuppressionListResponse)
def list_suppressions(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> SuppressionListResponse:
    return SuppressionListResponse(purposes=list(svc.muted_purposes()))


@router.post("/suppressions/unmute", response_model=OkResponse)
def unmute_suppression(
    body: UnmuteRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> OkResponse:
    svc.unmute(body.purpose)
    return OkResponse()


@router.post("/demo/suggest", response_model=SuggestionResponse)
def demo_suggest(
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
        is_demo=suggestion.is_demo or suggestion.time_band == "데모",
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
            is_demo=s.is_demo or s.time_band == "데모",
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
def history(
    limit: int = 50,
    store=Depends(get_job_history),
) -> list[HistoryEntryResponse]:
    from rpi.routines.auto_rules import display_purpose  # noqa: PLC0415

    # 실행 이력(최신순) — 공감지능의 근거 데이터와 폐루프 재시도 기록을
    # 사용자에게 그대로 보여준다. limit은 1~200으로 클램프.
    limit = max(1, min(limit, 200))
    return [
        HistoryEntryResponse(
            job_id=e.job_id,
            finished_at=e.finished_at,
            # 저장값은 그대로 두고 보여 줄 때만 지금 문체로(옛 질문 문장·옛 자동 실행 동작 문장, 10/18 쉬운 말 3차).
            purpose=display_purpose(e.purpose),
            status=e.status,
            retry_count=e.retry_count,
            appliance_id=e.appliance_id,
            execution_mode=e.execution_mode.value,
            termination=e.termination.value,
            outcome=e.effective_outcome,
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
            route=e.route,
            receipt=e.receipt,
            confirmation=e.confirmation,
            dispatch=dispatch_of(e.receipt, e.confirmation),
            detail=e.detail,
            operation_confirmed=e.operation_confirmed,
            operation_detail=e.operation_detail,
            abort_reason=None if e.abort_reason == "press_unconfirmed" else e.abort_reason,
            appliance_name=e.appliance_name,
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
def history_export(
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
def demo_inject_failure(
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
def demo_clear_failure(
    state=Depends(get_demo_failure_state),
    service: SimpleLayService = Depends(get_service),
) -> OkResponse:
    state.disarm()
    service.clear_forwarded_demo_failure()
    return OkResponse()


@router.post("/dnd", response_model=SettingSavedResponse)
async def set_dnd(
    body: DndRequest,
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> SettingSavedResponse:
    # HIGH 재확인 H-R2: 메모리 적용(입출력 없음)은 바로, DB 저장은 이벤트 루프 밖에서 — 저장이 멈춰도 /stop이 처리된다.
    _, version = svc.apply_dnd_for(body.duration_minutes)
    return SettingSavedResponse.of(await asyncio.to_thread(svc.persist_pause, version))


@router.delete("/dnd", response_model=SettingSavedResponse)
async def clear_dnd(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
) -> SettingSavedResponse:
    version = svc.apply_clear_dnd()
    return SettingSavedResponse.of(await asyncio.to_thread(svc.persist_pause, version))


# ── 조용한 시간(2026-10-14, 5번 정책 b) — 매일 시간대 + 잠시 쉬기를 한 판정으로 ─────────────


@router.get("/quiet-hours")
async def get_quiet_hours_status() -> dict:
    """``{enabled, start, end, active, reason(schedule|pause|null), pause_until, scope}`` — 키오스크는 /health의 ``quiet``."""
    from .deps import build_off_loop, get_quiet_hours, get_suggestion_service, quiet_status  # noqa: PLC0415

    await build_off_loop(get_quiet_hours, get_suggestion_service)  # 최초 생성(DB 읽기)은 루프 밖에서(외부 재확인 3차)
    return quiet_status()


@router.put("/quiet-hours")
async def put_quiet_hours(body: dict = Body(...)) -> dict:
    """``{"enabled": bool, "start": "HH:MM", "end": "HH:MM"}``(일부만 보내도 된다). 서버에 영속.

    HIGH 재확인 H-R1·M-R1: 메모리에 먼저 적용하고(판정은 바로 새 값) 저장은 이벤트 루프 밖에서. 응답에 저장 결과
    ``persisted``·``session_only``(``POST /dnd``와 같은 뜻)를 함께 싣는다.

    HIGH 재확인 2차 M-RR2: 응답의 설정 값은 **저장 결과가 가리키는 그 사본**이다(``persist_report``). 저장을 기다리는 사이
    다른 요청이 메모리를 바꿨으면, 그 지금 값에 이 요청의 저장 성공을 붙이지 않는다 — 값과 ``persisted``가 같은 판을
    말한다. 지금 값은 ``GET /quiet-hours``로 본다."""
    from rpi.services.quiet_hours import QuietHoursError  # noqa: PLC0415

    from .deps import build_off_loop, get_quiet_hours, get_suggestion_service, quiet_status  # noqa: PLC0415

    await build_off_loop(get_quiet_hours, get_suggestion_service)  # 최초 생성(DB 읽기)은 루프 밖에서(외부 재확인 3차)
    quiet = get_quiet_hours()
    try:
        _, version = quiet.apply(body)
    except QuietHoursError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    result, settings = await asyncio.to_thread(quiet.persist_report, version)
    saved = SettingSavedResponse.of(result)
    return {**quiet_status(settings), "persisted": saved.persisted, "session_only": saved.session_only}


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
def register_node(
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
def unregister_node(
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
        # 정지 요청으로 멈춤(stopped)과 실패(failed·safety_stop)를 가른다 —
        # last_status의 safety_stopped는 둘을 뭉갠다. 옛 클라이언트는 무시한다.
        "last_outcome": (
            outcome_of(snap.last_result).value if snap.last_result else None
        ),
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
        # 재시도 합·L3 판정(G1·G2) — GET /status와 같은 값.
        **result_detail_fields(snap.last_result),
        # 명령 계약(U1-a): 경로·수신·확인 근거. ThinQ 미확인은 실패가 아니다.
        **command_status_fields(snap),
    }


def command_status_fields(snap) -> dict:
    """/status·SSE 공통 — 제어 경로와 확인 수준. ThinQ 결과면 상태 문자열도 계약 값으로.

    ThinQ의 ``unconfirmed``(보냈지만 확인 못 함)를 ``failed``로 적으면 사용자가 다시
    보내 중복 실행이 된다(계약 §3). 물리 결과의 last_status는 종전 그대로 둔다 — 단, 물리 실행이 실행 대상 예외
    (링크 끊김 등)로 끝나 눌렸는지 모르는 경우(``unconfirmed``, 2026-10-15 G1·G5)는 같은 이유로 ``unconfirmed``로 올린다.
    ``failed``로 두면 폰·키오스크가 '끝까지 실행하지 못했어요'·'다시 시도'로 읽는다(이미 다 눌렀을 수 있다).
    """
    fields = {
        "route": snap.route,
        "last_route": snap.last_route,
        "last_receipt": snap.last_receipt,
        "last_confirmation": snap.last_confirmation,
        "last_detail": snap.last_detail,
    }
    if snap.last_command_status is not None and (
            snap.last_route == "thinq" or snap.last_command_status == "unconfirmed"):
        fields["last_status"] = snap.last_command_status
        fields["last_outcome"] = {
            "succeeded": "success", "stopped": "stopped",
            "failed": "failed", "unconfirmed": "unconfirmed",
        }[snap.last_command_status]
    return fields


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


#: /demo/alert를 열어 두는 실행 환경 — 기본(mock)과 시뮬레이터뿐이다.
_DEMO_ALERT_MODES = ("", "mock", "simulator")


UART_REHEARSAL_ENV = "SIMPLELAY_UART_REHEARSAL"


def uart_rehearsal_enabled() -> bool:
    """UART 모드 리허설 스위치(2026-10-06) — RPi5에서 명시적으로 켜야 한다. 켜도 RPi4가 가짜 콘센트·모의 모션이라고
    ``act_info``로 알린 때만 주입이 나간다(RPi4도 한 번 더 거절한다)."""
    return (os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower() == "uart"
            and os.environ.get(UART_REHEARSAL_ENV, "").strip().lower() in ("1", "true", "yes", "on"))


def demo_alert_allowed() -> bool:
    """주입을 열어도 되는 실행 환경인가.

    ``SIMPLELAY_ACT_MODE=uart``면 경보는 RPi4의 실제 감지 결과다. 그 위에
    가짜 경보를 얹으면 화면의 '위험 소리 감지'가 무엇을 근거로 켜졌는지
    구분할 수 없게 된다 -- 모의 ThinQ 장애 주입을 mock 모드에만 연 것과
    같은 이유다.
    """
    return os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower() in _DEMO_ALERT_MODES


@router.post("/demo/alert", response_model=AlertResponse)
async def demo_alert(
    body: DemoAlertRequest,
    store: DangerAlertStore = Depends(get_alert_store),
) -> AlertResponse:
    """리허설 장치(G13) — 위험 소리 경보를 UART 경로와 **같은 자리**에 넣는다.

    RPi4의 자체발신 프레임을 받는 ``DangerAlertStore.record``를 그대로 부르므로
    ``GET /alerts`` 스냅샷·SSE ``alert`` 이벤트·보호자 알림(상승 에지)이 실제
    경보와 똑같이 흐른다. 모의·시뮬레이터 모드 밖에서는 404다.
    """
    if not demo_alert_allowed():
        raise HTTPException(404, "경보 주입은 모의·시뮬레이터 모드에서만 열려 있어요")
    await asyncio.to_thread(
        store.record,
        AlertEvent(
            kind=body.kind,
            raised=body.raised,
            band_energy_ratio=body.band_energy_ratio,
            mean_period_seconds=body.mean_period_seconds,
        ),
    )
    state = store.current()
    return AlertResponse(
        active=state.active,
        kind=state.kind,
        band_energy_ratio=state.band_energy_ratio,
        mean_period_seconds=state.mean_period_seconds,
        updated_at=state.updated_at,
    )


# 10/18 쉬운 말: 연습 장치 문장도 결과 한 줄 + 사실 한 줄('시연'·'모의'·'모듈'·'릴레이'·괄호를 쓰지 않는다).
_REHEARSAL_ESTOP_DETAIL = "연습용 비상 버튼을 눌렀어요. 실제 전기 플러그는 그대로예요."


def _require_rehearsal_mode() -> None:
    """모의·시뮬레이터 모드가 아니면 404. 서비스 의존성보다 **먼저** 둔다 — UART 모드에서 시리얼을 열지 않는다.
    UART 모드는 ``SIMPLELAY_UART_REHEARSAL=1``일 때만 연다(그다음 RPi4 구성은 `_uart_rehearsal_controller`가 본다)."""
    if not demo_alert_allowed() and not uart_rehearsal_enabled():
        raise HTTPException(404, "비상 버튼 주입은 모의·시뮬레이터 모드(또는 UART 리허설 스위치)에서만 열려 있어요")


def _uart_rehearsal_controller(service: SimpleLayService):
    """UART 리허설: RPi4가 가짜 콘센트(또는 없음)·모의 모션이라고 알렸을 때만 그 실행기를 돌려준다. 아니면 409."""
    controller = getattr(service, "_controller", None)
    status_fn = getattr(controller, "rehearsal_status", None)
    status = status_fn() if callable(status_fn) else {}
    if status.get("rehearsal") is not True:
        raise HTTPException(
            409,
            "RPi4가 실물 콘센트 모듈·모션 MCU에 붙어 있거나 구성을 아직 알리지 않았어요 — "
            "리허설은 RPi4를 SIMPLELAY_OUTLET_PORT=fake(또는 없음)·SIMPLELAY_MOTION_MODE=mock으로 띄워야 해요",
        )
    return controller


def _rehearsal_estop_controller(service: SimpleLayService):
    """리허설 비상 버튼을 받을 실행기. 걸림을 흉내 낼 수 없는 실행기(기본 mock)면 409."""
    controller = getattr(service, "_controller", None)
    if not callable(getattr(controller, "rehearse_outlet_estop", None)):
        raise HTTPException(
            409,
            "이 실행기는 비상정지 걸림을 흉내 내지 않아요 — SIMPLELAY_ACT_MODE=simulator로 리허설하세요",
        )
    return controller


@router.post("/demo/outlet-estop", response_model=DemoOutletEstopResponse)
async def demo_outlet_estop(
    body: DemoOutletEstopRequest,
    _mode: None = Depends(_require_rehearsal_mode),
    service: SimpleLayService = Depends(get_service),
) -> DemoOutletEstopResponse:
    """리허설 장치(시연 v3 갭 S3) — 콘센트 모듈 비상 버튼을 누른 것처럼 모의 RPi4 실행기에 ``estop``을 넣는다.

    실행기 쪽 처리(걸림·실행 중 정지·``estop_state`` 보고)는 실물 경로와 같은 코드다. 그래서 화면의
    비상 띠·배너, 실행 412, ``POST /stop/ack``까지 회로 없이 이어서 리허설할 수 있다. 모의·시뮬레이터
    모드 밖은 404, 걸림을 흉내 낼 수 없는 실행기(기본 mock)는 409다.
    """
    if uart_rehearsal_enabled():
        controller = _uart_rehearsal_controller(service)
        await asyncio.to_thread(controller.uart_rehearse_outlet_estop, body.hold_button)
        return DemoOutletEstopResponse(ok=True, button_held=body.hold_button,
                                       detail=_UART_REHEARSAL_ESTOP_DETAIL)
    controller = _rehearsal_estop_controller(service)
    await asyncio.to_thread(controller.rehearse_outlet_estop, body.hold_button)
    return DemoOutletEstopResponse(ok=True, button_held=body.hold_button,
                                   detail=_REHEARSAL_ESTOP_DETAIL)


@router.delete("/demo/outlet-estop", response_model=DemoOutletEstopResponse)
async def demo_outlet_estop_release(
    _mode: None = Depends(_require_rehearsal_mode),
    service: SimpleLayService = Depends(get_service),
) -> DemoOutletEstopResponse:
    """리허설 비상 버튼을 푼다. 걸림은 그대로다 — 풀려면 사람이 ``POST /stop/ack``."""
    if uart_rehearsal_enabled():
        controller = _uart_rehearsal_controller(service)
        await asyncio.to_thread(controller.uart_release_rehearsal_estop_button)
        return DemoOutletEstopResponse(ok=True, button_held=False, detail=_UART_REHEARSAL_ESTOP_DETAIL)
    controller = _rehearsal_estop_controller(service)
    await asyncio.to_thread(controller.release_rehearsal_estop_button)
    return DemoOutletEstopResponse(ok=True, button_held=False, detail=_REHEARSAL_ESTOP_DETAIL)


_REHEARSAL_DONE_DETAIL = "연습으로 넣은 끝 신호예요. 실제로 잰 값이 아니에요."
_UART_REHEARSAL_ESTOP_DETAIL = _REHEARSAL_ESTOP_DETAIL


def _require_done_rehearsal_mode() -> None:
    """모의·시뮬레이터 모드가 아니면 404 — 실물 보드의 판정 위에 주입을 얹지 않는다(서비스 의존성보다 먼저).
    UART 모드는 ``SIMPLELAY_UART_REHEARSAL=1``이고 RPi4가 가짜 콘센트·모의 모션일 때만(2026-10-06)."""
    if not demo_alert_allowed() and not uart_rehearsal_enabled():
        raise HTTPException(404, "가전 완료 주입은 모의·시뮬레이터 모드(또는 UART 리허설 스위치)에서만 열려 있어요")


@router.post("/demo/appliance-done", response_model=DemoApplianceDoneResponse)
async def demo_appliance_done(
    body: DemoApplianceDoneRequest,
    _mode: None = Depends(_require_done_rehearsal_mode),
    service: SimpleLayService = Depends(get_service),
) -> DemoApplianceDoneResponse:
    """리허설 장치(시연 v3 갭 S8) — 세탁기 끝(전력 하강·종료음)을 주입한다.

    융합 규칙은 RPi4 실물 경로와 같다(`rpi/verifier/done_fusion.py`): 두 입력이면 done_confirmed, 하나면
    done_power_only/done_beep_only(루틴 안내가 '끝난 것 같아요, 확인해 주세요'). 시뮬레이터면 모의 RPi4 실행기가
    ``appliance_done`` 프레임을 보내고 RPi5는 실물 프레임과 같은 길(ActClient → 루틴 엔진)로 받는다. 기본 mock이면
    RPi5 안에서 같은 규칙으로 만든 기록을 같은 수신 함수에 넣는다. 출처는 늘 ``injected``. 모의·시뮬레이터 밖은 404.
    """
    from rpi.verifier.done_fusion import rehearsal_done_event

    from .deps import receive_appliance_done

    controller = getattr(service, "_controller", None)
    rehearse = getattr(controller, "rehearse_appliance_done", None)
    if uart_rehearsal_enabled():
        # RPi4가 같은 융합 규칙으로 appliance_done(source=injected)을 보내고, RPi5는 실물 프레임과 같은 길로 받는다.
        controller = _uart_rehearsal_controller(service)
        try:
            frame = await asyncio.to_thread(controller.uart_rehearse_appliance_done, body.appliance_id,
                                            list(body.inputs), body.event)
        except RuntimeError as exc:
            raise HTTPException(409, str(exc)) from exc
        where = "rpi4_uart"
    elif callable(rehearse):
        frame = await asyncio.to_thread(rehearse, body.appliance_id, list(body.inputs), body.event)
        where = "rpi4_simulator"
    else:
        frame = rehearsal_done_event(body.appliance_id, list(body.inputs), now_s=time.monotonic(),
                                     event=body.event).to_frame(time.monotonic_ns())
        await asyncio.to_thread(receive_appliance_done, frame)
        where = "rpi5_mock"
    return DemoApplianceDoneResponse(
        ok=True, appliance_id=frame["appliance_id"], state=frame["state"], confidence=frame["confidence"],
        inputs=list(frame["inputs"]), source=frame["source"], injected_in=where,
        detail=_REHEARSAL_DONE_DETAIL)


# ThinQ 경로·시나리오(U1) — 같은 인증 의존성 아래에 둔다.
router.include_router(thinq_router)

# 사용자 루틴(2026-09-30) — 같은 인증 의존성 아래.
from .routines_router import router as routines_router  # noqa: E402

router.include_router(routines_router)
