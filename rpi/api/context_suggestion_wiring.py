"""환경 제안(2026-10-26) — 판정(:mod:`rpi.services.context_suggestions`)에 실제 신호와 시나리오 카드를 붙인다.

- 판정 스레드는 공기질 판독과 같은 조건(``SIMPLELAY_THINQ_MODE``가 off가 아닐 때)에서만 띄운다 — 세 규칙 모두 공기청정기
  카드라 ThinQ 없이는 물을 일이 없다. 전용 데몬 스레드, 주기 ``SIMPLELAY_CONTEXT_POLL_SECONDS``(기본 30초).
- ThinQ를 따로 부르지 않는다: 공기청정기 상태는 공기질 판독이 마지막으로 읽은 것을 빌린다(나이 제한 있음).
- 사람 감지·방 밝기는 각 배선의 메모리 판단만 읽는다(꺼져 있으면 None → 그 신호가 필요한 규칙은 묻지 않는다).
- 기상특보는 날씨 서비스(30분마다 묻고 캐시)를 읽는다 — 이 스레드 안에서만.
- 비상정지가 걸려 있거나 다른 제안 카드가 떠 있으면 묻지 않는다(한 번에 카드 하나).

로그에는 규칙 이름·결과·신호 이름만 쓴다.
"""

from __future__ import annotations

import logging
import threading
import time
from datetime import datetime

log = logging.getLogger(__name__)

#: 모의 공기청정기로 만든 카드의 근거 끝말(공기질 제안의 '연습용 센서 값이에요.'와 같은 모양).
MOCK_SUFFIX = " 연습용 값이에요."
#: 기동 직후 첫 판정까지(초). 시험이 바꾼다.
FIRST_DELAY_SECONDS = 30.0

_lock = threading.Lock()
_monitor = None
_poller = None


def _presence_signals() -> tuple[str | None, float | None]:
    from .room_presence_wiring import get_room_presence  # noqa: PLC0415

    room = get_room_presence()
    if room is None:
        return None, None
    snap = room.snapshot()
    return snap.state, (snap.arrived_at if snap.greet else None)


def _light_signals() -> tuple[float | None, float | None]:
    from .room_presence_wiring import get_room_light  # noqa: PLC0415

    light = get_room_light()
    if light is None:
        return None, None
    since = light.dark_since()
    if since is None:
        return None, None
    return since, max(0.0, light.now() - since)


def _dust_warning() -> bool:
    from rpi.services.context_suggestions import has_dust_warning  # noqa: PLC0415

    from .ambient_router import get_weather_service  # noqa: PLC0415

    try:
        return has_dust_warning(get_weather_service().warnings())
    except Exception:  # noqa: BLE001 -- 특보를 못 읽으면 특보 없음으로(묻지 않을 뿐)
        log.debug("weather warnings unreadable for context rules", exc_info=True)
        return False


def read_signals(purifier_max_age_s: float):
    """지금 신호를 모은다. **판정 스레드에서만** 부른다(특보 조회는 입출력)."""
    from rpi.services.context_suggestions import ContextSignals  # noqa: PLC0415

    from .air_quality_wiring import get_air_monitor  # noqa: PLC0415

    presence, arrival_at = _presence_signals()
    lights_off_at, dark_for_s = _light_signals()
    return ContextSignals(
        local_now=datetime.now().astimezone(),
        presence=presence,
        arrival_at=arrival_at,
        wall_now=time.time(),
        lights_off_at=lights_off_at,
        dark_for_s=dark_for_s,
        purifier=get_air_monitor().recent_state(purifier_max_age_s),
        dust_warning=_dust_warning(),
    )


def blocked_reason() -> str | None:
    """비상정지 걸림·떠 있는 제안 카드면 그 이름. 확인하지 못하면 막는다(묻지 않을 뿐)."""
    from . import deps  # noqa: PLC0415

    try:
        if deps.get_service().estop_latched():
            return "estop"
        if deps.get_suggestion_service().pending():
            return "card_pending"
    except Exception:  # noqa: BLE001
        log.exception("context rule gate check failed")
        return "gate_unknown"
    return None


def offer(scenario_id: str, reason: str):
    """규칙 → 시나리오 카드. 막혔으면 None(조용한 시간·잠시 쉬기·다시 받지 않기·부재·준비 안 됨). 실행하지 않는다."""
    from rpi.controller.models import ExecutionMode  # noqa: PLC0415

    from . import deps  # noqa: PLC0415
    from .thinq_wiring import get_scenario_engine  # noqa: PLC0415

    controller = deps.get_service().thinq_controller
    engine = get_scenario_engine()
    if controller is None or engine is None:
        return None
    is_demo = controller.execution_mode is not ExecutionMode.REAL
    return engine.on_context(scenario_id, reason + (MOCK_SUFFIX if is_demo else ""), is_demo)


def get_monitor():
    global _monitor
    from rpi.services.context_suggestions import ContextRuleConfig, ContextSuggestionMonitor  # noqa: PLC0415

    from .air_quality_wiring import get_air_monitor  # noqa: PLC0415

    with _lock:
        if _monitor is None:
            air = get_air_monitor()
            config = ContextRuleConfig.from_env()
            _monitor = ContextSuggestionMonitor(
                lambda: read_signals(config.purifier_state_max_age_s), offer, blocked=blocked_reason,
                air_card_recent=air.card_recent, note_power_card=air.note_external_card,
                config=config)
        return _monitor


def start_context_poller():
    """서버 기동에서 부른다. ThinQ가 꺼져 있으면 띄우지 않고 None. 스레드만 띄운다(기다리는 일 없음)."""
    global _poller
    from rpi.services.air_quality import AirQualityPoller  # noqa: PLC0415
    from rpi.services.context_suggestions import poll_seconds_from_env  # noqa: PLC0415
    from rpi.services.thinq import ThinqMode  # noqa: PLC0415

    from .thinq_wiring import get_thinq_config  # noqa: PLC0415

    if get_thinq_config().mode is ThinqMode.OFF:
        return None
    monitor = get_monitor()
    with _lock:
        if _poller is not None and _poller.alive:
            return _poller
        _poller = AirQualityPoller(monitor.check_once, interval_s=poll_seconds_from_env(),
                                   first_delay_s=FIRST_DELAY_SECONDS, name="context-suggestions")
        poller = _poller
    poller.start()
    log.info("context suggestions: every %d s", int(poller.interval_s))
    return poller


def stop_context_poller() -> None:
    global _poller
    with _lock:
        poller, _poller = _poller, None
    if poller is not None:
        poller.stop()


def reset_context_suggestions() -> None:
    """시험용 — 스레드를 멈추라 표시하고 기억을 지운다."""
    global _monitor
    stop_context_poller()
    with _lock:
        _monitor = None
