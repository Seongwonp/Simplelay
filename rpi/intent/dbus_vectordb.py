"""On-device similarity search for intent resolution, via the device's
vector-DB D-Bus service. Meant to sit between RuleBasedIntentResolver
(exact match, zero risk) and an LLM-based resolver (flexible, slower) in a
TieredIntentResolver chain -- fast, offline "fuzzy" matching against a small
set of known purpose -> button-sequence examples, without a full
conversational round trip.

Calls go through the device's D-Bus CLI as a subprocess, the same pattern the
other on-device adapters use -- no Python D-Bus binding is available there yet.
Which CLI and which service to talk to are read from the environment
(rpi/dbus_env.py), not baked in.

CAUTION -- the exact text the CLI prints for AddText's metadata argument and
for SearchText's return value has still not been captured from a live device,
unlike the agent client's ``Response: "..."`` pattern, which WAS confirmed there.
``_format_metadata_arg`` and ``parse_search_text_output`` are written against
the interface's documented shape and are kept as small, independently
swappable pure functions so they're a quick fix once real output is captured.

What IS pinned down: a search result carries (id, metadata, originalData,
score) in that order, and the button sequence lives in metadata -- so the
parser must preserve metadata for VectordbIntentResolver to work at all.
"""

from __future__ import annotations

import json
import re
import subprocess
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from rpi import dbus_env

from .base import IntentResolver
from .rules import UnknownIntentError

CompletedProcess = subprocess.CompletedProcess[str]
Runner = Callable[[list[str]], CompletedProcess]

_METADATA_BUTTONS_KEY = "buttons"


class VectordbClientError(RuntimeError):
    """Raised when the D-Bus call fails or its output can't be parsed."""


@dataclass(frozen=True)
class VectordbClientConfig:
    """서비스 주소는 기기의 성질이라 환경에서 받는다 -- rpi/dbus_env.py 참고."""

    service: str
    object_path: str
    cli_path: str
    call_timeout_seconds: float = 5.0

    @classmethod
    def from_env(cls) -> "VectordbClientConfig":
        service = dbus_env.required(
            dbus_env.ENV_VECTORDB_SERVICE, "온디바이스 유사도 검색 서비스"
        )
        return cls(
            service=service,
            object_path=dbus_env.object_path_for(service),
            cli_path=dbus_env.required(dbus_env.ENV_DBUS_CLI, "D-Bus 호출 CLI"),
        )


@dataclass(frozen=True)
class SearchResult:
    id: str
    metadata: dict
    original_data: str
    score: float


# 실기기에서 StartRequest 출력으로 확인된 패턴(dbus_internal_ai.py 참고) — AddText도
# 단일 문자열(return_id)을 돌려주므로 같은 포맷일 것으로 추정.
_SIMPLE_RESPONSE_RE = re.compile(r'Response:\s*"([^"]*)"')

# 검색 결과 한 건의 필드 순서: id, metadata, originalData, score.
# metadata가 id와 originalData 사이에 오기 때문에, "id 다음의 첫 문자열이
# originalData"라고 보면 metadata 조각을 originalData로 잘못 집는다. 점수(실수)가
# 항상 결과 한 건의 마지막이라는 점을 이용해 블록으로 자른 뒤,
# 첫 문자열=id / 마지막 문자열=originalData / 그 사이=metadata 키·값 쌍으로 나눈다.
# metadata가 비어 있어도(문자열 2개) 같은 규칙이 그대로 성립한다.
_STRING_TOKEN_RE = re.compile(r'STRING\s+"((?:[^"\\]|\\.)*)"')
_SCORE_TOKEN_RE = re.compile(r"DOUBLE\s+(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)")


def _format_metadata_arg(metadata: Mapping[str, str]) -> str:
    """CLI arg for AddText's ``metadata`` map -- the documented example form is
    a JSON-ish list holding a single dict, e.g. ``[{"someKey": "someValue"}]``."""
    return json.dumps([dict(metadata)], ensure_ascii=False)


def parse_search_text_output(raw: str) -> list[SearchResult]:
    """Best-effort parse of SearchText's CLI output -- see module
    docstring's CAUTION. Returns [] for no matches (empty DB or no hits),
    never raises for a well-formed-but-empty response.

    metadata must survive this parse: VectordbIntentResolver reads the button
    sequence out of it, so dropping it here silently disables the whole
    vector-db tier (every lookup falls through to the next resolver).
    """
    results: list[SearchResult] = []
    cursor = 0
    for score_match in _SCORE_TOKEN_RE.finditer(raw):
        strings = _STRING_TOKEN_RE.findall(raw[cursor : score_match.start()])
        cursor = score_match.end()
        if not strings:
            continue
        # 홀수 개가 남으면(문자열이 아닌 값이 섞인 경우 등) 짝이 맞는 데까지만 취한다
        between = strings[1:-1]
        metadata = {
            between[i]: between[i + 1] for i in range(0, len(between) - 1, 2)
        }
        results.append(
            SearchResult(
                id=strings[0],
                metadata=metadata,
                original_data=strings[-1] if len(strings) > 1 else "",
                score=float(score_match.group(1)),
            )
        )
    return results


class VectordbClient:
    """Talks to the vector-DB service by shelling out to the device's D-Bus
    CLI, same spirit as the other on-device adapters. ``runner`` is injectable
    for testing; ``config`` defaults to reading the environment."""

    def __init__(
        self,
        config: VectordbClientConfig | None = None,
        runner: Runner | None = None,
    ) -> None:
        self._cfg = config or VectordbClientConfig.from_env()
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
            self._cfg.cli_path,
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
            raise VectordbClientError(f"{self._cfg.cli_path!r} not found") from exc
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
