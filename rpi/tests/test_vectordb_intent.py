"""VectordbClient + VectordbIntentResolver tests — no real D-Bus/hardware.

VectordbClient tests inject a fake subprocess runner (same pattern as
test_internal_gpio_gpio.py). VectordbIntentResolver tests use FakeVectordbClient
(rpi/intent/mock.py) so resolver logic is verified independently of the
CLI-parsing layer, which is explicitly flagged unverified against real
hardware (see rpi/intent/dbus_vectordb.py's module docstring).
"""

from __future__ import annotations

import subprocess

import pytest

from rpi.intent import (
    RuleBasedIntentResolver,
    SearchResult,
    TieredIntentResolver,
    UnknownIntentError,
    VectordbClient,
    VectordbClientError,
    VectordbIntentResolver,
    VectordbResolverConfig,
    parse_search_text_output,
    seed_examples,
)
from rpi.intent.mock import FakeVectordbClient


class FakeRunner:
    """Records internal_gpio invocations and returns scripted results."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self._scripted: dict[str, subprocess.CompletedProcess] = {}
        self._raise: dict[str, Exception] = {}

    def script(self, method: str, stdout: str, returncode: int = 0, stderr: str = "") -> None:
        self._scripted[method] = subprocess.CompletedProcess(
            args=[], returncode=returncode, stdout=stdout, stderr=stderr
        )

    def script_raise(self, method: str, exc: Exception) -> None:
        self._raise[method] = exc

    def __call__(self, argv: list[str]) -> subprocess.CompletedProcess:
        self.calls.append(argv)
        method = argv[3]  # [internal_gpio, call, <service>, <method>, ...]
        if method in self._raise:
            raise self._raise[method]
        if method in self._scripted:
            return self._scripted[method]
        return subprocess.CompletedProcess(args=argv, returncode=0, stdout="", stderr="")


def _make_client(runner: FakeRunner) -> VectordbClient:
    return VectordbClient(runner=runner)


# ═══════════════════════════════════════════════════════════════════════════════
# parse_search_text_output (pure function)
# ═══════════════════════════════════════════════════════════════════════════════

class TestParseSearchTextOutput:
    def test_empty_output_returns_empty_list(self):
        assert parse_search_text_output("") == []

    def test_single_result_parsed(self):
        raw = 'STRING "id-1";\nSTRING "우유 데워줘";\nDOUBLE 0.92;\n'
        results = parse_search_text_output(raw)
        assert results == [SearchResult(id="id-1", metadata={}, original_data="우유 데워줘", score=0.92)]

    def test_multiple_results_parsed_in_order(self):
        raw = (
            'STRING "id-1";\nSTRING "첫번째";\nDOUBLE 0.9;\n'
            'STRING "id-2";\nSTRING "두번째";\nDOUBLE 0.5;\n'
        )
        results = parse_search_text_output(raw)
        assert [r.id for r in results] == ["id-1", "id-2"]
        assert [r.score for r in results] == [0.9, 0.5]

    def test_garbage_output_returns_empty_list(self):
        assert parse_search_text_output("not a valid response at all") == []


# ═══════════════════════════════════════════════════════════════════════════════
# VectordbClient
# ═══════════════════════════════════════════════════════════════════════════════

class TestVectordbClientAddText:
    def test_parses_returned_id(self):
        runner = FakeRunner()
        runner.script("AddText", stdout='Response: "id-42"\n')
        client = _make_client(runner)

        result_id = client.add_text("우유 데워줘", {"buttons": "해동,시작"})

        assert result_id == "id-42"

    def test_sends_correct_argv(self):
        runner = FakeRunner()
        runner.script("AddText", stdout='Response: "id-1"\n')
        client = _make_client(runner)

        client.add_text("우유 데워줘", {"buttons": "해동,시작"})

        argv = runner.calls[0]
        assert argv[:4] == ["internal_gpio", "call", "com.platform.internal_aiVectordb1", "AddText"]
        assert "우유 데워줘" in argv
        assert "-o" in argv and "/com/platform/internal_aiVectordb1" in argv

    def test_unparseable_output_raises(self):
        runner = FakeRunner()
        runner.script("AddText", stdout="garbage, no Response: pattern here")
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="could not parse"):
            client.add_text("우유 데워줘", {"buttons": "해동"})

    def test_nonzero_returncode_raises(self):
        runner = FakeRunner()
        runner.script("AddText", stdout="", returncode=1, stderr="EmbeddingFailed")
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="EmbeddingFailed"):
            client.add_text("우유 데워줘", {"buttons": "해동"})

    def test_internal_gpio_not_found_raises(self):
        runner = FakeRunner()
        runner.script_raise("AddText", FileNotFoundError())
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="not found"):
            client.add_text("우유 데워줘", {"buttons": "해동"})

    def test_timeout_raises(self):
        runner = FakeRunner()
        runner.script_raise("AddText", subprocess.TimeoutExpired(cmd="internal_gpio", timeout=5.0))
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="timed out"):
            client.add_text("우유 데워줘", {"buttons": "해동"})


class TestVectordbClientSearchText:
    def test_parses_results(self):
        runner = FakeRunner()
        runner.script("SearchText", stdout='STRING "id-1";\nSTRING "우유 데워줘";\nDOUBLE 0.91;\n')
        client = _make_client(runner)

        results = client.search_text("우유 좀 데워줄래", top_k=1)

        assert len(results) == 1
        assert results[0].id == "id-1"
        assert results[0].score == pytest.approx(0.91)

    def test_no_matches_returns_empty_list(self):
        runner = FakeRunner()
        runner.script("SearchText", stdout="")
        client = _make_client(runner)

        assert client.search_text("아무 상관없는 말") == []

    def test_nonzero_returncode_raises(self):
        runner = FakeRunner()
        runner.script("SearchText", stdout="", returncode=1, stderr="DatabaseNotLoaded")
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="DatabaseNotLoaded"):
            client.search_text("우유 데워줘")


class TestVectordbClientCreateDb:
    def test_sends_correct_argv(self):
        runner = FakeRunner()
        client = _make_client(runner)

        client.create_db("simplelay")

        argv = runner.calls[0]
        assert argv[:4] == ["internal_gpio", "call", "com.platform.internal_aiVectordb1", "CreateDB"]
        assert "simplelay" in argv


# ═══════════════════════════════════════════════════════════════════════════════
# VectordbIntentResolver
# ═══════════════════════════════════════════════════════════════════════════════

def _result(id_: str, buttons: str | None, score: float) -> SearchResult:
    metadata = {"buttons": buttons} if buttons is not None else {}
    return SearchResult(id=id_, metadata=metadata, original_data="", score=score)


class TestVectordbIntentResolver:
    def test_good_match_returns_button_sequence(self):
        client = FakeVectordbClient({"우유 좀 데워줄래": [_result("id-1", "해동,시작", 0.9)]})
        resolver = VectordbIntentResolver(client)

        assert resolver.resolve("우유 좀 데워줄래") == ("해동", "시작")

    def test_no_results_raises_unknown_intent(self):
        client = FakeVectordbClient({})
        resolver = VectordbIntentResolver(client)

        with pytest.raises(UnknownIntentError):
            resolver.resolve("아무도 모르는 명령")

    def test_low_similarity_score_raises_unknown_intent(self):
        client = FakeVectordbClient({"애매한 명령": [_result("id-1", "해동", 0.4)]})
        resolver = VectordbIntentResolver(client, VectordbResolverConfig(similarity_threshold=0.75))

        with pytest.raises(UnknownIntentError, match="below threshold"):
            resolver.resolve("애매한 명령")

    def test_score_exactly_at_threshold_passes(self):
        client = FakeVectordbClient({"명령": [_result("id-1", "해동", 0.75)]})
        resolver = VectordbIntentResolver(client, VectordbResolverConfig(similarity_threshold=0.75))

        assert resolver.resolve("명령") == ("해동",)

    def test_missing_buttons_metadata_raises_unknown_intent(self):
        client = FakeVectordbClient({"명령": [_result("id-1", None, 0.95)]})
        resolver = VectordbIntentResolver(client)

        with pytest.raises(UnknownIntentError, match="no usable"):
            resolver.resolve("명령")

    def test_empty_buttons_metadata_raises_unknown_intent(self):
        client = FakeVectordbClient({"명령": [_result("id-1", "", 0.95)]})
        resolver = VectordbIntentResolver(client)

        with pytest.raises(UnknownIntentError):
            resolver.resolve("명령")

    def test_distance_metric_direction_lower_is_better(self):
        # 코사인 유사도가 아니라 거리 지표라면 낮을수록 더 비슷함
        client = FakeVectordbClient({"명령": [_result("id-1", "해동", 0.1)]})
        resolver = VectordbIntentResolver(
            client, VectordbResolverConfig(similarity_threshold=0.3, higher_score_is_better=False)
        )

        assert resolver.resolve("명령") == ("해동",)

    def test_distance_metric_direction_rejects_far_match(self):
        client = FakeVectordbClient({"명령": [_result("id-1", "해동", 0.9)]})
        resolver = VectordbIntentResolver(
            client, VectordbResolverConfig(similarity_threshold=0.3, higher_score_is_better=False)
        )

        with pytest.raises(UnknownIntentError):
            resolver.resolve("명령")

    def test_purpose_text_is_stripped_before_search(self):
        client = FakeVectordbClient({"우유 데워줘": [_result("id-1", "해동", 0.9)]})
        resolver = VectordbIntentResolver(client)

        resolver.resolve("  우유 데워줘  ")

        assert client.calls == [("우유 데워줘", 1)]

    def test_composes_as_a_tier_after_rule_based_resolver(self):
        # docs/inference-boundary.md 형태: 규칙기반이 먼저, 안 걸리면 벡터DB로
        rules = RuleBasedIntentResolver()
        client = FakeVectordbClient({"에어컨 좀 세게 틀어줘": [_result("id-1", "AC-01,AC-04", 0.88)]})
        vectordb = VectordbIntentResolver(client)
        resolver = TieredIntentResolver((rules, vectordb))

        # 규칙기반이 처리 -- 벡터DB는 호출도 안 됨
        assert resolver.resolve("우유 데워줘") == ("해동", "시간 90초", "시작")
        assert client.calls == []

        # 규칙에 없는 명령은 벡터DB로 넘어감
        assert resolver.resolve("에어컨 좀 세게 틀어줘") == ("AC-01", "AC-04")


# ═══════════════════════════════════════════════════════════════════════════════
# seed_examples
# ═══════════════════════════════════════════════════════════════════════════════

class TestSeedExamples:
    def test_adds_each_example_and_returns_ids_in_order(self):
        runner = FakeRunner()
        ids_by_call = iter(["id-1", "id-2"])

        def _script(argv):
            runner.calls.append(argv)
            return subprocess.CompletedProcess(
                args=argv, returncode=0, stdout=f'Response: "{next(ids_by_call)}"\n', stderr=""
            )

        client = VectordbClient(runner=_script)
        examples = {"우유 데워줘": ("해동", "시작"), "에어컨 켜줘": ("AC-01",)}

        result = seed_examples(client, examples)

        assert result == ["id-1", "id-2"]
        assert len(runner.calls) == 2

    def test_buttons_metadata_is_comma_joined(self):
        captured = {}

        def _script(argv):
            captured["argv"] = argv
            return subprocess.CompletedProcess(args=argv, returncode=0, stdout='Response: "id-1"\n', stderr="")

        client = VectordbClient(runner=_script)
        seed_examples(client, {"우유 데워줘": ("해동", "시간 90초", "시작")})

        assert any("해동,시간 90초,시작" in arg for arg in captured["argv"])
