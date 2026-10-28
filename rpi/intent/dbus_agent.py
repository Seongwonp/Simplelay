"""On-device LLM client that talks to the device's agent-orchestrator D-Bus
service -- an alternative to HttpLlmClient for when no cloud/HTTP endpoint
is configured (or explicitly preferred, see rpi/api/deps.py).

The orchestrator's request/response cycle is asynchronous: ``StartRequest``
returns a request_id immediately, and the actual answer streams back as
``ResponseSentence`` signals (one per sentence chunk, ordered by
sequence_number, terminated by the completed state code). The device's own
D-Bus CLI has no signal-subscribe mode, so the one-shot call goes through it
while the signal stream is read from a separately-launched ``busctl monitor``
process -- the general systemd D-Bus tool, confirmed present on the device and
able to see the same bus.

Which CLI and which service to talk to come from the environment
(rpi/dbus_env.py), not from constants baked into this file.
"""

import logging
import re
import subprocess
import threading
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass

from rpi import dbus_env

from .ports import LlmClient

_log = logging.getLogger(__name__)

# ResponseSentence의 state_code. 1(tooling)은 도구 호출 진행 알림이라 답변 본문이
# 아니다 -- 이어붙이면 우리가 요구한 JSON 응답이 오염된다.
_STATE_ERROR = 0
_STATE_TOOLING = 1
_STATE_COMPLETED = 3

CompletedProcess = subprocess.CompletedProcess[str]
Runner = Callable[[list[str]], CompletedProcess]


class DbusAgentClientError(RuntimeError):
    """Raised when the D-Bus call, signal wait, or parsing fails."""


@dataclass(frozen=True)
class DbusAgentClientConfig:
    """서비스 주소는 기기의 성질이라 환경에서 받는다 -- rpi/dbus_env.py 참고."""

    service: str
    object_path: str
    cli_path: str
    user_id: str = "simplelay"
    # 시그널 구독은 systemd 범용 도구를 쓴다 -- 기기 전용 CLI가 아니다
    busctl_path: str = "busctl"
    call_timeout_seconds: float = 5.0
    response_timeout_seconds: float = 20.0

    @classmethod
    def from_env(cls, **overrides: object) -> "DbusAgentClientConfig":
        service = dbus_env.required(
            dbus_env.ENV_AGENT_SERVICE, "온디바이스 대화형 에이전트 서비스"
        )
        return cls(
            service=service,
            object_path=dbus_env.object_path_for(service),
            cli_path=dbus_env.required(dbus_env.ENV_DBUS_CLI, "D-Bus 호출 CLI"),
            **overrides,  # type: ignore[arg-type]
        )


_PROMPT_TEMPLATE = (
    "You translate a home-appliance voice command into a button-press "
    'sequence. Respond with JSON only, in the exact shape '
    '{{"sequence": ["<button label>", ...]}}. Use only button labels from '
    "this list, in the order they must be pressed: {buttons}. If the "
    "command does not match any reasonable sequence, respond with "
    '{{"sequence": []}}. Command: {purpose}'
)

_REQUEST_ID_RE = re.compile(r'Response:\s*"([^"]+)"')

# One ResponseSentence signal block, as printed by `busctl monitor`:
#   Member=ResponseSentence
#   MESSAGE "susi" {
#           STRING "<request_id>";
#           UINT32 <sequence_number>;
#           STRING "<sentence>";
#           INT32 <state_code>;
#   };
_SIGNAL_BLOCK_RE = re.compile(
    r"Member=ResponseSentence\b.*?"
    r'STRING\s+"(?P<request_id>[^"]*)";\s*'
    r"UINT32\s+(?P<seq>\d+);\s*"
    r'STRING\s+"(?P<sentence>.*?)";\s*'
    r"INT32\s+(?P<state>-?\d+);",
    re.DOTALL,
)


def parse_response_sentences(
    monitor_text: str, request_id: str
) -> list[tuple[int, int, str]]:
    """Pure parse: pull (state_code, sequence_number, sentence) tuples for
    one request_id out of raw `busctl monitor` output. Ignores blocks for
    other request_ids (the monitor sees all of the service's traffic, not
    just ours)."""
    return [
        (int(m.group("state")), int(m.group("seq")), m.group("sentence"))
        for m in _SIGNAL_BLOCK_RE.finditer(monitor_text)
        if m.group("request_id") == request_id
    ]


