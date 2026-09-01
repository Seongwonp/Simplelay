"""싱글톤 서비스 의존성 — 하드웨어 없이도 동작하는 mock 구현으로 초기화."""
import logging
import os
import threading
from datetime import time
from functools import lru_cache

from .config import hardware_config

from rpi.controller import ExecutionProgressTracker
from rpi.intent import (
    DbusAgentLlmClient,
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
from rpi.services import (
    DangerAlertStore,
    EspNodeController,
    NodeRegistry,
    build_controller,
)
from rpi.services.demo_failure import DemoFailureState
from rpi.services.history import InMemoryJobHistory, JobHistoryStore
from rpi.services.persistence import (
    SimpleLayDb,
    SqliteJobHistory,
    SqliteSuppressionStore,
    SqliteUsageLog,
)
from rpi.intent.suppression import InMemorySuppressionStore
from rpi.intent.ports import SuppressionStore
from rpi.services.presence import PresenceStore

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


DBUS_TRANSPORT_ENV = "SIMPLELAY_DBUS_TRANSPORT"


def _build_vectordb_client():
    """유사도 계층이 쓸 vectordb 클라이언트를 전송 방식대로 고른다.

    - ``native`` (기본): dbus-fast로 시스템 버스에 직접 붙는다. 우리 백엔드가 도는
      플랫폼 컨테이너에는 D-Bus CLI가 없으므로 이쪽이 프로덕션 경로다. 반환값이
      타입으로 와서 CLI 텍스트 파싱의 불확실성이 없다.
    - ``cli``: 플랫폼 D-Bus CLI 서브프로세스. CLI가 있는 환경(호스트 직접 실행 등)용.

    ``native``인데 dbus-fast가 없으면(설치 안 됨) 무엇을 깔아야 하는지 짚으며 실패한다
    -- SIMPLELAY_LLM_MODE=dbus를 켠 사람은 전송도 함께 준비했어야 맞다.
    """
    transport = os.environ.get(DBUS_TRANSPORT_ENV, "native").strip().lower()
    if transport == "cli":
        return VectordbClient()
    if transport in {"", "native"}:
        try:
            from rpi.intent.dbus_native import DbusFastVectordbClient
        except ImportError as exc:  # pragma: no cover - 기기에서만
            raise RuntimeError(
                f"{DBUS_TRANSPORT_ENV}=native 인데 dbus-fast가 없습니다: "
                'pip install -e ".[dbus]" (플랫폼 컨테이너에서 설치). '
                f"CLI를 쓰려면 {DBUS_TRANSPORT_ENV}=cli."
            ) from exc
        return DbusFastVectordbClient()
    raise RuntimeError(
        f"알 수 없는 {DBUS_TRANSPORT_ENV}={transport!r} (native | cli)"
    )


def _build_llm_client() -> LlmClient | None:
    """LLM 클라이언트를 환경변수로만 구성한다 — 기본값 없이, 명시적으로 설정
    안 하면 None(오프라인 우선 원칙: 안 켜면 해당 기능이 그냥 꺼져 있다).

    두 경로가 있고 운영자가 명시적으로 골라야 한다(자동 폴백 없음):
    - ``SIMPLELAY_LLM_MODE=dbus``: 기기 내장 대화형 에이전트(D-Bus 경유) — 새
      하드웨어·네트워크 불필요, 기본으로 밀고 싶은 경로지만 실기기 안정성이 아직
      데모 전 검증 필요. 서비스 주소는 환경에서 읽으므로(rpi/dbus_env.py) 이 모드를
      켜고 주소를 안 주면 기동 시 어떤 변수가 비었는지 짚으며 실패한다.
    - ``SIMPLELAY_LLM_BASE_URL`` (그 외): OpenAI 호환 HTTP 엔드포인트 — 데모
      때 온디바이스가 불안정하면 이 값만 클라우드 API로 바꿔서 즉시 대체 가능.
    """
    mode = os.environ.get("SIMPLELAY_LLM_MODE", "").strip().lower()
    if mode == "dbus":
        return DbusAgentLlmClient()

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


@lru_cache(maxsize=1)
def get_job_history() -> JobHistoryStore:
    db = get_db()
    return SqliteJobHistory(db) if db is not None else InMemoryJobHistory()


def _build_intent_resolver() -> IntentResolver:
    """docs/inference-boundary.md의 온디바이스 우선 3계층 조립.

    1) 규칙 기반 — 항상. 정확·결정론적 매칭 + 별칭. 인메모리 조회라 지연이
       사실상 0이고 결과가 항상 같다.
    2) 벡터DB 유사도 — 온디바이스, ``SIMPLELAY_LLM_MODE=dbus``일 때만
       (개발 PC에는 D-Bus 서비스가 없다). DB가 비어 있으면 항상 미스라
       무해하게 다음 계층으로 넘어간다.
    3) LLM — 설정된 경우에만 최후 수단. 어휘 제약 없이 호출되므로
       (서버는 내장 가전 버튼맵을 모른다) 모델 출력 검증은 라벨 존재
       확인 없이 JSON 형태 검증만 적용된다는 한계를 감수한다.

    규칙이 벡터DB보다 **먼저**여야 하는 이유(이전에는 반대였다):
    - 벡터DB 조회는 CLI 서브프로세스 왕복이다. 규칙으로 끝날 문장까지 그 비용을
      물 이유가 없다.
    - 더 중요한 건 정확성이다. 먼저 성공한 계층이 이기므로(tiered.py), 벡터DB가
      앞에 있으면 **유사도 매칭이 정확한 규칙을 덮어쓸 수 있다** — 임계값을
      넘기만 하면 엉뚱한 시퀀스가 이긴다. 규칙이 앞이면 정확 매칭이 항상 우선하고,
      벡터DB는 규칙이 놓친 표현만 받는다(원래 의도한 역할).
    """
    tiers: list[IntentResolver] = [RuleBasedIntentResolver()]
    if os.environ.get("SIMPLELAY_LLM_MODE", "").strip().lower() == "dbus":
        tiers.append(VectordbIntentResolver(_build_vectordb_client()))
    llm = _build_llm_client()
    if llm is not None:
        tiers.append(LlmIntentResolver(llm))
    if len(tiers) == 1:
        return tiers[0]
    return TieredIntentResolver(tuple(tiers))


@lru_cache(maxsize=1)
def get_alert_store() -> DangerAlertStore:
    return DangerAlertStore(_clock)


log = logging.getLogger(__name__)

NODE_TRANSPORT_ENV = "SIMPLELAY_NODE_TRANSPORT"
GATEWAY_PORT_ENV = "SIMPLELAY_GATEWAY_PORT"
GATEWAY_BAUD_ENV = "SIMPLELAY_GATEWAY_BAUD"
DEFAULT_GATEWAY_BAUD = 115200

# 게이트웨이 UART 읽기 타임아웃. **유한해야 한다** -- 무한 블로킹이면 응답이 끊긴
# 순간 실행 대기 루프가 마감 시각을 확인하지 못해 영원히 붙잡힌다.
GATEWAY_READ_TIMEOUT_SECONDS = 0.2


@lru_cache(maxsize=1)
def _get_gateway_link():
    """ESP-NOW 게이트웨이(UART로 붙은 ESP32)와의 링크. 모든 노드가 하나를 공유한다.

    pyserial은 기기에서만 필요하므로 여기서 늦게 import한다 -- 개발 PC에 없어도
    HTTP 모드는 그대로 돌아야 한다.
    """
    from rpi.services.espnow_node_controller import EspNowGatewayLink

    # 설정 누락을 라이브러리 부재보다 **먼저** 알린다 -- 둘 다 없을 때
    # ModuleNotFoundError가 뜨면 정작 고쳐야 할 것이 가려진다.
    port_path = os.environ.get(GATEWAY_PORT_ENV, "").strip()
    if not port_path:
        raise RuntimeError(
            f"{NODE_TRANSPORT_ENV}=espnow 인데 {GATEWAY_PORT_ENV}가 없습니다 "
            f"(예: /dev/ttyAMA0). 기기의 /etc/simplelay/environment에 추가하세요."
        )

    try:
        import serial  # noqa: PLC0415 -- 기기 전용 의존성
    except ModuleNotFoundError as exc:  # pragma: no cover - 기기에서만 발생
        raise RuntimeError(
            "ESP-NOW 전송에는 pyserial이 필요합니다: "
            'pip install -e ".[gpio]" (기기에서만 설치)'
        ) from exc

    baud = int(os.environ.get(GATEWAY_BAUD_ENV, DEFAULT_GATEWAY_BAUD))
    return EspNowGatewayLink(
        serial.Serial(port_path, baud, timeout=GATEWAY_READ_TIMEOUT_SECONDS),
        on_unclaimed_line=handle_gateway_line,
    )


def handle_gateway_line(doc: dict) -> None:
    """게이트웨이 UART에서 온, 노드 실행 응답이 아닌 줄.

    이 보드는 폰 BLE 폴백 브릿지를 겸하므로 같은 UART에 브릿지 트래픽이 함께 흐른다.
    그중 **``abort``는 보드의 물리 E-STOP 버튼**이다(firmware/src/main.cpp의
    handleEstop). 여기 소비자를 붙이기 전까지 그 줄은 아무도 읽지 않았다 --
    하드웨어 비상정지가 소프트웨어 긴급 정지에 연결돼 있지 않은 상태였다.

    링크의 디스패처 스레드에서 불린다(리더 스레드가 아니다). 그래도 오래 붙잡지는
    말 것 -- 뒤에 다른 줄이 밀린다.
    """
    kind = doc.get("type")
    if kind == "abort":
        log.warning("게이트웨이 물리 E-STOP 수신 — 긴급 정지를 실행합니다")
        get_service().emergency_stop()
        return
    # 나머지(intent·confirm·sensor_log 등)는 아직 RPi5 쪽 소비자가 없다.
    # 조용히 버리지 않고 남긴다 -- 없어진 줄을 나중에 추적할 수 있어야 한다.
    log.info("게이트웨이 UART에 아직 처리기가 없는 메시지: %s", kind)


def _node_controller_factory():
    """등록된 노드 주소로 컨트롤러를 만드는 함수를 고른다.

    전송을 **명시적으로** 고른다(자동 감지 없음). 주소 모양(URL이냐 MAC이냐)으로
    추측하면 오타 하나가 조용히 다른 전송을 타게 되고, 시연장에서 "왜 안 되는지"를
    좁힐 수 없다 -- SIMPLELAY_ACT_MODE·SIMPLELAY_LLM_MODE와 같은 원칙.

    기본은 http. 이 배선이 없던 동안에는 펌웨어에서 ESP-NOW를 켜고 MAC을 등록해도
    RPi5가 그 MAC을 HTTP 주소로 취급했다(교차 리뷰 치명 지적) -- 신규 경로가
    프로덕션에는 존재하지 않는 상태였다.
    """
    mode = os.environ.get(NODE_TRANSPORT_ENV, "http").strip().lower()
    if mode in {"", "http"}:
        return EspNodeController
    if mode == "espnow":
        from rpi.services.espnow_node_controller import controller_factory

        return controller_factory(_get_gateway_link())
    raise RuntimeError(
        f"{NODE_TRANSPORT_ENV}는 http 또는 espnow여야 합니다 (받은 값: {mode!r})"
    )


@lru_cache(maxsize=1)
def get_appliance_registry():
    """가전 정의의 단일 진실원천 — 내장 + 폰에서 등록한 커스텀.
    SIMPLELAY_DB_PATH가 있으면 커스텀 등록이 재시작에도 유지된다."""
    from rpi.services import ApplianceRegistry  # noqa: PLC0415

    return ApplianceRegistry(store=get_db())


@lru_cache(maxsize=1)
def get_node_registry() -> NodeRegistry:
    """가전별 원격 노드(다중 노드 아키텍처) 등록부 — 처음엔 비어있고,
    ``POST /nodes/{appliance_id}``로 채워진다. 여기 없는 appliance_id는
    (또는 아예 안 실린 요청은) 그냥 로컬 기본 컨트롤러로 실행된다.
    SIMPLELAY_DB_PATH가 있으면 등록이 SQLite에 저장돼 재시작에도 유지된다.

    전송(HTTP/ESP-NOW)은 ``SIMPLELAY_NODE_TRANSPORT``로 고른다 —
    등록되는 주소의 의미가 달라진다(HTTP는 URL, ESP-NOW는 MAC)."""
    return NodeRegistry(store=get_db(), controller_factory=_node_controller_factory())


@lru_cache(maxsize=1)
def get_demo_failure_state() -> DemoFailureState:
    """데모 실패 주입 상태 — POST /demo/inject-failure가 무장하고,
    로컬 컨트롤러의 verifier 래퍼가 소비한다."""
    return DemoFailureState()


@lru_cache(maxsize=1)
def get_service() -> SimpleLayService:
    progress_tracker = ExecutionProgressTracker()
    store = get_alert_store()
    controller = build_controller(
        progress_tracker,
        on_alert=store.record,
        failure_state=get_demo_failure_state(),
    )
    return SimpleLayService(
        intent=_build_intent_resolver(),
        controller=controller,
        usage_log=get_usage_log(),
        clock=_clock,
        progress_tracker=progress_tracker,
        llm_client=_build_llm_client(),
        node_registry=get_node_registry(),
        history_store=get_job_history(),
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
def get_presence_store() -> PresenceStore:
    """공간 존재 상태 — RPi4 카메라 감지기가 POST /presence로 갱신한다.
    TTL(60초)이 지나면 unknown으로 복귀(죽은 감지기의 영구 차단 방지)."""
    return PresenceStore(_clock)


def _build_presence_gate():
    """SIMPLELAY_PRESENCE_GATING=true일 때만 부재 중 자동 제안 보류를
    배선한다 — 기본은 None(기존 동작 불변, 감지기 없는 구성 안전)."""
    enabled = (
        os.environ.get("SIMPLELAY_PRESENCE_GATING", "false").strip().lower()
        == "true"
    )
    if not enabled:
        return None
    return get_presence_store().allows_suggestions


@lru_cache(maxsize=1)
def get_suppression_store() -> SuppressionStore:
    db = get_db()
    return (
        SqliteSuppressionStore(db)
        if db is not None
        else InMemorySuppressionStore()
    )


class EnvironmentOverride:
    """데모용 온습도 강제값. 설정되면 /sensors와 환경 제안이 이 값을 본다.
    센서 미연결(현장) 대비 데모에서 "더운 상황"을 연출할 때 쓴다."""

    def __init__(self) -> None:
        self._value: tuple[float, float] | None = None
        self._lock = threading.Lock()

    def set(self, temperature: float, humidity: float) -> None:
        with self._lock:
            self._value = (temperature, humidity)

    def clear(self) -> None:
        with self._lock:
            self._value = None

    def current(self) -> tuple[float, float] | None:
        with self._lock:
            return self._value


@lru_cache(maxsize=1)
def get_environment_override() -> EnvironmentOverride:
    return EnvironmentOverride()


def _read_environment() -> tuple[float | None, float | None]:
    forced = get_environment_override().current()
    if forced is not None:
        return forced
    return get_dht22().read()


def _build_environmental_suggester():
    from rpi.intent.environment import EnvironmentalSuggester  # noqa: PLC0415

    return EnvironmentalSuggester(_read_environment)


@lru_cache(maxsize=1)
def get_suggestion_service() -> ProactiveSuggestionService:
    detector = PatternDetector(get_usage_log(), _clock, _PATTERN_CONFIG)
    # 미리보기 해석은 빠르고 오프라인이어야 하므로 규칙 계층만 쓴다 —
    # 실제 실행 시퀀스는 approve 시점에 서비스의 전체 리졸버로 다시 해석된다.
    return ProactiveSuggestionService(
        detector,
        _clock,
        get_service(),
        intent_resolver=RuleBasedIntentResolver(),
        presence_gate=_build_presence_gate(),
        suppression_store=get_suppression_store(),
        environmental=_build_environmental_suggester(),
    )
