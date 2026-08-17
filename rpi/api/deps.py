"""싱글톤 서비스 의존성 — 하드웨어 없이도 동작하는 mock 구현으로 초기화."""
import os
from datetime import time
from functools import lru_cache

from rpi.controller import ClosedLoopController, ExecutionProgressTracker
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import HttpLlmClient, HttpLlmClientConfig, LlmClient, RuleBasedIntentResolver
from rpi.intent.clock import SystemClock
from rpi.intent.log import InMemoryUsageLog
from rpi.intent.models import PatternConfig, TimeBand
from rpi.intent.patterns import PatternDetector
from rpi.intent.suggestions import ProactiveSuggestionService
from rpi.verifier import MockVerifier

from .service import SimpleLayService

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

    base_url만 바꾸면 온디바이스 로컬 OpenAI 호환 엔드포인트든 데모용 클라우드
    API든 동일한 HttpLlmClient로 그대로 쓸 수 있다 — 코드 분기 없음.
    """
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
def get_service() -> SimpleLayService:
    grbl = MockGrblClient()
    verifier = MockVerifier(outcomes=[True] * 100)
    progress_tracker = ExecutionProgressTracker()
    controller = ClosedLoopController(
        grbl,
        verifier,
        MockAlertSink(),
        MockSafetyController(),
        on_progress=progress_tracker.update,
    )
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
