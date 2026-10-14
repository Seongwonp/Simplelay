import asyncio
import contextlib
import logging
import os
import pathlib

import uvicorn
from fastapi import Depends, FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from rpi.api.auth import log_auth_mode, require_api_key
from rpi.api.deps import (
    get_actuator_status,
    get_service,
    get_suggestion_service,
    get_wellness_checker,
    quiet_status,
)
from rpi.api.pairing import pairing_router
from rpi.api.dev_router import dev_router
from rpi.api.router import router
from rpi.api.service import ApplianceNotReadyError, UnknownApplianceError
from rpi.api.schemas import HealthResponse
from rpi.intent.suggestions import ProactiveSuggestionService

log = logging.getLogger(__name__)

# 패턴 감지는 사용 이력의 시간대 집계라 비싸지 않다 — 1분 주기면
# "저녁 시간대에 들어서면 곧 제안이 뜬다" 체감에 충분하다.
SUGGESTION_REFRESH_SECONDS = 60.0


async def _suggestion_refresh_loop() -> None:
    """선제 제안 생성 루프. create_suggestions()는 그동안 프로덕션 어디에서도
    호출되지 않아 GET /suggestions가 항상 빈 배열이었다(핵심 기능이 죽은
    코드였던 원인) — 이 루프가 주기적으로 패턴을 감지해 제안을 만든다."""
    while True:
        try:
            # 동기 집계(SQLite 포함 가능)를 이벤트 루프에서 떼어낸다 —
            # 이력이 쌓이면 이 검사 동안 API·SSE 응답이 늦어진다(교차 리뷰 #11)
            await asyncio.to_thread(get_suggestion_service().create_suggestions)
        except Exception:  # 제안 생성 실패가 서버를 죽여선 안 된다
            log.exception("suggestion refresh failed")
        try:
            # 안부 신호 — 같은 주기로 "평소 시간대의 사용이 오늘 없었나" 확인
            await asyncio.to_thread(get_wellness_checker().check)
        except Exception:
            log.exception("wellness check failed")
        await asyncio.sleep(SUGGESTION_REFRESH_SECONDS)


def _seed_vectordb_if_enabled() -> None:
    """유사도 계층에 예시를 채운다 -- ``SIMPLELAY_VECTORDB_SEED=1`` 일 때만.

    자동으로 켜지 않는 이유: 진짜 D-Bus 호출이라 서비스가 없는 곳에서 돌면 무의미하고,
    저장소가 재부팅 후에도 유지되는지 아직 확인이 안 돼서 매 기동 시드가 중복을 쌓을지
    모른다. 실기기에서 확인한 뒤 기본값을 정한다.

    실패해도 서버는 계속 뜬다 -- 시드가 안 되면 유사도 계층이 계속 미스라 규칙·LLM이
    받아주고, 그건 시드 이전과 똑같은 상태다. 시드 실패로 서버가 못 뜨는 쪽이 더 나쁘다.
    """
    if os.environ.get("SIMPLELAY_VECTORDB_SEED", "").strip().lower() not in {"1", "true"}:
        return
    try:
        from rpi.intent.dbus_vectordb import VectordbClient
        from rpi.intent.vectordb_seed import seed_vectordb

        seed_vectordb(VectordbClient())
    except Exception:
        log.exception("벡터DB 시드 실패 — 유사도 계층 없이 계속 진행한다")


