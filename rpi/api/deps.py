"""싱글톤 서비스 의존성 — 하드웨어 없이도 동작하는 mock 구현으로 초기화."""
import logging
import os
from datetime import time
from functools import lru_cache

from rpi.controller import ClosedLoopController, ExecutionProgressTracker
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import (
    Dbusinternal_aiLlmClient,
    HttpLlmClient,
    HttpLlmClientConfig,
    LlmClient,
    RuleBasedIntentResolver,
)
from rpi.intent.clock import SystemClock
from rpi.intent.log import InMemoryUsageLog
from rpi.intent.models import PatternConfig, TimeBand
from rpi.intent.patterns import PatternDetector
from rpi.intent.suggestions import ProactiveSuggestionService
from rpi.services.act_client_controller import ActClientController, open_uart_act_controller
from rpi.verifier import MockVerifier

from .service import SimpleLayService

log = logging.getLogger(__name__)

_usage_log = InMemoryUsageLog()
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


def _build_controller(
    progress_tracker: ExecutionProgressTracker,
) -> ClosedLoopController | ActClientController:
    """폐루프 실행기를 환경변수로 고른다 — 기본은 이 프로세스 안에서 mock
    하드웨어로 직접 도는 로컬 ClosedLoopController(오프라인 우선 원칙).

    ``SIMPLELAY_ACT_MODE=uart``: 진짜 RPi4 보드에 UART로 시퀀스를 통째로
    보내고 결과만 기다리는 ActClientController. 단, RPi4는 지금 집계 결과
    (success/retry)만 보내므로 버튼별 실시간 진행상황은 안 옴 — 실행 중엔
    /status의 current_button 등이 계속 비어 있는다(docs/roadmap.md M2 참고).
    """
    mode = os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower()
    if mode == "uart":
        port = os.environ.get("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
        baud = int(os.environ.get("SIMPLELAY_UART_BAUD", "115200"))

        def _log_alert(event):
            log.warning(
                "RPi4 alert: kind=%s raised=%s band_energy_ratio=%s mean_period_seconds=%s",
                event.kind, event.raised, event.band_energy_ratio, event.mean_period_seconds,
            )

        return open_uart_act_controller(port, baud, on_alert=_log_alert)

    grbl = MockGrblClient()
    verifier = MockVerifier(outcomes=[True] * 100)
    return ClosedLoopController(
        grbl,
        verifier,
        MockAlertSink(),
        MockSafetyController(),
        on_progress=progress_tracker.update,
    )


@lru_cache(maxsize=1)
def get_service() -> SimpleLayService:
    progress_tracker = ExecutionProgressTracker()
    controller = _build_controller(progress_tracker)
    return SimpleLayService(
        intent=RuleBasedIntentResolver(),
        controller=controller,
        usage_log=_usage_log,
        clock=_clock,
        progress_tracker=progress_tracker,
        llm_client=_build_llm_client(),
    )


@lru_cache(maxsize=1)
def get_suggestion_service() -> ProactiveSuggestionService:
    detector = PatternDetector(_usage_log, _clock, _PATTERN_CONFIG)
    return ProactiveSuggestionService(
        detector, _clock, get_service(), intent_resolver=RuleBasedIntentResolver()
    )
