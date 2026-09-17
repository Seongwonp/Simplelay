"""유사도 계층 시드 -- 규칙에서 예시를 뽑아 벡터DB에 채우는 경로.

시드가 없으면 이 계층은 항상 미스라 계속 다음 단계로 넘어간다(계층이 노는 상태).
여기서는 D-Bus 없이 가짜 러너로 클라이언트를 만들어 호출 내용을 확인한다.
"""

from __future__ import annotations

import subprocess

import pytest

from rpi.intent.dbus_vectordb import VectordbClient, VectordbClientConfig
from rpi.intent.rules import RuleBasedIntentResolver
from rpi.intent.vectordb_seed import DEFAULT_DB_NAME, examples_from_rules, seed_vectordb

_TEST_CONFIG = VectordbClientConfig(
    service="com.example.TestVectordb1",
    object_path="/com/example/TestVectordb1",
    cli_path="fake-dbus-cli",
)


class FakeRunner:
    """호출을 기록하고, 지정한 메서드만 실패시킬 수 있는 가짜 CLI."""

    def __init__(self, fail_methods: set[str] | None = None) -> None:
        self.calls: list[list[str]] = []
        self._fail = fail_methods or set()

    def __call__(self, argv: list[str]) -> subprocess.CompletedProcess:
        self.calls.append(argv)
        method = argv[3]
        if method in self._fail:
            return subprocess.CompletedProcess(argv, returncode=1, stdout="", stderr=f"{method} failed")
        return subprocess.CompletedProcess(
            argv, returncode=0, stdout=f'Response: "id-{len(self.calls)}"\n', stderr=""
        )

    def methods(self) -> list[str]:
        return [argv[3] for argv in self.calls]


def _client(runner: FakeRunner) -> VectordbClient:
    return VectordbClient(config=_TEST_CONFIG, runner=runner)


class TestExamplesFromRules:
    def test_includes_every_rule_and_alias(self):
        examples = examples_from_rules()
        assert len(examples) == (
            len(RuleBasedIntentResolver.DEFAULT_RULES)
            + len(RuleBasedIntentResolver.DEFAULT_ALIASES)
        )

    def test_alias_inherits_canonical_button_sequence(self):
        rules = {"즉석밥 데워줘": ("해동", "시작")}
        aliases = {"즉석밥 좀 데워줘": "즉석밥 데워줘"}

        examples = examples_from_rules(rules, aliases)

        assert examples["즉석밥 좀 데워줘"] == ("해동", "시작")

    def test_keeps_original_wording_not_normalized_keys(self):
        # 규칙은 공백을 지운 키로 매칭하지만, 임베딩은 사람이 쓰는 문장이어야 한다
        examples = examples_from_rules()
        assert any(" " in phrase for phrase in examples)

    def test_alias_without_canonical_rule_is_skipped(self):
        # 시드 때문에 서버가 못 뜨는 것이 더 나쁘다 -- 조용히 건너뛴다
        examples = examples_from_rules({"있는 규칙": ("A",)}, {"떠도는 별칭": "없는 규칙"})

        assert "떠도는 별칭" not in examples
        assert examples == {"있는 규칙": ("A",)}


class TestSeedVectordb:
    def test_creates_db_before_adding(self):
        runner = FakeRunner()

        seed_vectordb(_client(runner), {"명령": ("버튼",)})

        assert runner.methods()[0] == "CreateDB"
        assert DEFAULT_DB_NAME in runner.calls[0]

    def test_adds_one_entry_per_example(self):
        runner = FakeRunner()

        count = seed_vectordb(_client(runner), {"명령1": ("A",), "명령2": ("B",)})

        assert count == 2
        assert runner.methods().count("AddText") == 2

    def test_buttons_go_into_metadata_comma_joined(self):
        # 리졸버가 metadata에서 버튼 시퀀스를 읽으므로 여기 형식이 맞아야 한다
        runner = FakeRunner()

        seed_vectordb(_client(runner), {"명령": ("해동", "시작")})

        add_argv = next(a for a in runner.calls if a[3] == "AddText")
        assert any("해동,시작" in arg for arg in add_argv)

    def test_continues_when_db_already_exists(self):
        # 이미 있는 DB에 CreateDB를 부르면 어떻게 되는지 실기기 미확인 --
        # 실패해도 "이미 있는 것"으로 보고 시드를 계속한다
        runner = FakeRunner(fail_methods={"CreateDB"})

        count = seed_vectordb(_client(runner), {"명령": ("버튼",)})

        assert count == 1
        assert runner.methods().count("AddText") == 1

    def test_add_failure_propagates(self):
        # DB 생성 실패는 삼키지만 실제 시드 실패까지 삼키면 조용히 빈 DB가 된다
        from rpi.intent.dbus_vectordb import VectordbClientError

        runner = FakeRunner(fail_methods={"AddText"})

        with pytest.raises(VectordbClientError):
            seed_vectordb(_client(runner), {"명령": ("버튼",)})

    def test_defaults_to_rule_derived_examples(self):
        runner = FakeRunner()

        count = seed_vectordb(_client(runner))

        assert count == len(examples_from_rules())