async def _shutdown_cleanup() -> None:
    """종료 절차: 신규 job 차단 → 협조 정지 → 잠시 대기 → 자원 정리.

    이전에는 제안 task만 취소해서, systemd 재시작 시 백그라운드 실행
    스레드(daemon)가 물리 컨트롤러에 아무 정지 명령 없이 증발했다.
    """
    from rpi.api.deps import (  # noqa: PLC0415
        developer_mode_enabled,
        get_db,
        get_developer_session_manager,
        get_service,
    )

    # 개발자 세션부터 정리한다 — 감시 스레드를 멈추고, 열린 세션이 있으면
    # 정지를 보낸다. systemd 재시작 때 세션이 정지 없이 증발하면 안 된다.
    try:
        if developer_mode_enabled():
            manager = get_developer_session_manager()
            if manager is not None:
                await asyncio.to_thread(manager.close)
    except Exception:
        log.exception("developer session cleanup failed")

    try:
        service = get_service()
        service.request_shutdown()  # 신규 job 거부
        if service.emergency_stop():  # 실행 중이면 협조 정지 요청
            deadline = asyncio.get_running_loop().time() + 5.0
            while (
                service.status().running
                and asyncio.get_running_loop().time() < deadline
            ):
                await asyncio.sleep(0.1)
        # UART 컨트롤러 등 정리 (있을 때만)
        close = getattr(service._controller, "close", None)
        if close is not None:
            close()
    except Exception:
        log.exception("shutdown cleanup failed")
    # 자동 실행 규칙: 남은 DB 쓰기(정지의 규칙 끄기 등)를 마친 뒤에만 세션 표시를 닫는다(4차 평가 M-N3).
    # 못 마치면 표시가 열린 채 남아 다음 기동이 켜진 규칙을 끈 채 시작한다. DB를 닫기 전에.
    try:
        from rpi.routines.wiring import close_auto_rules_if_any  # noqa: PLC0415

        if not await asyncio.to_thread(close_auto_rules_if_any):
            log.warning("auto rules not closed cleanly — next start holds enabled rules off")
    except Exception:
        log.exception("auto rule close failed")
    try:
        db = get_db()
        if db is not None:
            db.close()
    except Exception:
        log.exception("db close failed")


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    # 인증 방식을 기동 로그에 남긴다 — 키 없이 LAN을 연 상태면 경고
    log_auth_mode()
    # ThinQ SDK 모드(real·fake_cloud)는 SDK·PAT·주소가 안 맞으면 여기서 기동을 거절한다 --
    # 첫 요청 때가 아니라 띄울 때 알아야 한다(모르는 모드 값도 여기서 걸린다).
    from rpi.api.thinq_wiring import get_thinq_client
    get_thinq_client()
    # RPi5-RPi4 프레임 세션 기록 켜짐/꺼짐과 경로를 기동 로그에 남긴다(SIMPLELAY_SESSION_LOG_PATH)
    from rpi.services.link_tap import get_link_tap
    get_link_tap()
    # 사건 신선도 시계를 기동 때 만든다 — 그 순간이 '재시작 전에 끝난 가열'을 가르는 경계다(4차 평가 M-N2).
    from rpi.services.event_clock import get_event_clock
    get_event_clock()
    # 블로킹 서브프로세스 호출이라 이벤트 루프를 막지 않게 스레드로 넘긴다
    await asyncio.to_thread(_seed_vectordb_if_enabled)
    refresh_task = asyncio.create_task(_suggestion_refresh_loop())
    # 사용자 루틴의 시각·다가옴 트리거(카드·알림만 만든다, 실행 없음).
    from rpi.routines.wiring import routine_tick_loop
    routine_task = asyncio.create_task(routine_tick_loop())
    try:
        yield
    finally:
        refresh_task.cancel()
        routine_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await refresh_task
        with contextlib.suppress(asyncio.CancelledError):
            await routine_task
        await _shutdown_cleanup()


app = FastAPI(title="SimpleLay RPi API", version="0.1.0", lifespan=lifespan)

app.include_router(pairing_router)


@app.exception_handler(ApplianceNotReadyError)
async def _appliance_not_ready(
    _request: Request, exc: ApplianceNotReadyError
):
    """대상 가전이 아직 조작할 준비가 안 됐다 (F1).

    412를 쓴다. 404는 '없는 가전'이고(이건 있다), 409는 이 API에서
    '다른 작업이 실행 중'이라 클라이언트가 "잠시 후 다시"로 안내한다 --
    여기서 필요한 것은 기다림이 아니라 **설치를 마치는 일**이다.
    """
    # detail은 **사용자에게 그대로 보일 수 있는 문장**이다. 화면이
    # 기술 문구를 잘라 쓰게 하면 서버 문구가 바뀔 때마다 조용히 깨진다.
    return JSONResponse(
        status_code=412, content={"detail": exc.user_message}
    )


