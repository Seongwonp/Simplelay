"""HTTP-based ButtonSequenceController for one appliance's node (ESP32 next
to that appliance's RPi4 -- see long-term multi-node plan: RPi5 is one
central hub, an Act node is attached per appliance rather than co-located
with RPi5).

This is the dev-mode transport: RPi5 acts as the HTTP client and POSTs to a
small HTTP server the node runs, reusing the exact same request/response
style already used for the phone app. The production transport (ESP-NOW,
for demo-venue Wi-Fi independence) is a separate, not-yet-built
ButtonSequenceController -- swapping between them is meant to be a mode
selection, not a rewrite, so both need to keep satisfying this same
interface.

Unlike ActClientController (UART, needs a persistent connection and a
background event loop thread), plain HTTP request/response is inherently
one-shot, so this controller needs no background thread at all.
"""

from __future__ import annotations

import logging
from urllib.parse import urlparse, urlunparse

import httpx

from rpi.controller import ExecutionResult

from .aggregate_result import synthesize_execution_result

log = logging.getLogger(__name__)

# 노드 펌웨어의 긴급 정지 리스너는 항상 HTTP 포트 + 1 (firmware-node
# include/config.h의 STOP_PORT). 같은 포트를 못 쓰는 이유는 그쪽 주석 참고
# (단일 스레드 WebServer가 실행 블로킹 중 새 연결을 못 받음).
STOP_PORT_OFFSET = 1
STOP_REQUEST_TIMEOUT_SECONDS = 2.0


class EspNodeError(RuntimeError):
    """Raised when a node is unreachable or reports a non-2xx response."""


class EspNodeController:
    """Args:
    base_url: e.g. "http://192.168.1.42:8080" -- this node's address.
    client:   Injectable httpx.Client for testing (see httpx.MockTransport);
              production use leaves this as a real client.
    timeout:  Per-request timeout in seconds.
    """

    def __init__(
        self,
        base_url: str,
        client: httpx.Client | None = None,
        timeout: float = 10.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(timeout=timeout)
        self._owns_client = client is None

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult:
        buttons = list(buttons)
        try:
            response = self._client.post(
                f"{self._base_url}/execute", json={"buttons": buttons}
            )
        except httpx.HTTPError as exc:
            raise EspNodeError(
                f"could not reach node at {self._base_url}: {exc}"
            ) from exc

        if response.status_code != 200:
            raise EspNodeError(
                f"node at {self._base_url} returned {response.status_code}: "
                f"{response.text}"
            )

        body = response.json()
        success = bool(body.get("success", False))
        retry = int(body.get("retry", 0))
        return synthesize_execution_result(buttons, success, retry)

    def request_stop(self) -> None:
        """긴급 정지 — 노드의 STOP_PORT(HTTP 포트 + 1)에 정지를 요청한다.

        best-effort: 정지 경로에서 예외로 호출자(emergency_stop의 전체 노드
        브로드캐스트)를 죽이면 다른 노드의 정지까지 막는다 — 실패는 로그만.
        타임아웃도 짧게 잡는다: 죽은 노드 하나가 정지 경로를 오래 붙잡으면
        안 된다."""
        try:
            self._client.post(
                self._stop_url(), timeout=STOP_REQUEST_TIMEOUT_SECONDS
            )
        except httpx.HTTPError as exc:
            log.error("stop request to node %s failed: %s", self._base_url, exc)

    def _stop_url(self) -> str:
        parsed = urlparse(self._base_url)
        port = parsed.port if parsed.port is not None else 80
        netloc = f"{parsed.hostname}:{port + STOP_PORT_OFFSET}"
        return urlunparse(parsed._replace(netloc=netloc, path="/stop"))

    def close(self) -> None:
        if self._owns_client:
            self._client.close()
