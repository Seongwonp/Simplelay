"""개발자 모드 API (Phase 2, 2026-10-10 실물 경로) — 기본 OFF, 기본 모의, 명시적 접근 제한.

화면에서 숨기는 것은 접근 제한이 아니다. 이 라우터는 다음을 서버에서 강제한다:

1. **꺼져 있으면 없다.** ``SIMPLELAY_DEV_MODE``가 아니면 모든 경로가 404.
2. **토큰 없이는 닫힌다(fail closed).** 켜져 있어도 ``SIMPLELAY_DEV_TOKEN``이
   ``MIN_DEV_TOKEN_LEN``자 미만이면 503. 일반 조작 키(``SIMPLELAY_API_KEY``)와
   **별개의 권한**이고, 루프백도 면제하지 않는다 -- 키오스크 보드에 닿았다고
   기계를 직접 움직일 권한까지 생기지는 않는다.
3. **토큰 대입은 막힌다.** 클라이언트별 실패가 한도에 닿으면 창이 지날 때까지
   맞는 토큰도 429.
4. **세션은 연 클라이언트의 것이다.** 시작 응답에서만 ``session_secret``을 한 번
   돌려주고 서버에는 해시만 둔다. heartbeat·명령·종료는 그 비밀값이 있어야 한다.
5. **빈도·길이 제한.** 명령 길이 상한, 세션별 명령/heartbeat 빈도, 세션 시작 빈도.
   같은 ``request_id``의 재전송은 기계에 두 번 닿지 않는다(재시도 이중 누름 방지).
6. **정지는 어떤 제한에도 걸리지 않는다.** 빈도·중복 검사 예외이고, 개발자
   토큰이 없는 일반 ``POST /stop``도 개발자 세션을 멈춘다(router.py).

7. **기본은 모의, 실물은 env 두 개 + RPi4 실물 링크일 때만(2026-10-10).** 매니저 어댑터가 모의가
   아니면 ``SIMPLELAY_DEV_MODE``와 ``SIMPLELAY_DEV_REAL_MOTION``이 둘 다 켜져 있을 때만 API를 연다
   (아니면 503 ``real_adapter_not_allowed``). 실물 어댑터(rpi/services/dev_real_motion.py)는 RPi4가
   ``act_info``로 실제 모션 링크(``motion:"serial"``)와 개발자 조작 규약(``dev_motion_protocol`` ≥ 1)을
   알릴 때만 RPi4로 보낸다(docs/protocol.md ``dev_motion``). 그 밖의 실물 거절:
   ``motion_mock``·``dev_protocol_unsupported``·``act_link_unavailable``·``link_down``·``estop_latched``·
   ``estop_unknown``(RPi5에서, 보내기 전) · ``not_homed``·``execution_busy``·``dev_busy``·``soft_limit``·
   ``z_jog_unsupported``·``press_too_long``·``bringup_firmware``·``motion_not_ready`` 등(RPi4·MCU, 움직이기
   전 — ``moved:false``) · ``step_too_large``(한 번 조그 상한, ``max_jog_mm`` — 실물 기본 1 mm). 움직이기 전
   거절은 정지를 보내지 않고 세션을 유지한다. 움직였을 수 있는 실패는 종전처럼 정지를 보내고
   ``command_error``(원인을 message에 덧붙임)다. 조그는 요청 하나에 답 하나 — 재전송·자동 재개는 없다.
   정지(/dev/stop·세션 종료·heartbeat 끊김·일반 /stop)는 RPi4 ``dev_motion stop``으로 가고(옛 RPi4면
   ``abort drive``), 확인하지 못하면 종전처럼 fault로 잠근다. 상태 응답의 ``motion_target``
   (``mock``|``real``)·``real_motion_ready``·``real_motion_reason``으로 화면이 '실제 장치'/'모의'를 가른다.

거절은 전부 어댑터에 닿기 **전에** 일어난다(실물은 위 7 — RPi4·MCU의 움직이기 전 거절 포함). 응답의
``detail``은 ``{"code", "message"}`` 모양으로 통일한다 -- 화면은 code로 분기하고 message를
그대로 보여줄 수 있다.

범용 셸 콘솔은 범위 밖이다. 명령은 매니저의 허용 목록 파서만 통과한다.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import threading
import time
import uuid
from collections.abc import Callable
from datetime import datetime
from functools import lru_cache

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

import rpi.api.deps as deps
from rpi.services.control_arbiter import ControlFaultedError
from rpi.services.developer_session import (
    DevCommandKind,
    DevControlState,
    DeveloperSessionManager,
    DevResult,
    DevSessionConflict,
    DevSessionExpired,
    DevTargetUnknownError,
)
from rpi.services.rate_limit import SlidingWindowLimiter
from rpi.services.stop_confirm import stop_level_confirmed, stop_sentence

DEV_TOKEN_ENV = "SIMPLELAY_DEV_TOKEN"
MIN_DEV_TOKEN_LEN = 16
MAX_COMMAND_LEN = 64
_ID_PATTERN = r"^[A-Za-z0-9_-]{1,64}$"
_REQUEST_ID_PATTERN = r"^[A-Za-z0-9_-]{1,32}$"

# 빈도 한도. jog를 누르고 있는 동안 화면이 0.1~0.2초마다 다시 보내므로
# 명령은 초당 20회면 여유가 있고, 폭주한 클라이언트는 여기서 멈춘다.
COMMAND_LIMIT_PER_S = 20
HEARTBEAT_LIMIT_PER_S = 10
START_LIMIT, START_WINDOW_S = 5, 10.0
AUTH_FAILURE_LIMIT, AUTH_FAILURE_WINDOW_S = 10, 60.0
# 세션 수명 동안 기억한다. 상한에서는 거절하며 기존 ID를 버리지 않는다.
MAX_SESSION_REQUEST_IDS = 4096


def _error(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code=status, detail={"code": code, "message": message})


# ── API 층 상태(소유권·빈도) ────────────────────────────────────────────────


class DevApiState:
    """소유권 슬롯과 빈도 제한기. 매니저와 분리한 이유: 세션 비밀값·요청
    중복 기록은 전송 계층의 관심사고, 매니저의 안전 계약(제어권·정지)과
    섞으면 그 계약의 테스트가 HTTP 개념을 알아야 한다."""

    def __init__(self, monotonic: Callable[[], float] = time.monotonic) -> None:
        self.commands = SlidingWindowLimiter(
            COMMAND_LIMIT_PER_S, 1.0, monotonic=monotonic
        )
        self.heartbeats = SlidingWindowLimiter(
            HEARTBEAT_LIMIT_PER_S, 1.0, monotonic=monotonic
        )
        self.starts = SlidingWindowLimiter(
            START_LIMIT, START_WINDOW_S, monotonic=monotonic
        )
        self.auth_failures = SlidingWindowLimiter(
            AUTH_FAILURE_LIMIT, AUTH_FAILURE_WINDOW_S, monotonic=monotonic
        )
        self._lock = threading.Lock()
        # 시작→소유권 게시만 직렬화한다. 정지 경로는 이 락을 잡지 않는다.
        self.start_lock = threading.Lock()
        # 세션은 한 번에 하나라 슬롯도 하나다. (session_id, sha256(secret))
        self._owner: tuple[str, bytes] | None = None
        self._request_ids: set[str] = set()

    def bind(self, session_id: str) -> str:
        secret = secrets.token_urlsafe(24)
        with self._lock:
            self._owner = (session_id, hashlib.sha256(secret.encode()).digest())
            self._request_ids.clear()
        return secret

    def verify(self, session_id: str, secret: str) -> bool:
        with self._lock:
            owner = self._owner
        if owner is None or owner[0] != session_id:
            return False
        return hmac.compare_digest(
            owner[1], hashlib.sha256(secret.encode()).digest()
        )

    def claim_request_id(self, session_id: str, request_id: str) -> bool:
        """처음 보는 request_id면 기록하고 True, 재전송이면 False."""
        with self._lock:
            if self._owner is None or self._owner[0] != session_id:
                raise _error(410, "session_expired", "세션이 끝났습니다")
            if request_id in self._request_ids:
                return False
            if len(self._request_ids) >= MAX_SESSION_REQUEST_IDS:
                raise _error(429, "request_capacity_reached", "요청 기록 한도입니다 -- 세션을 끝내고 새로 시작해 주세요")
            self._request_ids.add(request_id)
            return True


@lru_cache(maxsize=1)
def get_dev_api_state() -> DevApiState:
    return DevApiState()


def _api_state() -> DevApiState:
    # 호출 시점에 모듈 전역을 찾는다 -- 테스트가 시계를 쥔 상태로 갈아끼운다.
    return get_dev_api_state()


# ── 접근 제한 의존성 ────────────────────────────────────────────────────────


def require_dev_access(
    request: Request,
    x_dev_token: str | None = Header(default=None),
) -> DeveloperSessionManager:
    if not deps.developer_mode_enabled():
        raise _error(404, "dev_mode_disabled", "개발자 모드가 서버에서 꺼져 있습니다")
    return _check_dev_access(request, x_dev_token, deps.get_developer_session_manager())


async def require_dev_stop_access(
    request: Request,
    x_dev_token: str | None = Header(default=None),
) -> DeveloperSessionManager:
    """``/dev/stop``의 접근 검사 — ``require_dev_access``와 같은 검사를 공유 스레드 풀 없이 한다(HIGH 재확인 2차 H-RR1).
    검사 자체는 메모리 일(환경 변수·빈도 제한기)이고, 매니저가 아직 없을 때만 정지 전용 실행기에서 만든다."""
    from .stop_lane import resolve_without_shared_pool  # noqa: PLC0415

    overrides = getattr(request.app, "dependency_overrides", None) or {}
    if require_dev_access in overrides:
        return await resolve_without_shared_pool(request, require_dev_access)
    if not deps.developer_mode_enabled():
        raise _error(404, "dev_mode_disabled", "개발자 모드가 서버에서 꺼져 있습니다")
    manager = await resolve_without_shared_pool(request, deps.get_developer_session_manager)
    return _check_dev_access(request, x_dev_token, manager)


def _check_dev_access(request: Request, x_dev_token: str | None,
                      manager: DeveloperSessionManager | None) -> DeveloperSessionManager:
    if manager is None:
        raise _error(404, "dev_mode_disabled", "개발자 모드가 서버에서 꺼져 있습니다")
    expected = os.environ.get(DEV_TOKEN_ENV, "").strip()
    if len(expected) < MIN_DEV_TOKEN_LEN:
        # 토큰 없는 개발자 모드는 열린 문이다 -- 켜 놓고 잊어도 닫혀 있게.
        raise _error(
            503,
            "dev_token_not_configured",
            f"서버에 {DEV_TOKEN_ENV}가 {MIN_DEV_TOKEN_LEN}자 이상으로 설정되지 않았습니다",
        )
    state = _api_state()
    client = request.client.host if request.client else "unknown"
    # 비교보다 잠금 확인이 먼저다 -- 잠긴 동안 맞는 토큰도 통과시키면
    # 대입 시도의 성공 여부를 응답 차이로 알려주게 된다.
    if state.auth_failures.exceeded(client):
        raise _error(429, "auth_rate_limited", "인증 실패가 너무 많습니다 -- 잠시 후 다시 시도해 주세요")
    if not x_dev_token:
        state.auth_failures.record(client)
        raise _error(401, "dev_token_required", "개발자 토큰이 필요합니다")
    if not hmac.compare_digest(x_dev_token.encode(), expected.encode()):
        state.auth_failures.record(client)
        raise _error(403, "dev_token_invalid", "개발자 토큰이 올바르지 않습니다")
    if not manager.is_mock and not deps.dev_real_motion_enabled():
        # 모의가 아닌 매니저는 env 두 개(SIMPLELAY_DEV_MODE + SIMPLELAY_DEV_REAL_MOTION)가 켜졌을 때만 연다.
        raise _error(503, "real_adapter_not_allowed", "실제 장치 조작이 서버에서 켜져 있지 않아요")
    return manager


def _require_owner(
    manager: DeveloperSessionManager,
    session_id: str,
    secret: str | None,
) -> None:
    """세션이 살아 있고, 요청자가 그 세션을 연 클라이언트인가.

    만료 판정이 먼저다 -- 이미 끝난 세션의 옛 비밀값에 403을 주면 화면은
    '권한 문제'로 오해하고, 실제로 필요한 행동(새 세션 시작)을 안내하지 못한다.
    """
    current = manager.state().session
    if current is None or current.session_id != session_id:
        raise _error(410, "session_expired", "세션이 끝났거나 heartbeat가 끊겨 정지됐습니다")
    if not secret:
        raise _error(401, "session_secret_required", "세션 비밀값이 필요합니다")
    if not _api_state().verify(session_id, secret):
        raise _error(403, "not_session_owner", "이 세션을 연 기기에서만 사용할 수 있습니다")


# ── 요청·응답 모델 ──────────────────────────────────────────────────────────


class DevSessionStartRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    appliance_id: str = Field(pattern=_ID_PATTERN)
    node_id: str = Field(pattern=_ID_PATTERN)


class DevCommandRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    appliance_id: str = Field(pattern=_ID_PATTERN)
    text: str = Field(min_length=1, max_length=MAX_COMMAND_LEN)
    request_id: str | None = Field(default=None, pattern=_REQUEST_ID_PATTERN)


class DevSessionView(BaseModel):
    """세션의 공개 정보. **비밀값은 절대 싣지 않는다.**"""

    session_id: str
    appliance_id: str
    node_id: str
    started_at: datetime
    expires_at: datetime


class DevStateResponse(BaseModel):
    phase: str
    mock: bool
    #: 명령이 가는 곳 ``mock``|``real``(2026-10-10). 화면의 '모의'/'실제 장치' 표시 근거.
    motion_target: str = "mock"
    #: 실물일 때 지금 RPi4로 보낼 수 있나(링크·RPi4 실물 모션·규약·비상정지). 모의면 None.
    real_motion_ready: bool | None = None
    #: 보낼 수 없는 이유(해요체 한 문장). 준비됐거나 모의면 None.
    real_motion_reason: str | None = None
    shutting_down: bool
    session: DevSessionView | None
    fault_reason: str | None
    heartbeat_ttl_s: float
    max_jog_mm: float
    max_command_len: int
    allowed_commands: list[str]


class DevSessionStartResponse(BaseModel):
    session_id: str
    session_secret: str
    state: DevStateResponse


class DevCommandResponse(BaseModel):
    accepted: bool
    request_id: str
    normalized: str | None
    sensor: dict[str, float] | None
    state: DevStateResponse


class DevStopResponse(BaseModel):
    """confirmed는 이번 stop 호출의 확인이다. 최종 정리는 state.phase로
    구분한다: stopping이면 이전 명령 정리가 남았고 fault이면 사용 불가다.
    confirmed=False만으로 fault를 추론하면 안 된다(유휴 정지 실패).

    2026-10-13: 실물이면 ``confirmed``는 정지 확인 단계가 ``mcu_ack``(모션 보드가 받음) 이상일 때만 참이다.
    ``sent``는 '정지 명령을 보냄'까지다 — 잠그지 않지만 확인도 아니다. 모의는 단계 없이 종전처럼 참."""

    confirmed: bool
    message: str
    state: DevStateResponse
    #: sent | mcu_ack | verified | None(모의·RPi4에 닿지 못함)
    stop_level: str | None = None
    #: 정지를 보낸 뒤 모션 보드 응답까지(ms). mcu_ack 이상일 때만.
    stop_ack_ms: int | None = None


class DevLogEntryView(BaseModel):
    at: datetime
    event: str
    request_id: str | None
    session_id: str | None
    appliance_id: str | None
    detail: str
    mock: bool


_ALLOWED_COMMANDS = [
    DevCommandKind.STATUS.value,
    DevCommandKind.HOME.value,
    DevCommandKind.SENSOR_READ.value,
    "jog <x|y|z> <+|-> <mm>",
    "press <button_id>",
    DevCommandKind.STOP.value,
]


def _state_view(manager: DeveloperSessionManager, snap: DevControlState | None = None) -> DevStateResponse:
    snap = snap or manager.state()
    session = snap.session
    real_status = None if snap.mock else manager.adapter_status()
    return DevStateResponse(
        phase=snap.phase,
        mock=snap.mock,
        motion_target="mock" if snap.mock else "real",
        real_motion_ready=None if real_status is None else real_status[0],
        real_motion_reason=None if real_status is None else real_status[1],
        shutting_down=snap.shutting_down,
        session=(
            DevSessionView(
                session_id=session.session_id,
                appliance_id=session.appliance_id,
                node_id=session.node_id,
                started_at=session.started_at,
                expires_at=session.expires_at,
            )
            if session is not None
            else None
        ),
        fault_reason=snap.fault_reason,
        heartbeat_ttl_s=manager.heartbeat_ttl_s,
        max_jog_mm=manager.max_jog_mm,
        max_command_len=MAX_COMMAND_LEN,
        allowed_commands=list(_ALLOWED_COMMANDS),
    )


# 매니저 거절 코드 → HTTP. 코드는 그대로 detail.code로 내보낸다.
_RESULT_STATUS: dict[str, int] = {
    "invalid_command": 422,
    "wrong_target": 422,
    "unknown_button": 422,
    "not_calibrated": 422,
    "session_expired": 410,
    "stopped": 409,
    "stop_race": 409,
    "stop_unconfirmed": 423,
    "command_error": 502,
    # 실물 경로(2026-10-10) — 움직이기 전 거절
    "step_too_large": 422,
    "z_jog_unsupported": 422,
    "soft_limit": 422,
    "press_too_long": 422,
    "bad_args": 422,
    "act_link_unavailable": 503,
    "link_down": 503,
    "motion_not_ready": 503,
    "outlet_offline": 503,
    "act_info_unknown": 409,
    "motion_mock": 409,
    "dev_protocol_unsupported": 409,
    "dev_unsupported": 409,
    "estop_latched": 423,
    "estop_unknown": 409,
    "not_homed": 409,
    "execution_busy": 409,
    "dev_busy": 409,
    "busy": 409,
    "bringup_firmware": 409,
    "press_mode_unsupported": 409,
    "z_cooldown": 409,
}


def _raise_for_result(result: DevResult) -> None:
    code = result.code or "command_rejected"
    status = _RESULT_STATUS.get(code, 422)
    raise HTTPException(
        status_code=status,
        detail={
            "code": code,
            "message": result.reason or "명령이 거절됐습니다",
            "request_id": result.request_id,
        },
    )


# ── 라우터 ──────────────────────────────────────────────────────────────────

# 모든 엔드포인트가 동기 함수다 -- FastAPI가 스레드풀에서 돌려, 매니저의
# 락·어댑터 호출이 이벤트 루프(SSE·다른 API)를 막지 않는다.
dev_router = APIRouter(prefix="/dev", tags=["developer"])


@dev_router.get("/diagnostics/board-probe")
def board_probe_history(_manager=Depends(require_dev_access)):
    from rpi.services.probe_history import load_last_probe
    try:
        result = load_last_probe()
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        raise _error(503, "probe_history_unavailable", "이전 점검 기록을 읽을 수 없습니다") from None
    if result is None:
        raise _error(404, "probe_history_disabled", "이전 점검 기록이 없거나 표시가 꺼져 있습니다")
    return result


@dev_router.get("/state", response_model=DevStateResponse)
def dev_state(
    manager: DeveloperSessionManager = Depends(require_dev_access),
) -> DevStateResponse:
    return _state_view(manager)


@dev_router.post("/sessions", response_model=DevSessionStartResponse, status_code=201)
def dev_start_session(
    body: DevSessionStartRequest,
    manager: DeveloperSessionManager = Depends(require_dev_access),
) -> DevSessionStartResponse:
    if not _api_state().starts.allow("start"):
        raise _error(429, "rate_limited", "세션 시작이 너무 잦습니다 -- 잠시 후 다시 시도해 주세요")
    api_state = _api_state()
    if not api_state.start_lock.acquire(blocking=False):
        raise _error(409, "session_starting", "다른 세션 시작을 처리 중입니다")
    try:
        session = manager.start(body.appliance_id, body.node_id)
        secret = api_state.bind(session.session_id)
        snap = manager.state()
        if snap.session is None or snap.session.session_id != session.session_id:
            raise _error(410, "session_expired", "시작 중 세션이 끝났습니다")
        return DevSessionStartResponse(
            session_id=session.session_id,
            session_secret=secret,
            state=_state_view(manager, snap),
        )
    except DevTargetUnknownError as exc:
        raise _error(404, "unknown_appliance", str(exc)) from exc
    except ControlFaultedError as exc:
        raise _error(423, "fault", str(exc)) from exc
    except DevSessionConflict as exc:
        status = 503 if exc.code == "shutting_down" else 409
        raise _error(status, exc.code, str(exc)) from exc
    finally:
        api_state.start_lock.release()


@dev_router.post("/sessions/{session_id}/heartbeat", response_model=DevStateResponse)
def dev_heartbeat(
    session_id: str,
    manager: DeveloperSessionManager = Depends(require_dev_access),
    x_dev_session_secret: str | None = Header(default=None),
) -> DevStateResponse:
    _require_owner(manager, session_id, x_dev_session_secret)
    if not _api_state().heartbeats.allow(session_id):
        raise _error(429, "rate_limited", "heartbeat가 너무 잦습니다")
    try:
        manager.heartbeat(session_id)
    except DevSessionExpired as exc:
        raise _error(410, "session_expired", str(exc)) from exc
    return _state_view(manager)


@dev_router.post("/sessions/{session_id}/commands", response_model=DevCommandResponse)
def dev_command(
    session_id: str,
    body: DevCommandRequest,
    manager: DeveloperSessionManager = Depends(require_dev_access),
    x_dev_session_secret: str | None = Header(default=None),
) -> DevCommandResponse:
    _require_owner(manager, session_id, x_dev_session_secret)
    is_stop = body.text.strip().lower() == "stop"
    request_id = body.request_id or uuid.uuid4().hex[:12]
    if not is_stop:
        # 정지는 빈도·중복 검사에서 뺀다 -- 멈추라는 말은 언제나 통한다.
        state = _api_state()
        if not state.commands.allow(session_id):
            raise _error(429, "rate_limited", "명령이 너무 잦습니다")
        if not state.claim_request_id(session_id, request_id):
            raise _error(409, "duplicate_request", "이미 처리한 요청입니다(재전송은 다시 실행하지 않습니다)")
    result = manager.submit(session_id, body.appliance_id, body.text, request_id=request_id)
    if not result.accepted:
        _raise_for_result(result)
    return DevCommandResponse(
        accepted=True,
        request_id=result.request_id,
        normalized=result.normalized,
        sensor=result.sensor,
        state=_state_view(manager),
    )


@dev_router.post("/sessions/{session_id}/end", response_model=DevStopResponse)
def dev_end_session(
    session_id: str,
    manager: DeveloperSessionManager = Depends(require_dev_access),
    x_dev_session_secret: str | None = Header(default=None),
) -> DevStopResponse:
    _require_owner(manager, session_id, x_dev_session_secret)
    try:
        info = manager.end(session_id)
    except DevSessionExpired as exc:
        raise _error(410, "session_expired", str(exc)) from exc
    except Exception:
        return DevStopResponse(
            confirmed=False,
            message="세션은 닫았지만 정지를 확인하지 못했습니다 -- 기기가 잠겼습니다",
            state=_state_view(manager),
        )
    return _stop_response(manager, info, mock_message="세션을 끝내고 모의 장치에서 정지를 확인했습니다", prefix="세션을 끝냈어요 — ")


def _stop_response(manager: DeveloperSessionManager, info: dict | None, *, mock_message: str,
                   prefix: str = "") -> DevStopResponse:
    """RPi4에 닿은 정지의 응답. 실물은 확인 단계로 ``confirmed``와 문장을 정한다(2026-10-13)."""
    if manager.is_mock:
        return DevStopResponse(confirmed=True, message=mock_message, state=_state_view(manager))
    level = info.get("stop_level") if isinstance(info, dict) else None
    ack_ms = info.get("ack_ms") if isinstance(info, dict) else None
    level = level if isinstance(level, str) else "sent"  # 실물인데 단계를 모르면 '보냄'까지만
    sentence = stop_sentence(level, ack_ms) or "정지 명령을 보냈어요"
    return DevStopResponse(confirmed=stop_level_confirmed(level), message=prefix + sentence,
                           state=_state_view(manager), stop_level=level, stop_ack_ms=ack_ms)


@dev_router.post("/stop", response_model=DevStopResponse)
async def dev_stop(
    manager: DeveloperSessionManager = Depends(require_dev_stop_access),
) -> DevStopResponse:
    """개발자 긴급 정지 -- 세션 소유권·빈도 제한 없이 토큰만 본다.
    토큰조차 없는 경우를 위해 일반 ``POST /stop``도 같은 정지를 보낸다.

    HIGH 재확인 2차 H-RR1: 접근 검사는 async, 정지는 정지 전용 실행기(``stop_lane``) — 일반 요청이 공유 스레드 풀을
    채운 동안에도 줄을 서지 않는다."""
    from .stop_lane import run_on_stop_lane  # noqa: PLC0415

    return await run_on_stop_lane(_dev_stop, manager)


def _dev_stop(manager: DeveloperSessionManager) -> DevStopResponse:
    try:
        info = manager.emergency_stop("emergency_stop")
    except Exception:
        return DevStopResponse(
            confirmed=False,
            message="정지를 보냈지만 확인하지 못했습니다 -- 다시 정지를 눌러 확인해 주세요",
            state=_state_view(manager),
        )
    return _stop_response(manager, info, mock_message="모의 장치에서 정지를 확인했습니다")


@dev_router.get("/log", response_model=list[DevLogEntryView])
def dev_log(
    limit: int = 50,
    manager: DeveloperSessionManager = Depends(require_dev_access),
) -> list[DevLogEntryView]:
    limit = max(1, min(limit, DeveloperSessionManager.LOG_LIMIT))
    entries = manager.log()[-limit:]
    return [
        DevLogEntryView(
            at=e.at,
            event=e.event,
            request_id=e.request_id,
            session_id=e.session_id,
            appliance_id=e.appliance_id,
            detail=e.detail,
            mock=e.mock,
        )
        for e in reversed(entries)
    ]
