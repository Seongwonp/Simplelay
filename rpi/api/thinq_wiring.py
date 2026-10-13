"""ThinQ 경로·시나리오 조립 — ``SIMPLELAY_THINQ_MODE``로만 켠다(기본 off).

- off: 아무것도 등록하지 않는다. 기존 동작과 같다.
- mock: 모의 클라이언트 + 모의 공기청정기·세탁기(``thinq_washer``)·제습기(ThinQ 경로) + 모의 선풍기(물리 경로,
  모의 실행기). 전부 **서버 구성 가전**이라 저장·편집되지 않고 GET /appliances에
  나오지 않는다.
- fake_cloud: **공식 SDK**가 저장소 안 모의 ThinQ 클라우드(``rpi/tools/fake_thinq_cloud.py``,
  127.0.0.1)로 요청한다. 실행 환경은 모의(mock), 가전 이름에 '(모의 클라우드)'. 기기 ID는 real과
  같은 환경 변수로 준다(모의 클라우드 기기 ID).
- real: 공식 SDK → 실제 ThinQ 클라우드. 기기 ID는 ``SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER``·
  ``..._WASHER``·``..._DEHUMIDIFIER``로 준다. **SDK·PAT가 없으면 기동을 거절한다**(PAT 값은
  로그에 쓰지 않는다 -- 있는지만 적는다).
"""

from __future__ import annotations

import logging
from functools import lru_cache

from rpi.commands import ControlRoute

log = logging.getLogger(__name__)

AIR_PURIFIER_ID = "air_purifier"
#: ThinQ 세탁기의 **가전 ID**. 버튼식 세탁기를 사용자가 ``washer``로 등록할 수 있게 비켜 둔다(2026-10-06,
#: 시연 v3 갭 S4·S7). real 모드 기기 ID 환경 변수 이름은 그대로 ``SIMPLELAY_THINQ_DEVICE_WASHER``다.
WASHER_ID = "thinq_washer"
#: ``ThinqConfig.device_ids``의 키(환경 변수 이름에서 온다).
WASHER_DEVICE_KEY = "washer"
DEHUMIDIFIER_ID = "dehumidifier"
FAN_ID = "fan"


@lru_cache(maxsize=1)
def get_thinq_config():
    from rpi.services.thinq import ThinqConfig  # noqa: PLC0415

    return ThinqConfig.from_env()


