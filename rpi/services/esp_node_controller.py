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

from rpi.controller import ExecutionMode, ExecutionResult

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

# 정지를 **생략해도 되는 유일한 경우**: 연결 자체가 성립하지 않은 예외들.
#
# 규칙을 이렇게 뒤집은 이유. 예전에는 "400/500은 실행이 시작되지 않았으니 정지가
# 불필요하다"고 판단했는데, 그건 노드 펌웨어가 지금 그렇게 짜여 있다는 것에 기댄
# 추론이다. 중간에 낀 프록시나 그 주소의 다른 기기가 답했다면, 혹은 펌웨어가 나중에
# 바뀌면 성립하지 않는다. 반면 연결이 못 이뤄졌다는 것은 우리 쪽에서 관측한 사실이고,
# 여기엔 자기충족적인 근거가 있다 -- **요청이 닿지 못했다면 정지도 닿지 못한다.**
# 죽은 노드에 정지를 쏘느라 실패마다 몇 초를 더 붙잡을 이유도 없다.
#
# 나머지는 전부 정지를 보낸다. 틀렸을 때의 대가가 비대칭이기 때문이다: 불필요한
# 정지는 유휴 RPi4가 무시하고 끝나지만(act_executor "abort received while idle"),
# 빠뜨린 정지는 화면이 실패라고 말하는 동안 실물이 계속 눌리는 상태로 남는다.
_UNDELIVERABLE = (
    httpx.ConnectError,      # TCP 연결 실패
    httpx.ConnectTimeout,    # 연결 수립 중 시간 초과
    httpx.PoolTimeout,       # 커넥션 풀에서 나가지도 못함
    httpx.UnsupportedProtocol,
    httpx.InvalidURL,        # HTTPError가 아니라 별도 계층이다
)


class EspNodeError(RuntimeError):
    """Raised when a node is unreachable or reports a non-2xx response."""


class EspNodeController:
    #: 전송이 원격이라는 사실은 **물리적으로 눌렸는지에 대해 아무것도**
    #: 말해주지 않는다 -- 저쪽 노드가 자기 안에서 mock을 돌리고 있을 수
    #: 있다. 노드가 자기 모드를 보고하게 되면(F1 readiness) 그 값으로
    #: 채운다. 그전까지는 모른다고 기록한다.
    execution_mode = ExecutionMode.UNKNOWN

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

        **포기할 때는 정지도 요청한다.** 고정 10초 타임아웃이던 시절에는 RPi5가
        실패로 보고한 뒤에도 노드와 RPi4가 최대 30초 동안 계속 버튼을 눌렀다 —
        화면은 '실패'인데 실물은 동작 중인 상태(교차 리뷰 치명).

        정지를 생략하는 경우는 ``_UNDELIVERABLE`` 하나뿐이다(그쪽 주석 참고).
        """
        buttons = list(buttons)
        timeout = self.timeout_for(len(buttons))
        try:
            response = self._client.post(
                f"{self._base_url}/execute",
                json={"buttons": buttons},
                timeout=timeout,
            )
        except _UNDELIVERABLE as exc:
            # 연결이 성립하지 않았다 → 실행이 시작됐을 리 없고, 시작됐더라도 같은
            # 이유로 정지 역시 닿지 못한다. 정지를 생략하는 유일한 갈래.
            raise EspNodeError(
                f"could not reach node at {self._base_url}: {exc}"
            ) from exc
        except httpx.TimeoutException as exc:
            # 요청은 나갔고 응답만 못 받았다 — 노드는 아직 실행 중일 수 있다
            self.request_stop()
            raise EspNodeError(
                f"node at {self._base_url} did not respond within "
                f"{timeout}s (stop requested): {exc}"
            ) from exc
        except httpx.HTTPError as exc:
            # 요청을 보낸 뒤 연결이 끊겼다(ReadError·RemoteProtocolError 등).
            # 예전에는 이 갈래가 정지를 보내지 않아, 시연장 Wi-Fi가 한 번 끊기면
            # 타임아웃과 **똑같은 상황인데도** 실물만 계속 눌리고 있었다.
            self.request_stop()
            raise EspNodeError(
                f"lost contact with node at {self._base_url} after the request "
                f"was sent (stop requested): {exc}"
            ) from exc

        if response.status_code != 200:
            # 200이 아닌 모든 응답에 정지를 보낸다 -- 어떤 상태 코드가 "실행 전에
            # 거절됐다"는 뜻인지는 노드 펌웨어의 사정이고, 그 가정이 틀렸을 때
            # 치르는 대가가 한쪽으로 크게 기울어 있다(_UNDELIVERABLE 주석 참고).
            self.request_stop()
            raise EspNodeError(
                f"node at {self._base_url} returned {response.status_code} "
                f"(stop requested): {response.text}"
            )

        # 200을 받았다면 노드는 실행을 끝내고 답한 것이다(펌웨어는 핸들러가 반환한
        # 뒤에만 200을 보낸다) → 본문이 이상해도 정지는 필요 없다.
        try:
            body = response.json()
        except ValueError as exc:
            raise EspNodeError(
                f"node at {self._base_url} returned 200 with a body that is not "
                f"JSON: {response.text!r}"
            ) from exc
        if not isinstance(body, dict):
            raise EspNodeError(
                f"node at {self._base_url} returned 200 with a non-object body: "
                f"{body!r}"
            )

        success = bool(body.get("success", False))
        retry = int(body.get("retry", 0))
        return synthesize_execution_result(buttons, success, retry)

    def request_stop(self) -> bool:
        """긴급 정지 — 노드의 STOP_PORT(HTTP 포트 + 1)에 정지를 요청한다.

        best-effort: 정지 경로에서 예외로 호출자(emergency_stop의 전체 노드
        브로드캐스트)를 죽이면 다른 노드의 정지까지 막는다 — 실패는 로그만.
        타임아웃도 짧게 잡는다: 죽은 노드 하나가 정지 경로를 오래 붙잡으면
        안 된다.

        반환값 True는 **노드가 정지 요청을 받았다고 2xx로 응답했다**는 뜻이다.
        모터가 실제로 멈췄다는 확인이 아니다. 전송 실패·오류 응답은 False라
        호출자가 미확인 노드로 드러낼 수 있다."""
        try:
            response = self._client.post(
                self._stop_url(), timeout=STOP_REQUEST_TIMEOUT_SECONDS
            )
        except httpx.HTTPError as exc:
            log.error("stop request to node %s failed: %s", self._base_url, exc)
            return False
        if not response.is_success:
            log.error(
                "stop request to node %s answered HTTP %s",
                self._base_url,
                response.status_code,
            )
            return False
        return True

    def _stop_url(self) -> str:
        parsed = urlparse(self._base_url)
        port = parsed.port if parsed.port is not None else 80
        netloc = f"{parsed.hostname}:{port + STOP_PORT_OFFSET}"
        return urlunparse(parsed._replace(netloc=netloc, path="/stop"))

    def close(self) -> None:
        if self._owns_client:
            self._client.close()
