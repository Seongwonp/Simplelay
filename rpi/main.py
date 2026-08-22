import asyncio
import contextlib
import logging
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


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    refresh_task = asyncio.create_task(_suggestion_refresh_loop())
    try:
        yield
    finally:
        refresh_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await refresh_task


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
    return HealthResponse(
        ok=True,
        actuator_ready=actuator.is_ready(),
        dnd_until=svc.dnd_until(),
    )


@app.get("/ui", response_class=HTMLResponse)
async def touchscreen_ui() -> HTMLResponse:
    return HTMLResponse(content=_UI_HTML)


if __name__ == "__main__":
    uvicorn.run("rpi.main:app", host="0.0.0.0", port=8000, reload=False)
