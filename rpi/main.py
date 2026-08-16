import pathlib

import uvicorn
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse

from rpi.api.router import router

app = FastAPI(title="SimpleLay RPi API", version="0.1.0")
app.include_router(router)

_UI_HTML = (pathlib.Path(__file__).parent / "touchscreen" / "index.html").read_text(
    encoding="utf-8"
)


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"ok": True})


@app.get("/ui", response_class=HTMLResponse)
async def touchscreen_ui() -> HTMLResponse:
    return HTMLResponse(content=_UI_HTML)


if __name__ == "__main__":
    uvicorn.run("rpi.main:app", host="0.0.0.0", port=8000, reload=False)
