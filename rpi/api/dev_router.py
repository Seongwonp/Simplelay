"""개발자 모드 API (Phase 2) — mock 전용, 기본 OFF, 명시적 접근 제한.

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

거절은 전부 어댑터에 닿기 **전에** 일어난다. 응답의 ``detail``은
``{"code", "message"}`` 모양으로 통일한다 -- 화면은 code로 분기하고 message를
그대로 보여줄 수 있다.

실물 어댑터·범용 셸 콘솔은 이 단계 범위 밖이다. 명령은 매니저의 허용 목록
파서만 통과한다.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import threading
import time
import uuid
from collections import deque
from collections.abc import Callable
from datetime import datetime
from functools import lru_cache

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

import rpi.api.deps as deps
from rpi.services.control_arbiter import ControlFaultedError
from rpi.services.developer_session import (
    MAX_JOG_MM,
    DevCommandKind,
    DevControlState,
    DeveloperSessionManager,
    DevResult,
    DevSessionConflict,
    DevSessionExpired,
    DevTargetUnknownError,
)
from rpi.services.rate_limit import SlidingWindowLimiter

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
# 세션별로 기억하는 최근 request_id 수 -- 재전송 이중 실행 방지용.
RECENT_REQUEST_IDS = 64


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
        # 세션은 한 번에 하나라 슬롯도 하나다. (session_id, sha256(secret))
        self._owner: tuple[str, bytes] | None = None
        self._request_ids: deque[str] = deque(maxlen=RECENT_REQUEST_IDS)

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

    def claim_request_id(self, request_id: str) -> bool:
        """처음 보는 request_id면 기록하고 True, 재전송이면 False."""
        with self._lock:
            if request_id in self._request_ids:
                return False
            self._request_ids.append(request_id)
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
    manager = deps.get_developer_session_manager()
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
    if not manager.is_mock:
        # Phase 2 계약: mock이 아닌 매니저가 물려 있으면 API를 열지 않는다.
        raise _error(503, "real_adapter_not_allowed", "이 단계의 개발자 API는 모의 제어 전용입니다")
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
    """confirmed=False를 성공처럼 보여주면 안 된다 -- 정지를 보냈지만
    확인하지 못했다는 뜻이고, 그때 phase는 대개 fault다."""

    confirmed: bool
    message: str
    state: DevStateResponse


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
    return DevStateResponse(
        phase=snap.phase,
        mock=snap.mock,
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
        max_jog_mm=MAX_JOG_MM,
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
    try:
        session = manager.start(body.appliance_id, body.node_id)
    except DevTargetUnknownError as exc:
        raise _error(404, "unknown_appliance", str(exc)) from exc
    except ControlFaultedError as exc:
        raise _error(423, "fault", str(exc)) from exc
    except DevSessionConflict as exc:
        status = 503 if exc.code == "shutting_down" else 409
        raise _error(status, exc.code, str(exc)) from exc
    secret = _api_state().bind(session.session_id)
    return DevSessionStartResponse(
        session_id=session.session_id,
        session_secret=secret,
        state=_state_view(manager),
    )


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
        if body.request_id is not None and not state.claim_request_id(body.request_id):
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
        manager.end(session_id)
    except DevSessionExpired as exc:
        raise _error(410, "session_expired", str(exc)) from exc
    except Exception:
        return DevStopResponse(
            confirmed=False,
            message="세션은 닫았지만 정지를 확인하지 못했습니다 -- 기기가 잠겼습니다",
            state=_state_view(manager),
        )
    return DevStopResponse(confirmed=True, message="세션을 끝내고 정지를 확인했습니다", state=_state_view(manager))


@dev_router.post("/stop", response_model=DevStopResponse)
def dev_stop(
    manager: DeveloperSessionManager = Depends(require_dev_access),
) -> DevStopResponse:
    """개발자 긴급 정지 -- 세션 소유권·빈도 제한 없이 토큰만 본다.
    토큰조차 없는 경우를 위해 일반 ``POST /stop``도 같은 정지를 보낸다."""
    try:
        manager.emergency_stop("emergency_stop")
    except Exception:
        return DevStopResponse(
            confirmed=False,
            message="정지를 보냈지만 확인하지 못했습니다 -- 다시 정지를 눌러 확인해 주세요",
            state=_state_view(manager),
        )
    return DevStopResponse(confirmed=True, message="정지를 확인했습니다", state=_state_view(manager))


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
