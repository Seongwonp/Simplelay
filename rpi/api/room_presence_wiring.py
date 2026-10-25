"""방 안 사람 감지 배선 — ``SIMPLELAY_ROOM_PRESENCE_FILE``이 있을 때만 켜진다(2026-10-25).

전용 데몬 스레드가 2초마다 감지기 파일을 읽어 :class:`RoomPresence`에 넣는다. 돌아오면(자리 비움·외출 → 있음)
습관 제안을 바로 한 번 만든다 — 1분 주기를 기다리지 않게. 공간 존재 저장소에는 매 주기 지금 판단을 적는다
(자리 비움·외출 = 없음 → 제안 보류는 ``SIMPLELAY_PRESENCE_GATING``을 켰을 때만).
"""

from __future__ import annotations

import contextlib
import logging
import os
import threading
from functools import lru_cache

from rpi.services.room_presence import AWAY, IDLE, PRESENT, RoomPresence, read_reading

log = logging.getLogger(__name__)

POLL_SECONDS = 2.0

_stop = threading.Event()
_thread: threading.Thread | None = None


def _float_env(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, "").strip() or default)
    except ValueError:
        log.warning("%s 값이 숫자가 아니다 — 기본 %s", name, default)
        return default


def room_presence_path() -> str | None:
    return os.environ.get("SIMPLELAY_ROOM_PRESENCE_FILE", "").strip() or None


_NAME_KEY = "resident_name"
_name_memory: dict[str, str | None] = {}


def resident_name() -> str | None:
    """인사에 부를 이름(폰 앱에서 정한다, 허브에만 남는다). 없으면 None — 이름 없이 인사한다."""
    from rpi.api.deps import get_db  # noqa: PLC0415

    db = get_db()
    value = db.load_setting(_NAME_KEY) if db is not None else _name_memory.get(_NAME_KEY)
    if value is None:
        value = os.environ.get("SIMPLELAY_RESIDENT_NAME", "").strip() or None
    return value or None


def clean_name(raw) -> str | None:
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise ValueError("이름은 글자로 적어 주세요")
    name = " ".join(raw.split())
    if len(name) > 10:
        raise ValueError("이름은 10자까지 적을 수 있어요")
    if any(not ch.isprintable() for ch in name):
        raise ValueError("이름에 쓸 수 없는 글자가 있어요")
    return name or None


def set_resident_name(raw) -> str | None:
    from rpi.api.deps import get_db  # noqa: PLC0415

    name = clean_name(raw)
    db = get_db()
    if db is not None:
        db.save_setting(_NAME_KEY, name or "")
    else:
        _name_memory[_NAME_KEY] = name or ""
    return name


def camera_off_flag() -> str | None:
    """카메라 끄기 표시 파일(감지 파일 옆 ``presence_camera_off``). 있으면 본체 감지기가 카메라를 열지 않는다(2026-10-25)."""
    path = room_presence_path()
    return None if path is None else os.path.join(os.path.dirname(path), "presence_camera_off")


def camera_enabled() -> bool:
    flag = camera_off_flag()
    return flag is not None and not os.path.exists(flag)


def set_camera_enabled(enabled: bool) -> bool:
    """사용자가 카메라를 끄고 켠다. 끄면 판단을 '모름'으로 — 화면 절전·제안 보류도 함께 풀린다."""
    flag = camera_off_flag()
    if flag is None:
        return False
    if enabled:
        with contextlib.suppress(FileNotFoundError):
            os.remove(flag)
    else:
        with open(flag, "w", encoding="utf-8") as f:
            f.write("off")
    return camera_enabled()


@lru_cache(maxsize=1)
def get_room_presence() -> RoomPresence | None:
    if room_presence_path() is None:
        return None
    return RoomPresence(
        dim_after_s=_float_env("SIMPLELAY_ROOM_DIM_SECONDS", 600.0),
        away_after_s=_float_env("SIMPLELAY_ROOM_AWAY_SECONDS", 3600.0),
        arrive_frames=int(_float_env("SIMPLELAY_ROOM_ARRIVE_FRAMES", 3)),
        greet_gap_s=_float_env("SIMPLELAY_ROOM_GREET_GAP_SECONDS", 3 * 3600.0),
        greet_after_s=_float_env("SIMPLELAY_ROOM_GREET_AFTER_SECONDS", 3 * 3600.0),
    )


