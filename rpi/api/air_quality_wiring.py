"""공기청정기 센서 공기질 제안 — 판독 스레드·시나리오 카드·리허설 주입을 붙인다(2026-10-15).

판정 규칙은 :mod:`rpi.services.air_quality`, 카드 정의는 ``rpi/scenarios/catalog.py``의 ``air_quality_high``(켜져 있을 때
강풍)·``air_quality_power_on``(꺼져 있을 때 켜기 — ThinQ 앱 공기질 센서 '항상' 설정일 때만 꺼진 채 값이 온다).

- 판독 스레드는 ``SIMPLELAY_THINQ_MODE``가 mock·fake_cloud·real일 때만 띄운다(off면 스레드 없음). 스레드는 판독마다
  ThinQ 공기청정기(가전 ID ``air_purifier``)가 등록·추가돼 있는지 먼저 보고, **없으면 ThinQ를 부르지 않는다**.
- 판독은 전용 데몬 스레드에서만 한다 — 이벤트 루프·공유 스레드 풀을 쓰지 않는다. 판독이 멈춰도 ``/stop``·종료는 그것을
  기다리지 않는다(2026-10-14 재확인 수리들과 같은 원칙).
- 주기는 ``SIMPLELAY_AIR_POLL_SECONDS``(기본 120초, 최소 60초). 다른 실행이 진행 중이면 이번 판독을 건너뛴다(확인 조회와
  호출 한도를 다투지 않게). SDK 경로는 최근 1분 호출이 상한(``SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE``)의 절반 이상이면
  건너뛴다 — 나머지는 사용자 명령 몫이다. 상한 자체(넘으면 보내지 않음)는 SDK 클라이언트가 그대로 지킨다.
- 리허설 주입(``POST /demo/thinq/air-quality``)은 mock·fake_cloud에서만 연다. real이면 409. 주입으로 만든 카드는
  시연 카드이고 근거 끝에 '(시연: 모의 센서 값이에요)'가 붙는다.

로그에는 가전 ID만 쓴다(기기 ID·토큰 없음).
"""

from __future__ import annotations

import json
import logging
import threading
import urllib.request

from rpi.commands import ControlRoute

log = logging.getLogger(__name__)

#: 카드 정의(``rpi.scenarios.AIR_QUALITY_HIGH``·``AIR_QUALITY_POWER_ON``)의 시나리오 ID.
AIR_SCENARIO_IDS = ("air_quality_high", "air_quality_power_on")
#: 모의 카드 근거 끝말 — 다른 모의 경로('(시연: 모의 이벤트예요)')와 같은 모양.
MOCK_SUFFIX = " (시연: 모의 센서 값이에요)"
#: 기동 직후 첫 판독까지(초). 시험이 바꾼다.
FIRST_DELAY_SECONDS = 30.0

_lock = threading.Lock()
_monitor = None
_poller = None


class AirInjectError(Exception):
    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


def _purifier(registry):
    from .thinq_wiring import AIR_PURIFIER_ID  # noqa: PLC0415

    appliance = registry.get(AIR_PURIFIER_ID) if registry is not None else None
    if appliance is None or appliance.thinq is None or appliance.control_path is not ControlRoute.THINQ:
        return None
    return appliance


