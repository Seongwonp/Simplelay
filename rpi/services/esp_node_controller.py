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

import httpx

from rpi.controller import ExecutionResult

from .aggregate_result import synthesize_execution_result


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

    def close(self) -> None:
        if self._owns_client:
            self._client.close()
