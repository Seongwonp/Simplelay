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
from collections.abc import Callable, Mapping

from rpi.controller import ButtonTarget, ExecutionMode, ExecutionResult

from .act_client import ActClient, ActClientConfig, ActLinkTimeoutError, AlertEvent
from .aggregate_result import synthesize_from_act_result

log = logging.getLogger(__name__)


class ActClientController:
    #: execute()가 ``targets``(버튼별 좌표)를 받아 RPi4로 전달한다.
    supports_button_targets = True

    #: UART 너머 RPi4가 실제 모터를 돌리는지, 자기 안에서 mock을 돌리는지
    #: 이쪽에서는 알 수 없다. 'UART니까 real'은 추측이다 -- 실기기 통합
    #: 초기에는 실제로 저쪽이 mock인 기간이 있다.
    execution_mode = ExecutionMode.UNKNOWN

    """Dispatches whole button sequences to the real RPi4 board over UART
    instead of running a local closed loop.

    Precision note (docs/roadmap.md M2): RPi4 only reports an aggregate
    {success, retry, outcome?} for the sequence, not a per-button breakdown -- see
    aggregate_result.synthesize_from_act_result() for how that gets
    approximated into a full ExecutionResult.
    """

    # ActClient의 응답 대기보다 항상 이만큼 더 기다린다 — ActClient가 먼저
    # 깨어나 abort 전송·stale 기록까지 마친 뒤 예외가 이 스레드로 전파되게.
    CALL_MARGIN_SECONDS = 5.0

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        client: ActClient,
        call_timeout_seconds: float | None = None,
    ) -> None:
        """call_timeout_seconds=None(기본)이면 시퀀스 길이에 맞춰 동적으로
        기다린다(client.response_timeout_for + 여유). 고정값은 테스트처럼
        브리지 자체의 timeout 동작을 검증할 때만 쓴다 — 고정 35s는 긴
        시퀀스에서 ActClient보다 먼저 포기해 결과를 유실시켰다(교차 리뷰 #6)."""
        self._loop = loop
        self._client = client
        self._call_timeout = call_timeout_seconds

    def _timeout_for(self, button_count: int) -> float:
        if self._call_timeout is not None:
            return self._call_timeout
        return self._client.response_timeout_for(button_count) + self.CALL_MARGIN_SECONDS

    def execute(
        self,
        buttons: list[str] | tuple[str, ...],
        targets: "Mapping[str, ButtonTarget] | None" = None,
    ) -> ExecutionResult:
        buttons = list(buttons)
        call_timeout = self._timeout_for(len(buttons))
        coro = (
            self._client.execute(buttons, targets=targets)
            if targets
            else self._client.execute(buttons)
        )
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        try:
            result = future.result(timeout=call_timeout)
        except TimeoutError as exc:
            future.cancel()
            raise ActLinkTimeoutError(
                f"ActClientController.execute() timed out after {call_timeout}s"
            ) from exc

        # RPi4가 보고한 것(종료 방식·버튼별 시도·L3·실행 환경)을 그대로 싣는다 --
        # 없으면(옛 RPi4) 집계 값만으로 합성한다.
        return synthesize_from_act_result(buttons, result)

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

    def inject_failure(self, button_index: int, attempts: int) -> None:
        """리허설 실패 주입을 RPi4로 전달 — 단방향(응답 없음). 전송 완료는
        기다린다: 리허설 절차가 '무장 → 즉시 실행'이라 실행보다 먼저
        도착해야 의미가 있다."""
        asyncio.run_coroutine_threadsafe(
            self._client.inject_failure(button_index, attempts), self._loop
        ).result(timeout=5.0)

    def clear_failure(self) -> None:
        asyncio.run_coroutine_threadsafe(
            self._client.clear_failure(), self._loop
        ).result(timeout=5.0)

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

    config = ActClientConfig.from_env()  # 실기기 타이밍 캘리브레이션 반영

    async def _open() -> ActClient:
        reader, writer = await serial_asyncio.open_serial_connection(url=port, baudrate=baud)
        client = ActClient(reader, writer, config=config, on_alert=on_alert)
        await client.start()
        return client

    client = asyncio.run_coroutine_threadsafe(_open(), loop).result(timeout=10.0)
    log.info("ActClientController connected to RPi4 on %s @ %d baud", port, baud)
    return ActClientController(loop, client)
