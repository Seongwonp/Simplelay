"""Tests for the on-device agent-orchestrator LLM client.

The parser tests use real ``busctl monitor`` output captured from an actual
device during manual verification -- see the ResponseSentence block shape
this asserts against.
"""

import subprocess

import pytest

from rpi.intent.dbus_agent import (
    DbusAgentClientConfig,
    DbusAgentClientError,
    DbusAgentLlmClient,
    parse_response_sentences,
)

# Captured verbatim from `busctl monitor com.example.TestAgent1`
# while a real StartRequest was in flight (request failed content-wise --
# "issue processing" -- but the signal mechanics are exactly what we rely on).
REAL_DEVICE_MONITOR_OUTPUT = """\
> Type=signal  Endian=l  Flags=0  Version=1  Cookie=29  Timestamp="Thu 2026-07-23 05:49:44.136152 UTC"
  Sender=:1.85  Path=/com/example/TestAgent1  Interface=com.example.TestAgent1  Member=ResponseSentence
  UniqueName=:1.85
  MESSAGE "susi" {
          STRING "a8a8671d-2db3-4ce5-9343-f7b26a514185";
          UINT32 0;
          STRING "There was an issue processing your request. Please try again.";
          INT32 2;
  };

> Type=signal  Endian=l  Flags=0  Version=1  Cookie=30  Timestamp="Thu 2026-07-23 05:49:44.136698 UTC"
  Sender=:1.85  Path=/com/example/TestAgent1  Interface=com.example.TestAgent1  Member=ResponseSentence
  UniqueName=:1.85
  MESSAGE "susi" {
          STRING "a8a8671d-2db3-4ce5-9343-f7b26a514185";
          UINT32 1;
          STRING "";
          INT32 3;
  };
"""

REAL_REQUEST_ID = "a8a8671d-2db3-4ce5-9343-f7b26a514185"


# ── parse_response_sentences (pure, against real captured device output) ──


def test_parses_real_device_signal_blocks():
    entries = parse_response_sentences(REAL_DEVICE_MONITOR_OUTPUT, REAL_REQUEST_ID)

    assert entries == [
        (2, 0, "There was an issue processing your request. Please try again."),
        (3, 1, ""),
    ]


def test_ignores_blocks_for_other_request_ids():
    entries = parse_response_sentences(REAL_DEVICE_MONITOR_OUTPUT, "some-other-id")

    assert entries == []


def test_returns_empty_for_text_with_no_signal_blocks():
    assert parse_response_sentences("some unrelated bus traffic\n", "any-id") == []


# ── DbusAgentLlmClient (subprocess I/O, fakes injected) ────────────────────


# 서비스 주소는 환경에서 오지만, 테스트는 가짜 주소를 명시적으로 준다
_FAKE_SERVICE = "com.example.TestAgent1"
_FAKE_CLI = "fake-dbus-cli"


def _config(**overrides) -> DbusAgentClientConfig:
    return DbusAgentClientConfig(
        service=_FAKE_SERVICE,
        object_path="/com/example/TestAgent1",
        cli_path=_FAKE_CLI,
        **overrides,
    )


class FakeMonitorProcess:
    """Stands in for the subprocess.Popen returned by busctl monitor."""

    def __init__(self, lines: list[str]) -> None:
        self.stdout = iter(lines)
        self.terminate_called = False
        self.wait_called = False

    def terminate(self) -> None:
        self.terminate_called = True

    def wait(self, timeout: float | None = None) -> None:
        self.wait_called = True

    def kill(self) -> None:
        pass


def _fake_runner(request_id: str) -> "subprocess.CompletedProcess[str]":
    def runner(argv: list[str]) -> "subprocess.CompletedProcess[str]":
        return subprocess.CompletedProcess(
            argv, returncode=0, stdout=f'Response: "{request_id}"\n', stderr=""
        )

    return runner