def _assemble_response(entries: Iterable[tuple[int, int, str]]) -> str | None:
    """Combine sentence chunks in sequence order once state_code=3 (completed)
    has been seen. Returns None if not yet complete. Raises on state_code=0
    (error) -- the agent's own error text becomes the exception message.

    Tooling chunks are progress notices about the agent's own tool calls, not
    answer text, so they're skipped -- concatenating them corrupts the
    JSON-only response this client asks for.
    """
    by_seq: dict[int, str] = {}
    completed = False
    for state, seq, sentence in entries:
        if state == _STATE_ERROR:
            raise DbusAgentClientError(f"agent reported an error: {sentence}")
        if state == _STATE_COMPLETED:
            completed = True
        elif state == _STATE_TOOLING:
            continue
        by_seq[seq] = sentence
    if not completed:
        return None
    return "".join(by_seq[i] for i in sorted(by_seq))


class DbusAgentLlmClient(LlmClient):
    """Talks to the agent-orchestrator service by shelling out to the device's
    D-Bus CLI (one-shot calls) plus ``busctl monitor`` (signal stream).
    ``runner`` and ``monitor_launcher`` are injectable for testing; ``config``
    defaults to reading the environment.
    """

    def __init__(
        self,
        config: DbusAgentClientConfig | None = None,
        runner: Runner | None = None,
        monitor_launcher: Callable[[], "subprocess.Popen[str]"] | None = None,
    ) -> None:
        self._config = config or DbusAgentClientConfig.from_env()
        self._run = runner or self._default_runner
        self._launch_monitor = monitor_launcher or self._default_monitor_launcher

    def complete(self, purpose: str, known_buttons: tuple[str, ...]) -> str:
        query = _PROMPT_TEMPLATE.format(buttons=list(known_buttons), purpose=purpose)

        monitor = self._launch_monitor()
        try:
            # Give the monitor a moment to attach its match rule before we
            # fire the request -- otherwise the first signal can race ahead
            # of the subscription and never be seen.
            time.sleep(0.3)
            request_id = self._start_request(query)
            try:
                return self._collect_response(monitor, request_id)
            except DbusAgentClientError:
                # 응답 대기를 중단해도 에이전트 처리는 계속되므로 중단 요청을 보낸다.
                # ESP 노드 경로와 동일하게 호출 측 실패 후 원격 작업이 계속되는 것을 막는다.
                self._stop_request(request_id)
                raise
        finally:
            monitor.terminate()
            try:
                monitor.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                monitor.kill()

    def _start_request(self, query: str) -> str:
        cfg = self._config
        argv = [
            cfg.cli_path,
            "call",
            cfg.service,
            "StartRequest",
            cfg.user_id,
            query,
            "false",
            "-o",
            cfg.object_path,
            "-s",
            cfg.service,
        ]
        try:
            result = self._run(argv)
        except FileNotFoundError as exc:
            raise DbusAgentClientError(f"{cfg.cli_path!r} not found") from exc
        except subprocess.TimeoutExpired as exc:
            raise DbusAgentClientError("StartRequest timed out") from exc

        if result.returncode != 0:
            raise DbusAgentClientError(f"StartRequest failed: {result.stderr.strip()}")
        match = _REQUEST_ID_RE.search(result.stdout)
        if not match:
            raise DbusAgentClientError(
                f"could not parse request_id from StartRequest output: {result.stdout!r}"
            )
        return match.group(1)

    def _stop_request(self, request_id: str) -> None:
        """Best-effort cancel of an in-flight request. Never raises -- it runs
        on the failure path and must not mask the error that triggered it."""
        cfg = self._config
        argv = [
            cfg.cli_path,
            "call",
            cfg.service,
            "StopRequest",
            request_id,
            "-o",
            cfg.object_path,
            "-s",
            cfg.service,
        ]
        try:
            self._run(argv)
        except Exception:  # noqa: BLE001 -- 취소 실패가 원래 오류를 가리면 안 된다
            _log.warning("could not cancel request %s", request_id, exc_info=True)

    def _collect_response(
        self, monitor: "subprocess.Popen[str]", request_id: str
    ) -> str:
        assert monitor.stdout is not None
        timed_out = threading.Event()
        timer = threading.Timer(
            self._config.response_timeout_seconds, timed_out.set
        )
        timer.start()
        try:
            buffer = ""
            for line in monitor.stdout:
                if timed_out.is_set():
                    break
                buffer += line
                entries = parse_response_sentences(buffer, request_id)
                response = _assemble_response(entries)
                if response is not None:
                    return response
        finally:
            timer.cancel()

        raise DbusAgentClientError(
            f"no completed response for request {request_id} within "
            f"{self._config.response_timeout_seconds}s"
        )

    def _default_runner(self, argv: list[str]) -> CompletedProcess:
        return subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=self._config.call_timeout_seconds,
        )

    def _default_monitor_launcher(self) -> "subprocess.Popen[str]":
        cfg = self._config
        return subprocess.Popen(
            [cfg.busctl_path, "monitor", cfg.service],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