def _read_purifier_state():
    """판독 한 번 — 하지 않을 이유가 있으면 ``AirReadSkipped``. **판독 스레드에서만** 부른다(입출력)."""
    from rpi.services.air_quality import AirReadSkipped  # noqa: PLC0415
    from rpi.services.thinq import ThinqMode  # noqa: PLC0415

    from . import deps  # noqa: PLC0415
    from .thinq_wiring import get_thinq_config  # noqa: PLC0415

    config = get_thinq_config()
    if config.mode is ThinqMode.OFF:
        raise AirReadSkipped("thinq_off")
    service = deps.get_service()
    controller = service.thinq_controller
    if controller is None:
        raise AirReadSkipped("thinq_off")
    appliance = _purifier(deps.get_appliance_registry())
    if appliance is None:
        raise AirReadSkipped("no_purifier")
    if service.status().running:
        raise AirReadSkipped("job_running")
    client = controller.client
    calls = getattr(client, "calls_last_minute", None)
    if callable(calls) and calls() >= max(1, config.max_calls_per_minute // 2):
        raise AirReadSkipped("rate_reserve")
    cached = getattr(client, "cached_status", None)
    device_id = appliance.thinq.device_id
    return cached(device_id) if callable(cached) else client.get_status(device_id)


def _offer(reason: str, *, power_off: bool = False):
    """나쁨 판정 → 시나리오 카드(꺼져 있으면 켜기, 아니면 강풍). 막혔으면 None(조용한 시간·잠시 쉬기·다시 받지 않기·부재·준비 안 됨)."""
    from rpi.controller.models import ExecutionMode  # noqa: PLC0415

    from . import deps  # noqa: PLC0415
    from .thinq_wiring import AIR_PURIFIER_ID, get_scenario_engine  # noqa: PLC0415

    controller = deps.get_service().thinq_controller
    if controller is None:
        return None
    is_demo = controller.execution_mode is not ExecutionMode.REAL
    engine = get_scenario_engine()
    if engine is None:
        return None
    return engine.on_air_quality(AIR_PURIFIER_ID, reason + (MOCK_SUFFIX if is_demo else ""), is_demo,
                                 power_off=power_off)


def get_air_monitor():
    """판독·제안 판정(재알림 기억)을 하나만 둔다. 만드는 데 입출력은 없다."""
    global _monitor
    from rpi.services.air_quality import AirQualityMonitor  # noqa: PLC0415

    with _lock:
        if _monitor is None:
            _monitor = AirQualityMonitor(_read_purifier_state, _offer)
        return _monitor


def start_air_quality_poller():
    """서버 기동(lifespan)에서 부른다. ThinQ가 꺼져 있으면 스레드를 띄우지 않고 None.

    환경 변수만 읽고 스레드만 띄운다 — 이벤트 루프에서 불러도 기다리는 일이 없다(싱글턴 생성·DB·ThinQ는 스레드 안에서)."""
    global _poller
    from rpi.services.air_quality import AirQualityPoller, poll_seconds_from_env  # noqa: PLC0415
    from rpi.services.thinq import ThinqMode  # noqa: PLC0415

    from .thinq_wiring import get_thinq_config  # noqa: PLC0415

    if get_thinq_config().mode is ThinqMode.OFF:
        return None
    monitor = get_air_monitor()
    with _lock:
        if _poller is not None and _poller.alive:
            return _poller
        _poller = AirQualityPoller(monitor.check_once, interval_s=poll_seconds_from_env(),
                                   first_delay_s=FIRST_DELAY_SECONDS)
        poller = _poller
    poller.start()
    log.info("air quality poll: every %d s (ThinQ air purifier sensor only)", int(poller.interval_s))
    return poller


def stop_air_quality_poller() -> None:
    """종료 — 표시만 하고 기다리지 않는다(판독이 멈춰 있어도 종료가 늦지 않게)."""
    global _poller
    with _lock:
        poller, _poller = _poller, None
    if poller is not None:
        poller.stop()


def reset_air_quality() -> None:
    """시험용 — 판독 스레드를 멈추라 표시하고 재알림 기억을 지운다."""
    global _monitor
    stop_air_quality_poller()
    with _lock:
        _monitor = None


# ── 리허설 주입(mock·fake_cloud만) ─────────────────────────────────────────────

def _post_fake_cloud(base_url: str, payload: dict) -> None:
    request = urllib.request.Request(
        base_url.rstrip("/") + "/__fake__/air", data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=5) as response:  # noqa: S310 -- 이 기기 안 주소만(설정이 검사)
        response.read()


def inject_mock_air(controller, registry, level: str, pm2: int | None = None, pm10: int | None = None,
                    forget_recent: bool = False) -> dict:
    """모의 공기청정기 센서 값을 바꾸고 판독을 한 번 바로 한다. real이면 거절(``AirInjectError(409)``).

    ``level``이 ``NONE``이면 센서 칸을 지운다(꺼짐·센서 준비 중 흉내). ``forget_recent``는 재알림 기억(다시 준비·45분)을
    지운다 — 리허설을 되풀이할 때만."""
    from rpi.controller.models import ExecutionMode  # noqa: PLC0415
    from rpi.services.thinq import ThinqMode  # noqa: PLC0415
    from rpi.services.thinq.profiles_sample import air_sensor_sample  # noqa: PLC0415

    from . import deps  # noqa: PLC0415
    from .thinq_wiring import get_thinq_config  # noqa: PLC0415

    if controller.mode is ThinqMode.REAL or controller.execution_mode is ExecutionMode.REAL:
        raise AirInjectError(409, "실제 ThinQ 모드에서는 공기질 값을 주입할 수 없어요 — 모의(mock)·모의 클라우드에서만 돼요")
    appliance = _purifier(registry)
    if appliance is None:
        raise AirInjectError(404, "ThinQ 공기청정기가 등록되지 않았어요")
    sensor = None if level == "NONE" else air_sensor_sample(level, pm2=pm2, pm10=pm10)
    client = controller.client
    setter = getattr(client, "set_air_quality", None)
    if controller.mode is ThinqMode.MOCK and callable(setter):
        setter(sensor)
    elif controller.mode is ThinqMode.FAKE_CLOUD:
        base_url = get_thinq_config().fake_cloud_url
        if not base_url:
            raise AirInjectError(409, "모의 클라우드 주소가 없어요")
        try:
            _post_fake_cloud(base_url, {"device_id": appliance.thinq.device_id, "sensor": sensor})
        except Exception as exc:  # noqa: BLE001 -- 이유만(주소·기기 ID 없이)
            raise AirInjectError(503, f"모의 클라우드에 값을 넣지 못했어요 ({type(exc).__name__})") from None
        forget = getattr(client, "forget_status", None)
        if callable(forget):
            forget(appliance.thinq.device_id)
    else:
        raise AirInjectError(409, "이 모드에서는 공기질 값을 주입할 수 없어요")
    monitor = get_air_monitor()
    if forget_recent:
        monitor.forget_recent()
    outcome = monitor.check_once()
    card = next((s for s in deps.get_suggestion_service().pending() if s.scenario_id in AIR_SCENARIO_IDS), None)
    from .thinq_router import suggestion_payload  # noqa: PLC0415

    return {
        "execution_mode": "mock",
        "level": level,
        "sensor": sensor,
        "check": outcome,
        "suggestion": suggestion_payload(card) if card is not None else None,
    }
