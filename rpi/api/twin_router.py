"""실모드 디지털 트윈 — 일반 서버(실기기 UART·시뮬레이터 모두)에서 읽기 전용으로 본다.

``/simulator/twin``은 시뮬레이터 내부 관측(act_local)을 쓰므로 SimulatorController에서만
뜬다. 이 라우터는 그 대신 RPi5↔RPi4 **통신 프레임 탭**(rpi/services/link_tap.py)과
RPi4의 ``progress`` 프레임, ``/status``를 근거로 같은 화면(twin.html)을 그린다.

  GET /twin                 화면(HTML). ``?replay=<파일 이름>``이면 기록 재생 모드.
  GET /twin-motion.js       화면 스크립트
  GET /twin/state           상태. ``?replay=<name>&t=<초>``면 기록 파일의 그 시각까지로 만든 상태
  GET /twin/hardware        하드웨어 요약(/simulator/twin/hardware와 같음)
  GET /twin/replays         재생 가능한 세션 기록 목록

화면·스크립트는 데이터가 없어 ``/ui``처럼 키 없이 연다(브라우저 주소창은 X-API-Key를 못
보낸다). 상태·목록은 다른 API와 같은 ``require_api_key``를 탄다(main.py에서 붙인다).
실행 시작 버튼은 없다 — 실행은 앱·키오스크가 한다. 정지는 화면이 기존 ``POST /stop``을 부른다.
결과는 result 프레임에서만 온다. 애니메이션은 결과를 만들지 않는다.
"""
from __future__ import annotations

import os
import pathlib
import re
import threading

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse, Response

from .deps import get_service

page_router = APIRouter()
router = APIRouter(prefix="/twin")

_TOUCHSCREEN = pathlib.Path(__file__).parent.parent / "touchscreen"
_REPLAY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_replay_cache: dict[str, tuple[tuple[float, int], dict]] = {}
_replay_lock = threading.Lock()


@page_router.get("/twin", response_class=HTMLResponse)
def twin_page():
    return (_TOUCHSCREEN / "twin.html").read_text(encoding="utf-8")


@page_router.get("/twin-motion.js")
def twin_motion_script():
    return Response((_TOUCHSCREEN / "twin-motion.js").read_text(encoding="utf-8"),
                    media_type="text/javascript")


def _mode_value(controller: object) -> str:
    mode = getattr(controller, "execution_mode", None)
    value = getattr(mode, "value", mode)
    return value if value in ("real", "mock", "unknown") else "unknown"


def _replay_file(name: str) -> pathlib.Path:
    from rpi.services.link_tap import replay_dir

    if not _REPLAY_NAME.match(name):
        raise HTTPException(422, "replay name must be a plain file name (A-Z, 0-9, . _ -)")
    folder = replay_dir()
    if folder is None:
        raise HTTPException(404, "no replay folder — set SIMPLELAY_SESSION_LOG_PATH or SIMPLELAY_TWIN_REPLAY_DIR")
    path = folder / name
    if not path.is_file():
        raise HTTPException(404, f"replay file not found: {name}")
    return path


def _timeline(name: str) -> dict:
    from rpi.services.twin_view import load_session_log

    path = _replay_file(name)
    stat = path.stat()
    key = (stat.st_mtime, stat.st_size)
    with _replay_lock:
        cached = _replay_cache.get(name)
        if cached is not None and cached[0] == key:
            return cached[1]
    with open(path, encoding="utf-8", errors="replace") as fh:
        timeline = load_session_log(fh)
    with _replay_lock:
        _replay_cache[name] = (key, timeline)
    return timeline


@router.get("/state")
def twin_state(
    replay: str | None = Query(default=None, max_length=128),
    t: float = Query(default=0.0, ge=0, le=86400),
    service=Depends(get_service),
):
    from rpi.services.link_tap import get_link_tap
    from rpi.services.twin_view import build_link_twin_state, build_replay_state

    if replay:
        return build_replay_state(_timeline(replay), t, replay)
    controller = service._controller
    tap = getattr(controller, "frame_tap", None) or get_link_tap()
    try:
        running = bool(service.status().running)
    except Exception:  # noqa: BLE001 - 상태를 못 읽으면 프레임으로만 판단
        running = None
    state = build_link_twin_state(
        tap.frames(),
        last_execute=tap.last_execute(),
        controller_mode=_mode_value(controller),
        transport=tap.transport or os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower() or "local",
        running=running,
    )
    state["session_log"] = {"enabled": tap.enabled,
                            "path": str(tap.current_path()) if tap.enabled else None}
    return state


@router.get("/hardware")
def twin_hardware():
    from rpi.services.twin_view import build_hardware_summary

    return build_hardware_summary()


@router.get("/replays")
def twin_replays():
    from rpi.services.link_tap import replay_dir

    folder = replay_dir()
    if folder is None or not folder.is_dir():
        return {"folder": str(folder) if folder else None, "files": []}
    files = []
    for p in sorted(folder.iterdir(), key=lambda q: q.stat().st_mtime, reverse=True):
        if p.is_file() and ".jsonl" in p.name and _REPLAY_NAME.match(p.name):
            files.append({"name": p.name, "bytes": p.stat().st_size})
    return {"folder": str(folder), "files": files[:100]}
