"""Intent-to-button-sequence translation."""

from .appliance import (
    ApplianceManifest,
    ApplianceManifestError,
    ButtonSpec,
    load_button_map,
)
from .base import IntentResolver
from .clock import SystemClock
from .dbus_agent import (
    DbusAgentClientConfig,
    DbusAgentClientError,
    DbusAgentLlmClient,
)
from .dbus_vectordb import (
    SearchResult,
    VectordbClient,
    VectordbClientConfig,
    VectordbClientError,
    VectordbIntentResolver,
    VectordbResolverConfig,
    VectordbSearcher,
    parse_search_text_output,
    seed_examples,
)
from .llm import (
    HttpLlmClient,
    HttpLlmClientConfig,
    LlmIntentResolver,
    LlmOutputError,
    LlmSequenceValidationError,
)
from .log import InMemoryUsageLog
from .models import (
    PatternCandidate,
    PatternConfig,
    ProactiveSuggestion,
    SuggestionStatus,
    TimeBand,
    UsageOutcome,
    UsageRecord,
    UsageSource,
)
from .patterns import PatternDetector
from .ports import Clock, LlmClient, PurposeExecutor, UsageLog
from .rules import RuleBasedIntentResolver, UnknownIntentError
from .suggestions import (
    ProactiveSuggestionService,
    SuggestionAlreadyApprovedError,
    UnknownSuggestionError,
)
from .tiered import TieredIntentResolver

__all__ = [
    "ApplianceManifest",
    "ApplianceManifestError",
    "ButtonSpec",
    "Clock",
    "DbusAgentClientConfig",
    "DbusAgentClientError",
    "DbusAgentLlmClient",
    "HttpLlmClient",
    "HttpLlmClientConfig",
    "InMemoryUsageLog",
    "IntentResolver",
    "LlmClient",
    "LlmIntentResolver",
    "LlmOutputError",
    "LlmSequenceValidationError",
    "PatternCandidate",
    "PatternConfig",
    "PatternDetector",
    "ProactiveSuggestion",
    "ProactiveSuggestionService",
    "PurposeExecutor",
    "RuleBasedIntentResolver",
    "SearchResult",
    "SuggestionAlreadyApprovedError",
    "SuggestionStatus",
    "SystemClock",
    "TieredIntentResolver",
    "TimeBand",
    "UnknownIntentError",
    "UnknownSuggestionError",
    "UsageLog",
    "UsageOutcome",
    "UsageRecord",
    "UsageSource",
    "VectordbClient",
    "VectordbClientConfig",
    "VectordbClientError",
    "VectordbIntentResolver",
    "VectordbResolverConfig",
    "VectordbSearcher",
    "load_button_map",
    "parse_search_text_output",
    "seed_examples",
]
