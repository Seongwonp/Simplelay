"""싱글톤 서비스 의존성 — 하드웨어 없이도 동작하는 mock 구현으로 초기화."""
import os
from datetime import time
from functools import lru_cache

from .config import hardware_config

from rpi.controller import ExecutionProgressTracker
from rpi.intent import (
    Dbusinternal_aiLlmClient,
    HttpLlmClient,
    HttpLlmClientConfig,
    LlmClient,
    RuleBasedIntentResolver,
)
from rpi.intent.base import IntentResolver
from rpi.intent.clock import SystemClock
from rpi.intent.dbus_vectordb import VectordbClient, VectordbIntentResolver
from rpi.intent.llm import LlmIntentResolver
from rpi.intent.log import InMemoryUsageLog
from rpi.intent.models import PatternConfig, TimeBand
from rpi.intent.patterns import PatternDetector
from rpi.intent.ports import UsageLog
from rpi.intent.suggestions import ProactiveSuggestionService
from rpi.intent.tiered import TieredIntentResolver
from rpi.services import DangerAlertStore, NodeRegistry, build_controller
from rpi.services.persistence import SimpleLayDb, SqliteUsageLog

from .service import SimpleLayService

_clock = SystemClock()

_PATTERN_CONFIG = PatternConfig(
    minimum_occurrences=3,
    time_bands=(
        TimeBand("아침", time(6, 0), time(10, 0)),
        TimeBand("점심", time(11, 0), time(14, 0)),
        TimeBand("저녁", time(17, 0), time(21, 0)),
        TimeBand("야간", time(21, 0), time(6, 0)),
    ),
)


def _build_llm_client() -> LlmClient | None:
    """LLM 클라이언트를 환경변수로만 구성한다 — 기본값 없이, 명시적으로 설정
    안 하면 None(오프라인 우선 원칙: 안 켜면 해당 기능이 그냥 꺼져 있다).

    두 경로가 있고 운영자가 명시적으로 골라야 한다(자동 폴백 없음):
    - ``SIMPLELAY_LLM_MODE=dbus``: 온디바이스 internal_ai 에이전트(D-Bus, internal_gpio+
      busctl monitor 기반) — 새 하드웨어·네트워크 불필요, 기본으로 밀고 싶은
      경로지만 실기기 안정성이 아직 데모 전 검증 필요.
    - ``SIMPLELAY_LLM_BASE_URL`` (그 외): OpenAI 호환 HTTP 엔드포인트 — 데모
      때 온디바이스가 불안정하면 이 값만 클라우드 API로 바꿔서 즉시 대체 가능.
    """
    mode = os.environ.get("SIMPLELAY_LLM_MODE", "").strip().lower()
    if mode == "dbus":
        return Dbusinternal_aiLlmClient()

    base_url = os.environ.get("SIMPLELAY_LLM_BASE_URL")
    if not base_url:
        return None
    return HttpLlmClient(
        HttpLlmClientConfig(
            base_url=base_url,
            api_key=os.environ.get("SIMPLELAY_LLM_API_KEY", ""),
            model=os.environ.get("SIMPLELAY_LLM_MODEL", ""),
        )
    )


@lru_cache(maxsize=1)
def get_db() -> SimpleLayDb | None:
    """SQLite 영속화 — SIMPLELAY_DB_PATH가 설정된 경우에만 켠다.

    미설정(개발 PC·테스트)이면 None → 사용 이력·노드 등록이 기존처럼
    인메모리로 동작해 테스트끼리 파일 상태로 오염되지 않는다. 실기기는
    systemd 서비스 파일이 경로를 지정한다.
    """
    path = os.environ.get("SIMPLELAY_DB_PATH", "").strip()
    if not path:
        return None
    return SimpleLayDb(path)


@lru_cache(maxsize=1)
def get_usage_log() -> UsageLog:
    db = get_db()
    return SqliteUsageLog(db) if db is not None else InMemoryUsageLog()


