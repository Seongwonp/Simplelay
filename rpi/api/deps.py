"""싱글톤 서비스 의존성 — 하드웨어 없이도 동작하는 mock 구현으로 초기화."""
from datetime import time
from functools import lru_cache

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
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


@lru_cache(maxsize=1)
def get_service() -> SimpleLayService:
    grbl = MockGrblClient()
    verifier = MockVerifier(outcomes=[True] * 100)
    controller = ClosedLoopController(
        grbl, verifier, MockAlertSink(), MockSafetyController()
    )
    return SimpleLayService(
        intent=RuleBasedIntentResolver(),
        controller=controller,
        usage_log=_usage_log,
        clock=_clock,
    )


@lru_cache(maxsize=1)
def get_suggestion_service() -> ProactiveSuggestionService:
    detector = PatternDetector(_usage_log, _clock, _PATTERN_CONFIG)
    return ProactiveSuggestionService(detector, _clock, get_service())
