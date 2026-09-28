"""ThinQ 경로·시나리오 조립 — ``SIMPLELAY_THINQ_MODE``로만 켠다(기본 off).

- off: 아무것도 등록하지 않는다. 기존 동작과 같다.
- mock: 모의 클라이언트 + 모의 공기청정기·세탁기(ThinQ 경로) + 모의 선풍기(물리 경로,
  모의 실행기). 전부 **서버 구성 가전**이라 저장·편집되지 않고 GET /appliances에
  나오지 않는다.
- real: 실물 클라이언트 자리(호출하면 NotImplementedError). 기기 ID는
  ``SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER``·``..._WASHER``로 준다. PAT가 없으면 기동은
  하되 준비 상태가 '미연결'로 남는다(PAT는 로그에 쓰지 않는다 -- 있는지만 적는다).
"""

from __future__ import annotations

import logging
from functools import lru_cache

from rpi.commands import ControlRoute

log = logging.getLogger(__name__)

AIR_PURIFIER_ID = "air_purifier"
WASHER_ID = "washer"
FAN_ID = "fan"


@lru_cache(maxsize=1)
def get_thinq_config():
    from rpi.services.thinq import ThinqConfig  # noqa: PLC0415

    return ThinqConfig.from_env()


def _thinq_appliances(config):
    from rpi.services.appliance_registry import ApplianceCategory, ApplianceDef  # noqa: PLC0415
    from rpi.services.thinq import (  # noqa: PLC0415
        MOCK_PURIFIER_ID,
        MOCK_WASHER_ID,
        ThinqMode,
        air_purifier_binding,
        washer_binding,
    )

    if config.mode is ThinqMode.MOCK:
        ids = {AIR_PURIFIER_ID: MOCK_PURIFIER_ID, WASHER_ID: MOCK_WASHER_ID}
        suffix = "(모의)"
    else:
        ids = dict(config.device_ids)
        suffix = ""
    appliances = []
    if ids.get(AIR_PURIFIER_ID):
        appliances.append(ApplianceDef(
            appliance_id=AIR_PURIFIER_ID, name=f"공기청정기{suffix}", rows=0, cols=0, buttons=(),
            category=ApplianceCategory.AIR_PURIFIER, control_path=ControlRoute.THINQ,
            thinq=air_purifier_binding(ids[AIR_PURIFIER_ID]),
        ))
    if ids.get(WASHER_ID):
        appliances.append(ApplianceDef(
            appliance_id=WASHER_ID, name=f"세탁기{suffix}", rows=0, cols=0, buttons=(),
            category=ApplianceCategory.WASHING_MACHINE, control_path=ControlRoute.THINQ,
            thinq=washer_binding(ids[WASHER_ID]),
        ))
    return appliances


def _mock_fan():
    from rpi.services.appliance_registry import ApplianceButtonDef, ApplianceDef  # noqa: PLC0415

    return ApplianceDef(
        appliance_id=FAN_ID, name="선풍기(모의)", rows=1, cols=3,
        buttons=(
            ApplianceButtonDef("FN-01", "전원", 0, 0),
            ApplianceButtonDef("FN-02", "약풍", 1, 0),
            ApplianceButtonDef("FN-03", "강풍", 2, 0),
        ),
    )


@lru_cache(maxsize=1)
def get_thinq_client():
    from rpi.services.thinq import MockThinqClient, RealThinqClient, ThinqMode  # noqa: PLC0415

    config = get_thinq_config()
    if config.mode is ThinqMode.MOCK:
        return MockThinqClient()
    if config.mode is ThinqMode.REAL:
        log.info("ThinQ real mode: PAT %s, country %s (실물 호출은 아직 미구현)",
                 "설정됨" if config.has_pat else "없음", config.country)
        return RealThinqClient(has_pat=config.has_pat, country=config.country)
    return None


def build_command_paths(registry):
    """서비스 생성 시 부른다: (ThinQ 실행기, 서버 구성 물리 실행기)."""
    from rpi.services.mock_physical import MockButtonController  # noqa: PLC0415
    from rpi.services.thinq import ThinqController, ThinqMode  # noqa: PLC0415

    config = get_thinq_config()
    client = get_thinq_client()
    if client is None:
        return None, {}
    for appliance in _thinq_appliances(config):
        registry.register_system(appliance)
    system = {}
    if config.mode is ThinqMode.MOCK:
        registry.register_system(_mock_fan())
        system[FAN_ID] = MockButtonController()

    def binding_of(appliance_id):
        appliance = registry.get(appliance_id)
        return appliance.thinq if appliance is not None else None

    controller = ThinqController(client, binding_of, mode=config.mode,
                                 confirm_seconds=config.confirm_seconds)
    return controller, system


_engine = None


def wire_scenarios(suggestions, service):
    """시나리오 엔진을 제안 서비스·실행 서비스·ThinQ 이벤트에 붙인다(한 번)."""
    global _engine
    from rpi.scenarios import ScenarioCatalog, ScenarioEngine  # noqa: PLC0415

    engine = ScenarioEngine(ScenarioCatalog(), suggestions, service)
    client = get_thinq_client()
    subscribe = getattr(client, "subscribe", None)
    if subscribe is not None and not getattr(client, "_simplelay_dispatch", False):
        # 클라이언트당 한 번만 — 이벤트는 그 시점의 엔진으로 보낸다.
        subscribe(lambda record: _engine.on_thinq_event(record) if _engine else None)
        client._simplelay_dispatch = True
    _engine = engine
    return engine


def forward_to_scenarios(event) -> None:
    """실행 서비스의 완료 이벤트 → 지금의 시나리오 엔진. 서비스가 먼저 만들어져도 된다."""
    engine = get_scenario_engine()
    if engine is not None:
        engine.on_job_finished(event)


def get_scenario_engine():
    # 제안 서비스가 (다시) 만들어질 때마다 wire_scenarios가 _engine을 갈아 끼운다.
    from .deps import get_suggestion_service  # noqa: PLC0415

    get_suggestion_service()
    return _engine


def reset_thinq_caches() -> None:
    """테스트용 — 환경 변수를 바꾼 뒤 부른다."""
    global _engine
    get_thinq_config.cache_clear()
    get_thinq_client.cache_clear()
    _engine = None
