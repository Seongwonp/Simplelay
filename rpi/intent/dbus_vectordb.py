"""On-device similarity search for intent resolution, via the platform's
internal_ai vector-DB D-Bus service. Meant to sit between RuleBasedIntentResolver
(exact match, zero risk) and an LLM-based resolver (flexible, slower) in a
TieredIntentResolver chain -- fast, offline "fuzzy" matching against a small
set of known purpose -> button-sequence examples, without a full
conversational round trip.

Uses the same subprocess `internal_gpio call` pattern as internal_gpio_gpio.py /
dbus_internal_ai.py -- no Python D-Bus binding available on this platform yet.

CAUTION -- unverified against real hardware this pass (RPi5 was offline):
the exact text `internal_gpio call` prints for AddText's a{sv} metadata argument
and SearchText's aa{sv} return value has not been captured from a live
device, unlike dbus_internal_ai.py's ``Response: "..."`` pattern, which WAS
confirmed there. ``_format_metadata_arg`` and ``parse_search_text_output``
follow the D-Bus API PDF's own example invocations as closely as possible
and are isolated as small, independently swappable pure functions
specifically so they're a quick fix once real output is captured.
"""

from __future__ import annotations

import json
import re
import subprocess
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from .base import IntentResolver
from .rules import UnknownIntentError

CompletedProcess = subprocess.CompletedProcess[str]
Runner = Callable[[list[str]], CompletedProcess]

_METADATA_BUTTONS_KEY = "buttons"


class VectordbClientError(RuntimeError):
    """Raised when the D-Bus call fails or its output can't be parsed."""


@dataclass(frozen=True)
class VectordbClientConfig:
    service: str = "com.platform.internal_aiVectordb1"
    object_path: str = "/com/platform/internal_aiVectordb1"
    internal_gpio_path: str = "internal_gpio"
    call_timeout_seconds: float = 5.0


@dataclass(frozen=True)
class SearchResult:
    id: str
    metadata: dict
    original_data: str
    score: float


# 실기기에서 StartRequest 출력으로 확인된 패턴(dbus_internal_ai.py 참고) — AddText도
# 단일 문자열(return_id)을 돌려주므로 같은 포맷일 것으로 추정.
_SIMPLE_RESPONSE_RE = re.compile(r'Response:\s*"([^"]*)"')

# 실기기 미검증(모듈 docstring의 CAUTION 참고) -- aa{sv} 배열을 busctl류
# 텍스트 포맷으로 가정하고 짠 최선의 추정 정규식.
_SEARCH_RESULT_BLOCK_RE = re.compile(
    r'STRING\s+"(?P<id>[^"]*)".*?'
    r'STRING\s+"(?P<original>[^"]*)".*?'
    r"DOUBLE\s+(?P<score>-?\d+(?:\.\d+)?)",
    re.DOTALL,
)


def _format_metadata_arg(metadata: Mapping[str, str]) -> str:
    """CLI arg for AddText's ``metadata (a{sv})`` -- PDF example shows a
    JSON-ish list containing one dict, e.g. ``[{"stringSample": "..."}]``."""
    return json.dumps([dict(metadata)], ensure_ascii=False)


def parse_search_text_output(raw: str) -> list[SearchResult]:
    """Best-effort parse of SearchText's internal_gpio output -- see module
    docstring's CAUTION. Returns [] for no matches (empty DB or no hits),
    never raises for a well-formed-but-empty response."""
    return [
        SearchResult(id=m.group("id"), metadata={}, original_data=m.group("original"), score=float(m.group("score")))
        for m in _SEARCH_RESULT_BLOCK_RE.finditer(raw)
    ]


