"""VectordbClient + VectordbIntentResolver tests — no real D-Bus/hardware.

VectordbClient tests inject a fake subprocess runner (same pattern as
the GPIO adapter's tests). VectordbIntentResolver tests use FakeVectordbClient
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
from rpi.intent.dbus_vectordb import VectordbClientConfig
from rpi.intent.mock import FakeVectordbClient

# 서비스 주소는 환경에서 오지만, 테스트는 가짜 주소를 명시적으로 준다
_TEST_CONFIG = VectordbClientConfig(
    service="com.example.TestVectordb1",
    object_path="/com/example/TestVectordb1",
    cli_path="fake-dbus-cli",
)


class FakeRunner:
    """Records CLI invocations and returns scripted results."""

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
        method = argv[3]  # [cli, call, <service>, <method>, ...]
        if method in self._raise:
            raise self._raise[method]
        if method in self._scripted:
            return self._scripted[method]
        return subprocess.CompletedProcess(args=argv, returncode=0, stdout="", stderr="")


def _make_client(runner: FakeRunner) -> VectordbClient:
    return VectordbClient(config=_TEST_CONFIG, runner=runner)


# ═══════════════════════════════════════════════════════════════════════════════
# parse_search_text_output (pure function)
# ═══════════════════════════════════════════════════════════════════════════════

class TestParseSearchTextOutput:
    def test_empty_output_returns_empty_list(self):
        assert parse_search_text_output("") == []

    def test_single_result_parsed(self):
        raw = 'STRING "id-1";\nSTRING "즉석밥 데워줘";\nDOUBLE 0.92;\n'
        results = parse_search_text_output(raw)
        assert results == [SearchResult(id="id-1", metadata={}, original_data="즉석밥 데워줘", score=0.92)]

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

    def test_metadata_is_preserved(self):
        # 결과 한 건은 id, metadata, originalData, score 순. metadata를 버리면
        # 리졸버가 버튼 시퀀스를 못 읽어 벡터DB 계층 전체가 무력화된다.
        raw = (
            'STRING "id-1";\n'
            'STRING "buttons";\n'
            'STRING "해동,시작";\n'
            'STRING "즉석밥 데워줘";\n'
            "DOUBLE 0.92;\n"
        )
        assert parse_search_text_output(raw) == [
            SearchResult(
                id="id-1",
                metadata={"buttons": "해동,시작"},
                original_data="즉석밥 데워줘",
                score=0.92,
            )
        ]

    def test_metadata_is_not_mistaken_for_original_data(self):
        # metadata가 id와 originalData 사이에 있어서, "id 다음 첫 문자열"을
        # originalData로 잡으면 metadata 조각이 들어온다.
        raw = (
            'STRING "id-1";\nSTRING "buttons";\nSTRING "해동";\n'
            'STRING "진짜 원본";\nDOUBLE 0.9;\n'
        )
        assert parse_search_text_output(raw)[0].original_data == "진짜 원본"

    def test_multiple_results_with_metadata_do_not_bleed(self):
        raw = (
            'STRING "id-1";\nSTRING "buttons";\nSTRING "해동";\n'
            'STRING "첫번째";\nDOUBLE 0.9;\n'
            'STRING "id-2";\nSTRING "buttons";\nSTRING "시작";\n'
            'STRING "두번째";\nDOUBLE 0.5;\n'
        )
        results = parse_search_text_output(raw)
        assert [r.metadata for r in results] == [
            {"buttons": "해동"},
            {"buttons": "시작"},
        ]
        assert [r.original_data for r in results] == ["첫번째", "두번째"]


# ═══════════════════════════════════════════════════════════════════════════════
# VectordbClient
# ═══════════════════════════════════════════════════════════════════════════════

class TestVectordbClientAddText:
    def test_parses_returned_id(self):
        runner = FakeRunner()
        runner.script("AddText", stdout='Response: "id-42"\n')
        client = _make_client(runner)

        result_id = client.add_text("즉석밥 데워줘", {"buttons": "해동,시작"})

        assert result_id == "id-42"

    def test_sends_correct_argv(self):
        runner = FakeRunner()
        runner.script("AddText", stdout='Response: "id-1"\n')
        client = _make_client(runner)

        client.add_text("즉석밥 데워줘", {"buttons": "해동,시작"})

        argv = runner.calls[0]
        assert argv[:4] == ["fake-dbus-cli", "call", "com.example.TestVectordb1", "AddText"]
        assert "즉석밥 데워줘" in argv
        assert "-o" in argv and "/com/example/TestVectordb1" in argv

    def test_unparseable_output_raises(self):
        runner = FakeRunner()
        runner.script("AddText", stdout="garbage, no Response: pattern here")
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="could not parse"):
            client.add_text("즉석밥 데워줘", {"buttons": "해동"})

    def test_nonzero_returncode_raises(self):
        runner = FakeRunner()
        runner.script("AddText", stdout="", returncode=1, stderr="EmbeddingFailed")
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="EmbeddingFailed"):
            client.add_text("즉석밥 데워줘", {"buttons": "해동"})

    def test_missing_cli_binary_raises(self):
        runner = FakeRunner()
        runner.script_raise("AddText", FileNotFoundError())
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="not found"):
            client.add_text("즉석밥 데워줘", {"buttons": "해동"})

    def test_timeout_raises(self):
        runner = FakeRunner()
        runner.script_raise("AddText", subprocess.TimeoutExpired(cmd="fake-dbus-cli", timeout=5.0))
        client = _make_client(runner)

        with pytest.raises(VectordbClientError, match="timed out"):
            client.add_text("즉석밥 데워줘", {"buttons": "해동"})


class TestVectordbClientSearchText:
    def test_parses_results(self):
        runner = FakeRunner()
        runner.script("SearchText", stdout='STRING "id-1";\nSTRING "즉석밥 데워줘";\nDOUBLE 0.91;\n')
        client = _make_client(runner)

        results = client.search_text("즉석밥 좀 데워줄래", top_k=1)

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
            client.search_text("즉석밥 데워줘")


class TestVectordbClientCreateDb:
    def test_sends_correct_argv(self):
        runner = FakeRunner()
        client = _make_client(runner)

        client.create_db("simplelay")

        argv = runner.calls[0]
        assert argv[:4] == ["fake-dbus-cli", "call", "com.example.TestVectordb1", "CreateDB"]
        assert "simplelay" in argv


# ═══════════════════════════════════════════════════════════════════════════════
# VectordbIntentResolver
# ═══════════════════════════════════════════════════════════════════════════════

def _result(id_: str, buttons: str | None, score: float) -> SearchResult:
    metadata = {"buttons": buttons} if buttons is not None else {}
    return SearchResult(id=id_, metadata=metadata, original_data="", score=score)


class TestVectordbIntentResolver:
    def test_good_match_returns_button_sequence(self):
        client = FakeVectordbClient({"즉석밥 좀 데워줄래": [_result("id-1", "해동,시작", 0.9)]})
        resolver = VectordbIntentResolver(client)

        assert resolver.resolve("즉석밥 좀 데워줄래") == ("해동", "시작")

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
        client = FakeVectordbClient({"즉석밥 데워줘": [_result("id-1", "해동", 0.9)]})
        resolver = VectordbIntentResolver(client)

        resolver.resolve("  즉석밥 데워줘  ")

        assert client.calls == [("즉석밥 데워줘", 1)]

    def test_composes_as_a_tier_after_rule_based_resolver(self):
        # docs/inference-boundary.md 형태: 규칙기반이 먼저, 안 걸리면 벡터DB로
        rules = RuleBasedIntentResolver()
        client = FakeVectordbClient({"에어컨 좀 세게 틀어줘": [_result("id-1", "AC-01,AC-04", 0.88)]})
        vectordb = VectordbIntentResolver(client)
        resolver = TieredIntentResolver((rules, vectordb))

        # 규칙기반이 처리 -- 벡터DB는 호출도 안 됨
        assert resolver.resolve("즉석밥 데워줘") == ("즉석밥", "시작")
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

        client = VectordbClient(config=_TEST_CONFIG, runner=_script)
        examples = {"즉석밥 데워줘": ("해동", "시작"), "에어컨 켜줘": ("AC-01",)}

        result = seed_examples(client, examples)

        assert result == ["id-1", "id-2"]
        assert len(runner.calls) == 2

    def test_buttons_metadata_is_comma_joined(self):
        captured = {}

        def _script(argv):
            captured["argv"] = argv
            return subprocess.CompletedProcess(args=argv, returncode=0, stdout='Response: "id-1"\n', stderr="")

        client = VectordbClient(config=_TEST_CONFIG, runner=_script)
        seed_examples(client, {"즉석밥 데워줘": ("즉석밥", "시작")})

        assert any("즉석밥,시작" in arg for arg in captured["argv"])


# ═══════════════════════════════════════════════════════════════════════════════
# 파서 ↔ 리졸버 이음매
# ═══════════════════════════════════════════════════════════════════════════════

class TestParserResolverSeam:
    """CLI 출력 → 파서 → 리졸버를 한 번에 통과시킨다.

    파서는 가짜 원문으로, 리졸버는 손으로 만든 SearchResult로 따로만 검증하면
    "파서가 버리는 필드를 리졸버가 요구한다"는 어긋남을 어느 쪽 테스트도 잡지
    못한다. 실제로 그 구멍으로 벡터DB 계층이 항상 폴스루하고 있었다.
    """

    @staticmethod
    def _resolver_reading(raw: str) -> VectordbIntentResolver:
        runner = FakeRunner()
        runner.script("SearchText", stdout=raw)
        return VectordbIntentResolver(
            VectordbClient(config=_TEST_CONFIG, runner=runner)
        )

    def test_search_output_resolves_to_button_sequence(self):
        raw = (
            'STRING "id-1";\n'
            'STRING "buttons";\n'
            'STRING "해동,시작";\n'
            'STRING "즉석밥 데워줘";\n'
            "DOUBLE 0.92;\n"
        )
        assert self._resolver_reading(raw).resolve("즉석밥 좀 데워줄래") == ("해동", "시작")

    def test_low_score_output_falls_through(self):
        raw = (
            'STRING "id-1";\nSTRING "buttons";\nSTRING "해동";\n'
            'STRING "즉석밥 데워줘";\nDOUBLE 0.10;\n'
        )
        with pytest.raises(UnknownIntentError, match="below threshold"):
            self._resolver_reading(raw).resolve("전혀 다른 명령")

    def test_output_without_metadata_falls_through(self):
        raw = 'STRING "id-1";\nSTRING "즉석밥 데워줘";\nDOUBLE 0.92;\n'
        with pytest.raises(UnknownIntentError, match="no usable"):
            self._resolver_reading(raw).resolve("즉석밥 좀 데워줄래")

    def test_empty_output_falls_through(self):
        with pytest.raises(UnknownIntentError):
            self._resolver_reading("").resolve("아무 명령")

    def test_tier_chain_falls_back_to_rules_when_vectordb_misses(self):
        # 벡터DB가 못 잡아도 규칙 계층이 받아야 한다 -- 계층 구성의 핵심 계약
        vectordb = self._resolver_reading("")
        tiered = TieredIntentResolver([vectordb, RuleBasedIntentResolver()])

        assert tiered.resolve("즉석밥 데워줘")
