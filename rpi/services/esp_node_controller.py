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

# 실행 응답 대기 — UART 경로(ActClientConfig)와 같은 산정식이어야 한다.
# 두 경로가 다른 시간에 포기하면 "한쪽은 실패로 보고, 다른 쪽은 계속 실행"이
# 된다. 노드 펌웨어의 대기 시간은 항상 이보다 짧게(먼저 504 회신) 잡는다.
EXECUTE_BASE_TIMEOUT_SECONDS = 30.0
EXECUTE_PER_BUTTON_SECONDS = 6.0


class EspNodeError(RuntimeError):
    """Raised when a node is unreachable or reports a non-2xx response."""


class EspNodeController:
    """Args:
    base_url: e.g. "http://192.168.1.42:8080" -- this node's address.
    client:   Injectable httpx.Client for testing (see httpx.MockTransport);
              production use leaves this as a real client.
    timeout:  Fallback per-request timeout (연결·정지 등 짧은 요청용).
              실행 요청은 버튼 수에 비례한 값을 따로 계산해 쓴다.
    """

    def __init__(
        self,
        base_url: str,
        client: httpx.Client | None = None,
        timeout: float = 10.0,
        base_timeout_seconds: float = EXECUTE_BASE_TIMEOUT_SECONDS,
        per_button_timeout_seconds: float = EXECUTE_PER_BUTTON_SECONDS,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(timeout=timeout)
        self._owns_client = client is None
        self._base_timeout = base_timeout_seconds
        self._per_button_timeout = per_button_timeout_seconds

    def timeout_for(self, button_count: int) -> float:
        return self._base_timeout + self._per_button_timeout * max(0, button_count)

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult:
        """버튼 시퀀스를 노드에 넘기고 완료를 기다린다.

        포기할 때는 반드시 정지도 요청한다. 고정 10초 타임아웃이던 시절에는
        RPi5가 실패로 보고한 뒤에도 노드와 RPi4가 최대 30초 동안 계속 버튼을
        눌렀다 — 화면은 '실패'인데 실물은 동작 중인 상태(교차 리뷰 치명).
        """
        buttons = list(buttons)
        try:
            response = self._client.post(
                f"{self._base_url}/execute",
                json={"buttons": buttons},
                timeout=self.timeout_for(len(buttons)),
            )
        except httpx.TimeoutException as exc:
            # 응답만 못 받았을 뿐, 노드는 아직 실행 중일 수 있다 → 정지 요청
            self.request_stop()
            raise EspNodeError(
                f"node at {self._base_url} did not respond within "
                f"{self.timeout_for(len(buttons))}s (stop requested): {exc}"
            ) from exc
        except httpx.HTTPError as exc:
            raise EspNodeError(
                f"could not reach node at {self._base_url}: {exc}"
            ) from exc

        if response.status_code != 200:
            # 504 = 노드가 RPi4 응답을 못 받고 포기한 것 — RPi4는 여전히
            # 누르고 있을 수 있다. 400/500(요청·핸들러 오류)은 실행 자체가
            # 시작되지 않았으므로 정지가 불필요하다.
            if response.status_code == 504:
                self.request_stop()
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
