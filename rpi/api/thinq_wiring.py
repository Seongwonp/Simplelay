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

연습 기기(2026-10-18): ``SIMPLELAY_THINQ_PRACTICE_DEVICES=washer``면 SDK 모드(real·fake_cloud)에서도 모의 세탁기 한 대를
'LG 세탁기(연습)'(가전 ID ``thinq_washer``)로 더한다. 그 기기만 모의 클라이언트로 가고(:mod:`rpi.services.thinq.practice`),
실행 결과·상태 조회의 실행 환경이 mock이라 화면이 '연습'으로 보인다. 세탁기 자리가 이미 있으면(환경 변수·추가) 더하지 않는다.

기기 등록 두 갈래(2026-10-13): 위 환경 변수(서버 설정)와 **발견 → 사용자 확인 후 추가**
(``GET /thinq/discovered`` → ``POST /thinq/added``). 추가한 기기는 서버 DB에 남아 재시작 뒤에도
다시 등록된다. 종류마다 가전 ID 자리가 하나라 둘 다 있어도 겹치지 않는다(환경 변수가 먼저).
"""

from __future__ import annotations

import logging
import threading
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
#: 연습 세탁기 이름 — 사용자 등록 버튼식 '세탁기'(작은 팔용)와 구분한다(2026-10-18).
PRACTICE_WASHER_NAME = "LG 세탁기(연습)"


@lru_cache(maxsize=1)
def get_thinq_config():
    from rpi.services.thinq import ThinqConfig  # noqa: PLC0415

    return ThinqConfig.from_env()


#: 우리 종류(``discovery.KINDS``의 kind) → (가전 ID, 이름, 가전 종류 이름). 종류마다 가전 ID가 하나라
#: 환경 변수로 넣은 기기와 사용자가 추가한 기기가 같은 자리를 두고 겹치지 않는다(한 종류에 한 대).
_KIND_SLOTS = {
    "air_purifier": (AIR_PURIFIER_ID, "공기청정기", "AIR_PURIFIER"),
    "washer": (WASHER_ID, "세탁기", "WASHING_MACHINE"),
    # 가전 종류 목록(폰과 공유하는 계약)에 제습기가 없어 other로 둔다.
    "dehumidifier": (DEHUMIDIFIER_ID, "제습기", "OTHER"),
}
#: 환경 변수 키(``ThinqConfig.device_ids``) → 우리 종류.
_ENV_KEY_KIND = {AIR_PURIFIER_ID: "air_purifier", WASHER_DEVICE_KEY: "washer",
                 DEHUMIDIFIER_ID: "dehumidifier"}


def _suffix(mode) -> str:
    from rpi.services.thinq import ThinqMode  # noqa: PLC0415

    return {ThinqMode.MOCK: "(모의)", ThinqMode.FAKE_CLOUD: "(모의 클라우드)"}.get(mode, "")


def appliance_for(kind: str, device_id: str, name: str):
    """우리 종류 + ThinQ 기기 ID → 서버 구성 가전(ThinQ 경로)."""
    from rpi.services.appliance_registry import ApplianceCategory, ApplianceDef  # noqa: PLC0415
    from rpi.services.thinq.discovery import KINDS  # noqa: PLC0415

    appliance_id, _, category = _KIND_SLOTS[kind]
    binding = next(k.binding for k in KINDS.values() if k.kind == kind)
    return ApplianceDef(
        appliance_id=appliance_id, name=name, rows=0, cols=0, buttons=(),
        category=ApplianceCategory[category], control_path=ControlRoute.THINQ,
        thinq=binding(device_id),
    )


def _thinq_appliances(config):
    from rpi.services.thinq import (  # noqa: PLC0415
        MOCK_DEHUMIDIFIER_ID,
        MOCK_PURIFIER_ID,
        MOCK_WASHER_ID,
        ThinqMode,
    )

    if config.mode is ThinqMode.MOCK:
        ids = {AIR_PURIFIER_ID: MOCK_PURIFIER_ID, WASHER_DEVICE_KEY: MOCK_WASHER_ID,
               DEHUMIDIFIER_ID: MOCK_DEHUMIDIFIER_ID}
    else:
        ids = dict(config.device_ids)
    suffix = _suffix(config.mode)
    appliances = []
    for key in (AIR_PURIFIER_ID, WASHER_DEVICE_KEY, DEHUMIDIFIER_ID):
        if ids.get(key):
            kind = _ENV_KEY_KIND[key]
            appliances.append(appliance_for(kind, ids[key], f"{_KIND_SLOTS[kind][1]}{suffix}"))
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
        from rpi.services.thinq.mock_client import air_sensor_always_from_env  # noqa: PLC0415

        return MockThinqClient(air_sensor_always=air_sensor_always_from_env())
    if not config.mode.uses_sdk:
        return None
    from rpi.services.thinq.sdk_client import SdkThinqClient  # noqa: PLC0415

    if config.mode is ThinqMode.FAKE_CLOUD:
        from rpi.tools.fake_thinq_cloud import FAKE_CLOUD_TOKEN  # noqa: PLC0415

        # 모의 클라우드에는 실제 PAT를 보내지 않는다. 클라이언트 ID도 실행마다 새로(실제 ID 파일 미사용).
        log.info("ThinQ fake_cloud mode: 공식 SDK → 모의 클라우드 %s (실제 클라우드 아님)",
                 config.fake_cloud_url)
        return _with_practice(
            SdkThinqClient(access_token=FAKE_CLOUD_TOKEN, country=config.country,
                           client_id=str(uuid.uuid4()), execution_mode=ExecutionMode.MOCK,
                           base_url=config.fake_cloud_url,
                           max_calls_per_minute=config.max_calls_per_minute), config)
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
    return _with_practice(client, config)


def _with_practice(client, config):
    """연습 기기를 섞는다(SDK 모드만, 2026-10-18). 없으면 클라이언트 그대로."""
    if not config.practice_devices or not config.mode.uses_sdk:
        return client
    from rpi.services.thinq.practice import (  # noqa: PLC0415
        PRACTICE_DEVICE_IDS,
        PracticeMixClient,
        practice_washer_client,
    )

    ids = [PRACTICE_DEVICE_IDS[kind] for kind in config.practice_devices]
    log.info("ThinQ 연습 기기(모의) 함께 사용: %s", ", ".join(config.practice_devices))
    return PracticeMixClient(client, practice_washer_client(), ids)


def _register_practice(registry, config) -> None:
    """연습 기기를 서버 구성 가전으로 등록한다 — 환경 변수·추가 기기 뒤(실제가 자리를 먼저 갖는다)."""
    if not config.practice_devices or not config.mode.uses_sdk:
        return
    from rpi.services.thinq.practice import PRACTICE_DEVICE_IDS  # noqa: PLC0415

    for kind in config.practice_devices:
        if _slot_taken(registry, kind):
            log.info("ThinQ 연습 %s는 같은 자리에 실제 가전이 있어 더하지 않았어요", kind)
            continue
        registry.register_system(appliance_for(kind, PRACTICE_DEVICE_IDS[kind], PRACTICE_WASHER_NAME))


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
    _restore_added(registry, config)
    _register_practice(registry, config)
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
                                 confirm_seconds=config.confirm_seconds, poll_interval=poll,
                                 observe_state=get_power_cache().observe)
    return controller, system


# ── 전원 기억(2026-10-16) — 키오스크 가전 줄의 '켜짐'. 이미 하는 조회 결과만 적는다(새 호출 없음) ──

_power_cache = None
_power_lock = threading.Lock()


def get_power_cache():
    """ThinQ 가전 전원 기억(:mod:`rpi.services.thinq.power`) 하나. 입출력 없음."""
    global _power_cache
    from rpi.services.thinq.power import ThinqPowerCache  # noqa: PLC0415

    with _power_lock:
        if _power_cache is None:
            _power_cache = ThinqPowerCache()
        return _power_cache


# ── 발견 → 사용자 확인 후 추가 (2026-10-13) ──────────────────────────────
#
# 발견(GET)은 아무것도 등록하지 않는다. 추가는 사용자가 누를 때만(POST) 하고, 추가한 기기만
# 서버 구성 가전으로 등록돼 기존 ThinQ 경로(준비 판정·승인·제어·확인·기록)에 들어간다. 실행은
# 추가 뒤에도 종전처럼 승인 카드·직접 명령을 거친다. 기기 ID 원문은 서버 DB에만 두고, API에는
# ``device_key``만, 로그에는 가전 ID만 쓴다.

ADDED_SETTING_PREFIX = "thinq_added_devices:"
_added_lock = threading.Lock()
_CLOUD_DOWN = "ThinQ 클라우드에 연결되지 않았어요 — 인터넷 연결을 확인해 주세요"


class DiscoveryError(Exception):
    """추가·제거를 할 수 없다. ``status``는 HTTP 상태, 메시지는 사람 말 이유."""

    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


@lru_cache(maxsize=1)
def get_added_store():
    """사용자가 추가한 ThinQ 기기. 서버 DB(설정 칸, 모드별)가 있으면 재시작에도 남는다."""
    from rpi.services.thinq.discovery import ThinqAddedStore  # noqa: PLC0415

    from .deps import get_db  # noqa: PLC0415

    db = get_db()
    if db is None:
        return ThinqAddedStore()
    key = ADDED_SETTING_PREFIX + get_thinq_config().mode.value
    return ThinqAddedStore(load=lambda: db.load_setting(key),
                           save=lambda value: db.save_setting(key, value))


def _added_name(entry, mode) -> str:
    from rpi.services.thinq.discovery import kind_label  # noqa: PLC0415

    name = (entry.alias or "").strip()[:40] or kind_label(entry.device_type)
    suffix = _suffix(mode)
    return name if not suffix or suffix in name else f"{name}{suffix}"


def _slot_taken(registry, kind: str) -> bool:
    """그 종류의 가전 ID 자리를 이미 누가(환경 변수·추가·사용자 가전) 쓰는가."""
    return registry.get(_KIND_SLOTS[kind][0]) is not None


def _restore_added(registry, config) -> None:
    """기동 때 추가했던 기기를 다시 등록한다. 환경 변수로 이미 들어온 자리는 건너뛴다."""
    from rpi.services.thinq.discovery import KINDS  # noqa: PLC0415

    for entry in get_added_store().entries():
        kind = KINDS.get(entry.device_type)
        if kind is None or _slot_taken(registry, kind.kind):
            log.info("ThinQ 추가 가전 하나는 이미 같은 자리가 있어 다시 등록하지 않았어요")
            continue
        try:
            registry.register_system(appliance_for(kind.kind, entry.device_id,
                                                   _added_name(entry, config.mode)))
        except ValueError:
            log.warning("ThinQ 추가 가전 하나를 다시 등록하지 못했어요(가전 ID 겹침)")


def _registered_by_device(registry) -> dict:
    return {a.thinq.device_id: a for a in registry.system_appliances() if a.thinq is not None}


def _client_reason(exc: Exception) -> str | None:
    from rpi.services.thinq.client import ThinqClientError  # noqa: PLC0415

    reason = getattr(exc, "reason", None) if isinstance(exc, ThinqClientError) else None
    return reason if isinstance(reason, str) and reason else None


def _support_of(client, device):
    from rpi.services.thinq.discovery import KINDS, UNKNOWN, Support, classify  # noqa: PLC0415

    if device.device_type not in KINDS:
        return classify(device.device_type, None)
    try:
        return classify(device.device_type, client.get_profile(device.device_id))
    except Exception as exc:  # noqa: BLE001 -- 이유만 싣는다
        return Support(UNKNOWN, "지원 여부를 확인하지 못했어요 — "
                       + (_client_reason(exc) or "기기 프로필을 읽지 못했어요"))


def discover(controller, registry) -> dict:
    """계정의 기기 목록 + 지원 판정 + 추가 여부. 목록 조회 실패는 ``reachable: false``와 이유."""
    from rpi.services.thinq import ThinqMode  # noqa: PLC0415
    from rpi.services.thinq.discovery import CONTROLLABLE, KINDS, device_key, kind_label  # noqa: PLC0415

    client = controller.client
    head = {"mode": controller.mode.value, "execution_mode": controller.execution_mode.value,
            "mock_cloud": controller.mode is ThinqMode.FAKE_CLOUD}
    try:
        devices = client.list_devices()
    except Exception as exc:  # noqa: BLE001 -- 사람 말 이유만 싣는다(토큰·ID 없음)
        return {**head, "reachable": False, "error": _client_reason(exc) or _CLOUD_DOWN, "devices": []}
    store = get_added_store()
    registered = _registered_by_device(registry)
    rows = []
    for device in devices:
        kind = KINDS.get(device.device_type)
        support = _support_of(client, device)
        appliance = registered.get(device.device_id)
        can_add, reason = False, None
        if appliance is None:
            if support.support != CONTROLLABLE:
                reason = support.reason
            elif _slot_taken(registry, kind.kind):
                reason = f"이미 다른 {kind.label}가 연결돼 있어요 — 한 종류에 한 대만 추가할 수 있어요"
            else:
                can_add = True
        rows.append({
            "key": device_key(device.device_id),
            "device_type": device.device_type,
            "kind": kind.kind if kind is not None else None,
            "kind_label": kind_label(device.device_type),
            "alias": device.alias,
            "model_name": device.model_name,
            "support": support.support,
            "support_reason": support.reason,
            "actions": list(support.actions),
            "added": appliance is not None,
            "source": None if appliance is None else (
                "added" if store.contains(device.device_id) else "config"),
            "appliance_id": appliance.appliance_id if appliance is not None else None,
            "name": appliance.name if appliance is not None else None,
            "can_add": can_add,
            "reason": reason,
        })
    return {**head, "reachable": True, "error": None, "devices": rows}


def add_discovered(controller, registry, key: str) -> dict:
    """사용자가 누른 기기 하나를 추가한다. 지원·자리를 다시 확인하고, 저장한 뒤 등록한다."""
    from rpi.services.thinq.discovery import CONTROLLABLE, KINDS, AddedDevice, device_key  # noqa: PLC0415

    client = controller.client
    try:
        devices = client.list_devices()
    except Exception as exc:  # noqa: BLE001
        raise DiscoveryError(503, (_client_reason(exc) or _CLOUD_DOWN) + " (추가하지 않았어요)") from None
    device = next((d for d in devices if device_key(d.device_id) == key), None)
    if device is None:
        raise DiscoveryError(404, "ThinQ 계정 목록에서 그 가전을 찾지 못했어요 — 목록을 다시 불러와 주세요")
    store = get_added_store()
    with _added_lock:
        existing = _registered_by_device(registry).get(device.device_id)
        if existing is not None:  # 이미 있다 -- 같은 기기를 두 번 넣지 않는다
            return {"appliance_id": existing.appliance_id, "name": existing.name, "added": True,
                    "source": "added" if store.contains(device.device_id) else "config"}
        support = _support_of(client, device)
        if support.support != CONTROLLABLE:
            raise DiscoveryError(409, support.reason + " (추가하지 않았어요)")
        kind = KINDS[device.device_type]
        if _slot_taken(registry, kind.kind):
            raise DiscoveryError(
                409, f"이미 다른 {kind.label}가 연결돼 있어요 — 한 종류에 한 대만 추가할 수 있어요")
        entry = AddedDevice(device.device_id, device.device_type, device.alias, device.model_name)
        appliance = appliance_for(kind.kind, device.device_id, _added_name(entry, controller.mode))
        try:
            registry.register_system(appliance)
        except ValueError:
            raise DiscoveryError(409, "같은 ID의 가전이 이미 있어 추가하지 않았어요") from None
        store.add(entry)
    log.info("ThinQ 가전 추가(사용자 확인): %s", appliance.appliance_id)
    return {"appliance_id": appliance.appliance_id, "name": appliance.name, "added": True,
            "source": "added"}


def remove_added(registry, key: str) -> dict:
    """사용자가 추가한 기기를 뺀다. 환경 변수로 넣은 기기는 여기서 빼지 않는다."""
    from rpi.services.thinq.discovery import device_key  # noqa: PLC0415

    store = get_added_store()
    with _added_lock:
        entry = store.by_key(key)
        if entry is None:
            if any(device_key(d) == key for d in _registered_by_device(registry)):
                raise DiscoveryError(409, "서버 설정(환경 변수)으로 넣은 가전이라 여기서 뺄 수 없어요")
            raise DiscoveryError(404, "추가한 ThinQ 가전 중에 그 가전이 없어요")
        appliance = _registered_by_device(registry).get(entry.device_id)
        appliance_id = appliance.appliance_id if appliance is not None else None
        if appliance_id is not None:
            registry.unregister_system(appliance_id)
        store.remove(entry.device_id)
    log.info("ThinQ 가전 제거(사용자): %s", appliance_id)
    return {"appliance_id": appliance_id, "removed": True}


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
    get_added_store.cache_clear()
    _engine = None
    if _power_cache is not None:
        _power_cache.clear()
    from .air_quality_wiring import reset_air_quality  # noqa: PLC0415

    reset_air_quality()