def _build_intent_resolver() -> IntentResolver:
    """docs/inference-boundary.md의 온디바이스 우선 3계층 조립.

    1) 벡터DB 유사도 — 온디바이스, ``SIMPLELAY_LLM_MODE=dbus``일 때만
       (개발 PC에는 D-Bus 서비스가 없다). DB가 비어 있으면 항상 미스라
       무해하게 다음 계층으로 넘어간다 — 예시 시딩은 실기기 작업.
    2) 규칙 기반 — 항상. 정확·결정론적 1차 매칭 + 별칭.
    3) LLM — 설정된 경우에만 최후 수단. 어휘 제약 없이 호출되므로
       (서버는 내장 가전 버튼맵을 모른다) 모델 출력 검증은 라벨 존재
       확인 없이 JSON 형태 검증만 적용된다는 한계를 감수한다.
    """
    tiers: list[IntentResolver] = []
    if os.environ.get("SIMPLELAY_LLM_MODE", "").strip().lower() == "dbus":
        tiers.append(VectordbIntentResolver(VectordbClient()))
    tiers.append(RuleBasedIntentResolver())
    llm = _build_llm_client()
    if llm is not None:
        tiers.append(LlmIntentResolver(llm))
    if len(tiers) == 1:
        return tiers[0]
    return TieredIntentResolver(tuple(tiers))


@lru_cache(maxsize=1)
def get_alert_store() -> DangerAlertStore:
    return DangerAlertStore(_clock)


@lru_cache(maxsize=1)
def get_node_registry() -> NodeRegistry:
    """가전별 원격 노드(다중 노드 아키텍처) 등록부 — 처음엔 비어있고,
    ``POST /nodes/{appliance_id}``로 채워진다. 여기 없는 appliance_id는
    (또는 아예 안 실린 요청은) 그냥 로컬 기본 컨트롤러로 실행된다.
    SIMPLELAY_DB_PATH가 있으면 등록이 SQLite에 저장돼 재시작에도 유지된다."""
    return NodeRegistry(store=get_db())


@lru_cache(maxsize=1)
def get_service() -> SimpleLayService:
    progress_tracker = ExecutionProgressTracker()
    store = get_alert_store()
    controller = build_controller(progress_tracker, on_alert=store.record)
    return SimpleLayService(
        intent=_build_intent_resolver(),
        controller=controller,
        usage_log=get_usage_log(),
        clock=_clock,
        progress_tracker=progress_tracker,
        llm_client=_build_llm_client(),
        node_registry=get_node_registry(),
    )


@lru_cache(maxsize=1)
def get_dht22() -> "Dht22Sensor":
    from rpi.services.dht22 import Dht22Sensor  # noqa: PLC0415

    return Dht22Sensor(
        gpio_bcm=hardware_config.dht22_gpio,
        enabled=hardware_config.gpio_enabled,
    )


@lru_cache(maxsize=1)
def get_actuator_status() -> "ActuatorStatus":
    from rpi.services.actuator import ActuatorStatus  # noqa: PLC0415

    return ActuatorStatus(
        home_x_pin=hardware_config.home_switch_x_gpio,
        home_y_pin=hardware_config.home_switch_y_gpio,
        home_z_pin=hardware_config.home_switch_z_gpio,
        enabled=hardware_config.gpio_enabled,
    )


@lru_cache(maxsize=1)
def get_suggestion_service() -> ProactiveSuggestionService:
    detector = PatternDetector(get_usage_log(), _clock, _PATTERN_CONFIG)
    # 미리보기 해석은 빠르고 오프라인이어야 하므로 규칙 계층만 쓴다 —
    # 실제 실행 시퀀스는 approve 시점에 서비스의 전체 리졸버로 다시 해석된다.
    return ProactiveSuggestionService(
        detector, _clock, get_service(), intent_resolver=RuleBasedIntentResolver()
    )