class VectordbClient:
    """Talks to com.platform.internal_aiVectordb1 via subprocess (internal_gpio call),
    same spirit as internal_gpioGpioClient/Dbusinternal_aiLlmClient. ``runner`` is
    injectable for testing."""

    def __init__(
        self,
        config: VectordbClientConfig | None = None,
        runner: Runner | None = None,
    ) -> None:
        self._cfg = config or VectordbClientConfig()
        self._run = runner or self._default_runner

    def create_db(
        self,
        db_name: str,
        data_type: str = "TEXT",
        vector_dimension: int = 768,
        similarity_metric: str = "COSINE",
    ) -> None:
        self._call(
            "CreateDB",
            "-S", "sa(sus)",
            db_name,
            f"[({data_type}, {vector_dimension}, {similarity_metric})]",
        )

    def add_text(self, input_text: str, metadata: Mapping[str, str]) -> str:
        output = self._call(
            "AddText", "-S", "sa{sv}", input_text, _format_metadata_arg(metadata)
        )
        match = _SIMPLE_RESPONSE_RE.search(output)
        if not match:
            raise VectordbClientError(
                f"could not parse return_id from AddText output: {output!r}"
            )
        return match.group(1)

    def search_text(self, input_text: str, top_k: int = 1) -> list[SearchResult]:
        output = self._call("SearchText", "-S", "su", input_text, str(top_k))
        return parse_search_text_output(output)

    def _call(self, method: str, *args: str) -> str:
        argv = [
            self._cfg.internal_gpio_path,
            "call",
            self._cfg.service,
            method,
            *args,
            "-o",
            self._cfg.object_path,
            "-s",
            self._cfg.service,
        ]
        try:
            result = self._run(argv)
        except FileNotFoundError as exc:
            raise VectordbClientError(f"{self._cfg.internal_gpio_path!r} not found") from exc
        except subprocess.TimeoutExpired as exc:
            raise VectordbClientError(f"{method} timed out") from exc

        if result.returncode != 0:
            raise VectordbClientError(f"{method} failed: {result.stderr.strip()}")
        return result.stdout

    def _default_runner(self, argv: list[str]) -> CompletedProcess:
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=self._cfg.call_timeout_seconds
        )


class VectordbSearcher(Protocol):
    """Structural type VectordbIntentResolver depends on -- satisfied by
    VectordbClient and by test doubles (see rpi/intent/mock.py)."""

    def search_text(self, input_text: str, top_k: int = 1) -> list[SearchResult]: ...


@dataclass(frozen=True)
class VectordbResolverConfig:
    similarity_threshold: float = 0.75
    # COSINE similarity: higher = more similar. Flip to False if the DB is
    # ever configured with a distance metric instead (lower = more similar) --
    # unconfirmed which convention this platform's `scores` field actually
    # uses (see module CAUTION).
    higher_score_is_better: bool = True


class VectordbIntentResolver(IntentResolver):
    """Resolves a purpose by similarity search against previously-seeded
    examples (see seed_examples()). Raises UnknownIntentError -- same as
    every other resolver -- when there's no DB hit, the best hit is below
    the similarity threshold, or its metadata doesn't carry a parseable
    button sequence, so it composes cleanly inside TieredIntentResolver.
    """

    def __init__(
        self,
        client: VectordbSearcher,
        config: VectordbResolverConfig | None = None,
    ) -> None:
        self._client = client
        self._cfg = config or VectordbResolverConfig()

    def resolve(self, purpose: str) -> tuple[str, ...]:
        normalized = purpose.strip()
        results = self._client.search_text(normalized, top_k=1)
        if not results:
            raise UnknownIntentError(f"no vector-db match for: {normalized}")

        best = results[0]
        if not self._passes_threshold(best.score):
            raise UnknownIntentError(
                f"best vector-db match for {normalized!r} below threshold "
                f"(score={best.score}, id={best.id})"
            )

        raw_buttons = best.metadata.get(_METADATA_BUTTONS_KEY)
        if not raw_buttons or not isinstance(raw_buttons, str):
            raise UnknownIntentError(
                f"vector-db match {best.id!r} has no usable {_METADATA_BUTTONS_KEY!r} metadata"
            )
        buttons = tuple(b.strip() for b in raw_buttons.split(",") if b.strip())
        if not buttons:
            raise UnknownIntentError(f"vector-db match {best.id!r} has an empty button sequence")
        return buttons

    def _passes_threshold(self, score: float) -> bool:
        if self._cfg.higher_score_is_better:
            return score >= self._cfg.similarity_threshold
        return score <= self._cfg.similarity_threshold


def seed_examples(
    client: VectordbClient, examples: Mapping[str, Sequence[str]]
) -> list[str]:
    """Explicit, caller-invoked one-time setup -- adds each purpose ->
    button-sequence example to the DB. Not called automatically by
    VectordbIntentResolver or wired into rpi/api/deps.py's singleton
    construction, since that would make real D-Bus calls at import time
    with no hardware guaranteed present.
    """
    ids = []
    for purpose, buttons in examples.items():
        metadata = {_METADATA_BUTTONS_KEY: ",".join(buttons)}
        ids.append(client.add_text(purpose.strip(), metadata))
    return ids