def _thinq_appliances(config):
    from rpi.services.appliance_registry import ApplianceCategory, ApplianceDef  # noqa: PLC0415
    from rpi.services.thinq import (  # noqa: PLC0415
        MOCK_DEHUMIDIFIER_ID,
        MOCK_PURIFIER_ID,
        MOCK_WASHER_ID,
        ThinqMode,
        air_purifier_binding,
        dehumidifier_binding,
        washer_binding,
    )

    if config.mode is ThinqMode.MOCK:
        ids = {AIR_PURIFIER_ID: MOCK_PURIFIER_ID, WASHER_DEVICE_KEY: MOCK_WASHER_ID,
               DEHUMIDIFIER_ID: MOCK_DEHUMIDIFIER_ID}
        suffix = "(모의)"
    else:
        ids = dict(config.device_ids)
        suffix = "(모의 클라우드)" if config.mode is ThinqMode.FAKE_CLOUD else ""
    appliances = []
    if ids.get(AIR_PURIFIER_ID):
        appliances.append(ApplianceDef(
            appliance_id=AIR_PURIFIER_ID, name=f"공기청정기{suffix}", rows=0, cols=0, buttons=(),
            category=ApplianceCategory.AIR_PURIFIER, control_path=ControlRoute.THINQ,
            thinq=air_purifier_binding(ids[AIR_PURIFIER_ID]),
        ))
    if ids.get(WASHER_DEVICE_KEY):
        appliances.append(ApplianceDef(
            appliance_id=WASHER_ID, name=f"세탁기{suffix}", rows=0, cols=0, buttons=(),
            category=ApplianceCategory.WASHING_MACHINE, control_path=ControlRoute.THINQ,
            thinq=washer_binding(ids[WASHER_DEVICE_KEY]),
        ))
    if ids.get(DEHUMIDIFIER_ID):
        # 가전 종류 목록(폰과 공유하는 계약)에 제습기가 없어 other로 둔다 -- 서버 구성
        # 가전이라 GET /appliances에는 나오지 않는다.
        appliances.append(ApplianceDef(
            appliance_id=DEHUMIDIFIER_ID, name=f"제습기{suffix}", rows=0, cols=0, buttons=(),
            category=ApplianceCategory.OTHER, control_path=ControlRoute.THINQ,
            thinq=dehumidifier_binding(ids[DEHUMIDIFIER_ID]),
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
    """모드별 클라이언트. SDK 모드(real·fake_cloud)는 조건이 안 맞으면 **기동을 거절**한다."""
    import uuid  # noqa: PLC0415

    from rpi.controller.models import ExecutionMode  # noqa: PLC0415
    from rpi.services.thinq import MockThinqClient, ThinqMode  # noqa: PLC0415
    from rpi.services.thinq.config import load_access_token, load_or_create_client_id  # noqa: PLC0415

    config = get_thinq_config()
    if config.mode is ThinqMode.MOCK:
        return MockThinqClient()
    if not config.mode.uses_sdk:
        return None
    from rpi.services.thinq.sdk_client import SdkThinqClient  # noqa: PLC0415

    if config.mode is ThinqMode.FAKE_CLOUD:
        from rpi.tools.fake_thinq_cloud import FAKE_CLOUD_TOKEN  # noqa: PLC0415

        # 모의 클라우드에는 실제 PAT를 보내지 않는다. 클라이언트 ID도 실행마다 새로(실제 ID 파일 미사용).
        log.info("ThinQ fake_cloud mode: 공식 SDK → 모의 클라우드 %s (실제 클라우드 아님)",
                 config.fake_cloud_url)
        return SdkThinqClient(access_token=FAKE_CLOUD_TOKEN, country=config.country,
                              client_id=str(uuid.uuid4()), execution_mode=ExecutionMode.MOCK,
                              base_url=config.fake_cloud_url,
                              max_calls_per_minute=config.max_calls_per_minute)
    token = load_access_token()
    if not token:
        raise RuntimeError(
            "SIMPLELAY_THINQ_MODE=real에는 PAT가 필요합니다 — SIMPLELAY_THINQ_PAT 또는 "
            "저장소 밖 파일 SIMPLELAY_THINQ_PAT_FILE (docs/ThinQ-실물-확인-절차.md)")
    client = SdkThinqClient(access_token=token, country=config.country,
                            client_id=load_or_create_client_id(), execution_mode=ExecutionMode.REAL,
                            max_calls_per_minute=config.max_calls_per_minute)
    del token
    log.info("ThinQ real mode: 공식 SDK, PAT 설정됨, country %s", config.country)
    return client


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

    # SDK 모드는 조회 한 번이 클라우드 호출 한 번이다 -- 확인 조회 간격을 넓혀 호출 한도를 아낀다.
    poll = 0.5 if config.mode.uses_sdk else 0.25
    controller = ThinqController(client, binding_of, mode=config.mode,
                                 confirm_seconds=config.confirm_seconds, poll_interval=poll)
    return controller, system


_engine = None


def wire_scenarios(suggestions, service):
    """시나리오 엔진을 제안 서비스·실행 서비스·ThinQ 이벤트에 붙인다(한 번)."""
    global _engine
    from rpi.scenarios import ScenarioCatalog, ScenarioEngine, scenarios_from_env  # noqa: PLC0415

    # 기본은 v3 빈 카탈로그 — v2 시나리오(공기청정기·선풍기·제습기)는 SIMPLELAY_V2_SCENARIOS로만.
    engine = ScenarioEngine(ScenarioCatalog(scenarios_from_env()), suggestions, service)
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
    if get_thinq_client.cache_info().currsize:
        try:
            close = getattr(get_thinq_client(), "close", None)
            if close is not None:
                close()
        except Exception:  # noqa: BLE001 -- 정리 실패가 초기화를 막지 않는다
            pass
    get_thinq_config.cache_clear()
    get_thinq_client.cache_clear()
    _engine = None