@app.exception_handler(UnknownApplianceError)
async def _unknown_appliance(_request: Request, exc: UnknownApplianceError):
    """실행 대상 가전이 없을 때의 응답을 한 곳에서 정한다 (R1).

    라우터마다 검사를 붙이면 진입점이 늘 때마다 구멍이 생기므로, 검증은
    서비스(_controller_for)에 두고 매핑만 여기서 한다. 404여야 하는
    이유: 409('다른 작업 실행 중')로 뭉뚱그리면 클라이언트가 '잠시 후
    다시 시도하세요'로 안내하는데, 기다려도 영원히 안 되는 상황이다.
    """
    return JSONResponse(status_code=404, content={"detail": str(exc)})
# LAN 요청은 SIMPLELAY_API_KEY(X-API-Key)가 필요하다. 키 미설정이면 루프백만
# 허용하고, 명시적 SIMPLELAY_ALLOW_UNAUTHENTICATED=1일 때만 개방 (auth.py 참고).
# /health(아래)와 /ui는 의도적으로 키 없이 개방.
app.include_router(router, dependencies=[Depends(require_api_key)])
from rpi.api.simulator_router import router as simulator_router
app.include_router(simulator_router, dependencies=[Depends(require_api_key)])
# 실모드 디지털 트윈(/twin) -- 화면·스크립트는 /ui처럼 키 없이, 상태·재생 목록은 키 필요.
from rpi.api.twin_router import page_router as twin_page_router
from rpi.api.twin_router import router as twin_router
app.include_router(twin_page_router)
app.include_router(twin_router, dependencies=[Depends(require_api_key)])
# 가전 추가 5단계 — 사진 매핑·확인 주행(2026-09-30). 다른 가전 API와 같은 인증.
from rpi.api.mapping_router import router as mapping_router
app.include_router(mapping_router, dependencies=[Depends(require_api_key)])
# 키오스크 평소 화면(/ambient 인사말·날씨, /connections 연결 상태) -- 다른 읽기 경로와 같은 인증.
from rpi.api.ambient_router import router as ambient_router
app.include_router(ambient_router, dependencies=[Depends(require_api_key)])
# 개발자 API(/dev/*) — 일반 키 위에 **별도 개발자 토큰**을 더 요구한다.
# 꺼져 있으면(기본) 전 경로 404. 계약은 dev_router.py 머리말.
app.include_router(dev_router, dependencies=[Depends(require_api_key)])

_UI_HTML = (pathlib.Path(__file__).parent / "touchscreen" / "index.html").read_text(
    encoding="utf-8"
)

# ── 키오스크 화면 두 벌 ──────────────────────────────────────────────────────
#
# /ui    — 구형 HTML 키오스크(rpi/touchscreen/index.html). 백엔드에 딸려 있어
#          항상 뜬다. 기능은 제안·상태·정지뿐이고 접근성 개편도 반영돼 있지 않다.
# /kiosk — Flutter 키오스크(rpi5-touchscreen-app)를 웹으로 빌드한 것.
#          SSE·센서·큰 글씨·음성 안내가 다 들어 있는 실제 화면이다.
#
# Flutter 쪽은 라즈베리파이에서 빌드할 수 없어(툴체인이 없다) PC에서 만들어
# 복사해 넣는다. 그래서 **없을 수도 있다** -- 없으면 조용히 404를 내는 대신
# 무엇을 해야 하는지 알려주고, cage+Chromium은 /ui로 돌리면 그대로 돈다.
KIOSK_WEB_DIR_ENV = "SIMPLELAY_KIOSK_WEB_DIR"

