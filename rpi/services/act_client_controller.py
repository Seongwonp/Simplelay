"""Synchronous bridge so SimpleLayService (and other sync call sites) can
drive the async ActClient without becoming async themselves.

``ActClientController`` owns no IO of its own -- it takes an already-started
``ActClient`` plus the event loop it's bound to, and exposes execute()/close()
as plain blocking calls that hop onto that loop via
``asyncio.run_coroutine_threadsafe``. This makes it a drop-in replacement
anywhere a ``ClosedLoopController`` is used today (same ``execute(buttons) ->
ExecutionResult`` shape), since both ``rpi/api/service.py`` and
``rpi4/services/bridge.py`` currently call that method synchronously.

See ``open_uart_act_controller()`` for the production factory that actually
opens a serial port and starts the background loop thread -- that part
needs real RPi4 hardware and isn't covered by unit tests, mirroring
rpi4/act_main.py's untested ``_run()``.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from collections.abc import Callable

from rpi.controller import ExecutionResult

from .act_client import ActClient, ActLinkTimeoutError, AlertEvent
from .aggregate_result import synthesize_execution_result

log = logging.getLogger(__name__)


class ActClientController:
    """Dispatches whole button sequences to the real RPi4 board over UART
    instead of running a local closed loop.

    Precision note (docs/roadmap.md M2): RPi4 only reports an aggregate
    {success, retry} for the sequence, not a per-button breakdown -- see
    aggregate_result.synthesize_execution_result() for how that gets
    approximated into a full ExecutionResult.
    """

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        client: ActClient,
        call_timeout_seconds: float = 35.0,
    ) -> None:
        self._loop = loop
        self._client = client
        self._call_timeout = call_timeout_seconds

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult:
        buttons = list(buttons)
        future = asyncio.run_coroutine_threadsafe(self._client.execute(buttons), self._loop)
        try:
            result = future.result(timeout=self._call_timeout)
        except TimeoutError as exc:
            future.cancel()
            raise ActLinkTimeoutError(
                f"ActClientController.execute() timed out after {self._call_timeout}s"
            ) from exc

        return synthesize_execution_result(buttons, result.success, result.retry)

    def request_stop(self) -> None:
        """긴급 정지 — RPi4에 abort를 보낸다. fire-and-forget(프로토콜상 abort는
        응답이 없음): 진행 중이던 execute()는 RPi4 쪽 중단 결과(error/result)로
        스스로 마무리된다. 전송 실패는 로그만 남긴다 — 정지 경로에서 예외로
        호출자를 죽이는 것보다 물리 E-STOP이 최종 권한이라는 설계를 따른다."""

        def _log_send_failure(future: "asyncio.Future[None]") -> None:
            exc = future.exception()
            if exc is not None:
                log.error("emergency abort send failed: %s", exc)

        future = asyncio.run_coroutine_threadsafe(self._client.abort(), self._loop)
        future.add_done_callback(_log_send_failure)

    def close(self) -> None:
        asyncio.run_coroutine_threadsafe(self._client.stop(), self._loop).result(timeout=5.0)


def start_background_loop() -> tuple[asyncio.AbstractEventLoop, threading.Thread]:
    """Start a dedicated event loop on its own thread -- ActClient needs a
    running asyncio loop, but SimpleLayService's call sites are synchronous."""
    loop = asyncio.new_event_loop()
    thread = threading.Thread(target=loop.run_forever, daemon=True, name="act-client-loop")
    thread.start()
    return loop, thread


def open_uart_act_controller(
    port: str,
    baud: int,
    on_alert: Callable[[AlertEvent], None] | None = None,
) -> ActClientController:
    """Production factory -- opens the real serial port to RPi4 and starts
    the background loop + ActClient. Requires pyserial-asyncio and a real
    device; not exercised by unit tests."""
    import serial_asyncio  # type: ignore[import-untyped]

    loop, _thread = start_background_loop()

    async def _open() -> ActClient:
        reader, writer = await serial_asyncio.open_serial_connection(url=port, baudrate=baud)
        client = ActClient(reader, writer, on_alert=on_alert)
        await client.start()
        return client

    client = asyncio.run_coroutine_threadsafe(_open(), loop).result(timeout=10.0)
    log.info("ActClientController connected to RPi4 on %s @ %d baud", port, baud)
    return ActClientController(loop, client)