def _success_lines(request_id: str) -> list[str]:
    # 두 조각으로 나뉘어 오는 걸 순서대로 이어붙이는지 확인 — 임베디드 큰따옴표
    # 이스케이프 방식이 실기기에서 검증 안 됐으니, 그 부분은 건드리지 않는
    # 평문 조각으로 구성한다(JSON 파싱 자체는 LlmIntentResolver 쪽에서 이미
    # 별도로 테스트됨 -- 여기선 순서대로 잘 이어붙이는지만 본다).
    return [
        line + "\n"
        for line in (
            "> Type=signal Member=ResponseSentence",
            f'  STRING "{request_id}";',
            "  UINT32 0;",
            '  STRING "sequence is ";',
            "  INT32 2;",
            "};",
            "",
            "> Type=signal Member=ResponseSentence",
            f'  STRING "{request_id}";',
            "  UINT32 1;",
            '  STRING "해동 then 시작";',
            "  INT32 3;",
            "};",
            "",
        )
    ]


def test_complete_assembles_sentences_in_order():
    request_id = "req-success-1"
    client = DbusAgentLlmClient(
        config=_config(),
        runner=_fake_runner(request_id),
        monitor_launcher=lambda: FakeMonitorProcess(_success_lines(request_id)),
    )

    result = client.complete("해동해줘", ("해동", "시작"))

    assert result == "sequence is 해동 then 시작"


def test_complete_terminates_the_monitor_process():
    request_id = "req-cleanup-1"
    monitor = FakeMonitorProcess(_success_lines(request_id))
    client = DbusAgentLlmClient(
        config=_config(),
        runner=_fake_runner(request_id),
        monitor_launcher=lambda: monitor,
    )

    client.complete("해동해줘", ("해동", "시작"))

    assert monitor.terminate_called
    assert monitor.wait_called


def test_complete_returns_agent_text_even_when_it_could_not_help():
    # 실기기 캡처: 에이전트가 요청을 이해 못 했을 때도 state_code=2(말하는 중)로
    # 자연어 사과문을 보내고 state_code=3(완료)으로 끝난다 -- state_code=0(에러)이
    # 아니다. 즉 이건 클라이언트 레벨 에러가 아니라 "정상 완료, 다만 JSON이 아닌
    # 내용"인 경우 -- 그 판별은 LlmIntentResolver의 JSON 파싱 단계 몫이다.
    client = DbusAgentLlmClient(
        config=_config(),
        runner=_fake_runner(REAL_REQUEST_ID),
        monitor_launcher=lambda: FakeMonitorProcess(
            REAL_DEVICE_MONITOR_OUTPUT.splitlines(keepends=True)
        ),
    )

    result = client.complete("아무 명령", ("버튼",))

    assert result == "There was an issue processing your request. Please try again."


def test_complete_raises_on_protocol_level_error_state():
    # state_code=0 -- 문서상 명시된 프로토콜 레벨 에러(실기기에서 아직 재현은
    # 못 봤지만, 스펙에 있는 값이라 방어적으로 처리).
    request_id = "req-protocol-error"
    lines = [
        line + "\n"
        for line in (
            "> Type=signal Member=ResponseSentence",
            f'  STRING "{request_id}";',
            "  UINT32 0;",
            '  STRING "internal failure";',
            "  INT32 0;",
            "};",
            "",
        )
    ]
    client = DbusAgentLlmClient(
        config=_config(),
        runner=_fake_runner(request_id),
        monitor_launcher=lambda: FakeMonitorProcess(lines),
    )

    with pytest.raises(DbusAgentClientError, match="agent reported an error"):
        client.complete("아무 명령", ("버튼",))


def test_complete_raises_when_request_id_not_found_in_start_request_output():
    def runner(argv: list[str]) -> "subprocess.CompletedProcess[str]":
        return subprocess.CompletedProcess(argv, returncode=0, stdout="garbage", stderr="")

    client = DbusAgentLlmClient(
        config=_config(),
        runner=runner, monitor_launcher=lambda: FakeMonitorProcess([])
    )

    with pytest.raises(DbusAgentClientError, match="could not parse request_id"):
        client.complete("아무 명령", ("버튼",))


