import asyncio
import contextlib
import logging
import os
import pathlib

import uvicorn
from fastapi import Depends, FastAPI
from fastapi.responses import HTMLResponse

from rpi.api.auth import require_api_key
from rpi.api.deps import get_actuator_status, get_suggestion_service
from rpi.api.router import router
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
            get_suggestion_service().create_suggestions()
        except Exception:  # 제안 생성 실패가 서버를 죽여선 안 된다
            log.exception("suggestion refresh failed")
        await asyncio.sleep(SUGGESTION_REFRESH_SECONDS)


async def _shutdown_cleanup() -> None:
    """종료 절차: 신규 job 차단 → 협조 정지 → 잠시 대기 → 자원 정리.

    이전에는 제안 task만 취소해서, systemd 재시작 시 백그라운드 실행
    스레드(daemon)가 물리 컨트롤러에 아무 정지 명령 없이 증발했다.
    """
    from rpi.api.deps import get_db, get_service  # noqa: PLC0415

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
    try:
        db = get_db()
        if db is not None:
            db.close()
    except Exception:
        log.exception("db close failed")


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    refresh_task = asyncio.create_task(_suggestion_refresh_loop())
    try:
        yield
    finally:
        refresh_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await refresh_task
        await _shutdown_cleanup()


app = FastAPI(title="SimpleLay RPi API", version="0.1.0", lifespan=lifespan)
# SIMPLELAY_API_KEY 설정 시 라우터 전체에 X-API-Key 요구 (auth.py 참고).
# /health(아래)와 /ui는 의도적으로 키 없이 개방.
app.include_router(router, dependencies=[Depends(require_api_key)])

_UI_HTML = (pathlib.Path(__file__).parent / "touchscreen" / "index.html").read_text(
    encoding="utf-8"
)


@app.get("/health", response_model=HealthResponse)
async def health(
    svc: ProactiveSuggestionService = Depends(get_suggestion_service),
    actuator=Depends(get_actuator_status),
) -> HealthResponse:
    act_mode = os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower() or "local"
    return HealthResponse(
        ok=True,
        actuator_ready=actuator.is_ready(),
        dnd_until=svc.dnd_until(),
        act_mode=act_mode,
    )


@app.get("/ui", response_class=HTMLResponse)
async def touchscreen_ui() -> HTMLResponse:
    return HTMLResponse(content=_UI_HTML)


if __name__ == "__main__":
    uvicorn.run("rpi.main:app", host="0.0.0.0", port=8000, reload=False)
