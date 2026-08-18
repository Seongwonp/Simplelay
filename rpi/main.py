import pathlib

import uvicorn
from fastapi import Depends, FastAPI
from fastapi.responses import HTMLResponse

from rpi.api.deps import get_actuator_status, get_suggestion_service
from rpi.api.router import router
from rpi.api.schemas import HealthResponse
from rpi.intent.suggestions import ProactiveSuggestionService

app = FastAPI(title="SimpleLay RPi API", version="0.1.0")
app.include_router(router)

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