def _publish(room: RoomPresence) -> None:
    """지금 판단을 공간 존재 저장소에 **매 주기** 적는다(저장소 TTL 60초 — 한 번만 적으면 부재 판정이 풀린다).

    자리 비움·외출 모두 '없음' — 사람이 없는 동안 습관 제안을 보류한다(SIMPLELAY_PRESENCE_GATING을 켰을 때).
    모름(감지기 죽음)은 적지 않는다 — 저장소가 스스로 만료돼 제안을 막지 않는다.
    """
    from rpi.api.deps import get_presence_store  # noqa: PLC0415

    state = room.snapshot().state
    if state == PRESENT:
        get_presence_store().set_present(True, "camera")
    elif state in (IDLE, AWAY):
        get_presence_store().set_present(False, "camera")


def _on_arrival() -> None:
    from rpi.api.deps import get_suggestion_service  # noqa: PLC0415

    try:
        get_suggestion_service().create_suggestions()
    except Exception:  # noqa: BLE001 — 제안이 안 돼도 감지는 계속
        log.exception("arrival suggestion refresh failed")


def _loop(path: str) -> None:
    room = get_room_presence()
    while not _stop.is_set():
        try:
            before = room.snapshot().arrived_at
            # 카메라를 끈 동안은 읽지 않는다 — 판단이 '모름'이 되어 화면을 끄지도, 제안을 막지도 않는다.
            changed = room.observe(read_reading(path) if camera_enabled() else None)
            if changed is not None:
                log.info("room presence → %s", changed)
            _publish(room)
            if room.snapshot().arrived_at != before:
                _on_arrival()  # 돌아왔다 — 1분 주기를 기다리지 않고 그 시간대 제안을 한 번 만든다
        except Exception:  # noqa: BLE001
            log.exception("room presence poll failed")
        _stop.wait(POLL_SECONDS)


def start_room_presence_poller() -> None:
    global _thread
    path = room_presence_path()
    if path is None or (_thread is not None and _thread.is_alive()):
        return
    _stop.clear()
    _thread = threading.Thread(target=_loop, args=(path,), daemon=True, name="simplelay-room-presence")
    _thread.start()
    log.info("room presence on: %s", path)


def stop_room_presence_poller() -> None:
    _stop.set()


# ── 방 밝기(2026-10-26) — SIMPLELAY_ROOM_LIGHT_FILE이 있을 때만. 사람 감지와 따로 도는 가벼운 데몬 스레드. ──

_light_stop = threading.Event()
_light_thread: threading.Thread | None = None


def room_light_path() -> str | None:
    return os.environ.get("SIMPLELAY_ROOM_LIGHT_FILE", "").strip() or None


@lru_cache(maxsize=1)
def get_room_light():
    from rpi.services.room_light import RoomLight  # noqa: PLC0415

    if room_light_path() is None:
        return None
    return RoomLight(
        dark_below=_float_env("SIMPLELAY_ROOM_DARK_BELOW", 115.0),
        light_above=_float_env("SIMPLELAY_ROOM_LIGHT_ABOVE", 135.0),
    )


def poll_room_light_once(path: str) -> str | None:
    """한 번 읽어 넣는다. 판단이 바뀌면 한 줄만 남긴다(밤새 문턱 맞추기용 — 영상은 남기지 않는다)."""
    from rpi.services.room_light import read_level  # noqa: PLC0415

    light = get_room_light()
    if light is None:
        return None
    level = read_level(path, stale_s=light.stale_s)
    changed = light.observe(level)
    if changed is not None:
        log.info("room light → %s (mean=%s)", changed, light.snapshot().level)
    return changed


def _light_loop(path: str) -> None:
    while not _light_stop.is_set():
        try:
            poll_room_light_once(path)
        except Exception:  # noqa: BLE001
            log.exception("room light poll failed")
        _light_stop.wait(POLL_SECONDS)


def start_room_light_poller() -> None:
    global _light_thread
    path = room_light_path()
    if path is None or (_light_thread is not None and _light_thread.is_alive()):
        return
    _light_stop.clear()
    _light_thread = threading.Thread(target=_light_loop, args=(path,), daemon=True, name="simplelay-room-light")
    _light_thread.start()
    log.info("room light on: %s", path)


def stop_room_light_poller() -> None:
    _light_stop.set()