_KIOSK_MISSING_HTML = """<!doctype html><meta charset="utf-8">
<title>SimpleLay 키오스크</title>
<style>
 body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
      background:#0C0E12;color:#FAF7F2;font-family:system-ui,sans-serif;text-align:center}
 p{color:#A3AAB1;font-size:20px;line-height:1.6}
 code{color:#D9A356}
</style>
<div>
  <h1 style="font-size:34px">키오스크 화면이 아직 없어요</h1>
  <p>PC에서 빌드해 이 기기로 복사해야 합니다.<br>
     <code>scripts/deploy_kiosk.ps1</code><br><br>
     그때까지는 <code>/ui</code>로 구형 화면을 쓸 수 있어요.</p>
</div>"""


def kiosk_web_dir() -> pathlib.Path:
    """Flutter 키오스크 웹 빌드가 놓이는 자리.

    기본값은 리포 옆 ``kiosk-web/`` -- 빌드 산출물이라 git에 넣지 않는다(36MB가
    빌드할 때마다 쌓인다). 기기에서 경로를 바꾸고 싶으면 환경변수로 준다.
    """
    configured = os.environ.get(KIOSK_WEB_DIR_ENV, "").strip()
    if configured:
        return pathlib.Path(configured)
    return pathlib.Path(__file__).resolve().parents[1] / "kiosk-web"


def mount_kiosk(target: FastAPI, directory: pathlib.Path | None = None) -> bool:
    """``/kiosk``를 붙인다. 빌드가 있으면 정적 서빙, 없으면 안내 페이지.

    반환값은 "실제 빌드를 붙였는가" -- 기동 로그에서 어느 쪽인지 보이게 한다.
    같은 오리진에서 서빙하는 것이 중요하다: 키오스크가 /status·/events를 부르는데
    다른 포트면 CORS에 막힌다(백엔드에 CORS 미들웨어가 없다).
    """
    root = directory if directory is not None else kiosk_web_dir()
    if (root / "index.html").is_file():
        target.mount("/kiosk", StaticFiles(directory=root, html=True), name="kiosk")
        return True

    @target.get("/kiosk", response_class=HTMLResponse)
    async def kiosk_not_built() -> HTMLResponse:  # pragma: no cover - 분기만 검증
        return HTMLResponse(content=_KIOSK_MISSING_HTML)

    return False


@app.get("/health", response_model=HealthResponse)
async def health(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
    actuator=Depends(get_actuator_status),
    service=Depends(get_service),
) -> HealthResponse:
    act_mode = os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower() or "local"
    # 홈 스위치 판독은 기한까지 기다릴 수 있다 — 이벤트 루프 밖에서 읽는다
    actuator_ready = await asyncio.to_thread(actuator.is_ready)
    # RPi4(누름 장치) 링크가 끊겼거나 첫 연결 전이면 준비 안 됨(2026-10-06 인계 §6). 보고 없는 실행 대상은 그대로.
    link_up = getattr(service, "actuator_link_up", None)
    if callable(link_up) and link_up() is False:
        actuator_ready = False
    return HealthResponse(
        ok=True,
        actuator_ready=actuator_ready,
        dnd_until=svc.dnd_until(),
        quiet=quiet_status(),
        act_mode=act_mode,
    )


@app.get("/ui", response_class=HTMLResponse)
async def touchscreen_ui() -> HTMLResponse:
    return HTMLResponse(content=_UI_HTML)


# 라우트 등록이 끝난 뒤에 붙인다 -- mount는 경로 앞쪽을 가로채므로 순서가 중요하다.
_KIOSK_BUILT = mount_kiosk(app)
log.info(
    "kiosk UI: %s",
    "Flutter 웹 빌드 (/kiosk)" if _KIOSK_BUILT else "빌드 없음 — /ui 사용",
)


if __name__ == "__main__":
    uvicorn.run("rpi.main:app", host="0.0.0.0", port=8000, reload=False)