def test_complete_raises_when_start_request_fails():
    def runner(argv: list[str]) -> "subprocess.CompletedProcess[str]":
        return subprocess.CompletedProcess(
            argv, returncode=1, stdout="", stderr="boom"
        )

    client = DbusAgentLlmClient(
        config=_config(),
        runner=runner, monitor_launcher=lambda: FakeMonitorProcess([])
    )

    with pytest.raises(DbusAgentClientError, match="StartRequest failed"):
        client.complete("아무 명령", ("버튼",))


def test_complete_times_out_if_never_completed():
    request_id = "req-never-completes"
    config = _config(response_timeout_seconds=0.2)
    client = DbusAgentLlmClient(
        config=config,
        runner=_fake_runner(request_id),
        monitor_launcher=lambda: FakeMonitorProcess(iter([])),
    )

    with pytest.raises(DbusAgentClientError, match="no completed response"):
        client.complete("아무 명령", ("버튼",))


def _lines_with_tooling(request_id: str) -> list[str]:
    """tooling(1) 청크가 섞인 스트림 — 도구 호출 진행 알림이지 답변 본문이 아니다."""
    return [
        line + "\n"
        for line in (
            "> Type=signal Member=ResponseSentence",
            f'  STRING "{request_id}";',
            "  UINT32 0;",
            '  STRING "도구를 호출하는 중...";',
            "  INT32 1;",
            "};",
            "",
            "> Type=signal Member=ResponseSentence",
            f'  STRING "{request_id}";',
            "  UINT32 1;",
            '  STRING "진짜 답변";',
            "  INT32 3;",
            "};",
            "",
        )
    ]


def test_complete_skips_tooling_chunks():
    # tooling 텍스트가 섞이면 우리가 요구한 JSON 응답이 오염된다
    request_id = "req-tooling-1"
    client = DbusAgentLlmClient(
        config=_config(),
        runner=_fake_runner(request_id),
        monitor_launcher=lambda: FakeMonitorProcess(_lines_with_tooling(request_id)),
    )

    assert client.complete("명령", ("버튼",)) == "진짜 답변"


def test_complete_cancels_the_request_when_it_gives_up():
    # 우리가 포기해도 에이전트는 계속 처리한다 — 반드시 중단을 알려야 한다
    request_id = "req-abandoned-1"
    calls: list[list[str]] = []

    def runner(argv: list[str]) -> "subprocess.CompletedProcess[str]":
        calls.append(argv)
        return subprocess.CompletedProcess(
            argv, returncode=0, stdout=f'Response: "{request_id}"\n', stderr=""
        )

    client = DbusAgentLlmClient(
        config=_config(response_timeout_seconds=0.2),
        runner=runner,
        monitor_launcher=lambda: FakeMonitorProcess([]),
    )

    with pytest.raises(DbusAgentClientError, match="no completed response"):
        client.complete("아무 명령", ("버튼",))

    stop_calls = [argv for argv in calls if argv[3] == "StopRequest"]
    assert len(stop_calls) == 1
    assert request_id in stop_calls[0]


def test_cancel_failure_does_not_mask_the_original_error():
    request_id = "req-cancel-fails"

    def runner(argv: list[str]) -> "subprocess.CompletedProcess[str]":
        if argv[3] == "StopRequest":
            raise OSError("bus unavailable")
        return subprocess.CompletedProcess(
            argv, returncode=0, stdout=f'Response: "{request_id}"\n', stderr=""
        )

    client = DbusAgentLlmClient(
        config=_config(response_timeout_seconds=0.2),
        runner=runner,
        monitor_launcher=lambda: FakeMonitorProcess([]),
    )

    # 취소 실패가 원래 타임아웃 오류를 덮어쓰면 안 된다
    with pytest.raises(DbusAgentClientError, match="no completed response"):
        client.complete("아무 명령", ("버튼",))
