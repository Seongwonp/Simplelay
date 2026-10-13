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
import concurrent.futures
import contextlib
import logging
import threading
from collections.abc import Callable, Mapping

from rpi.controller import ButtonTarget, ExecutionMode, ExecutionResult

from .act_client import ActClient, ActClientConfig, ActLinkError, ActLinkTimeoutError, AlertEvent
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
        #: 다음 execute에 실을 정지 대기 계획(``arm_stop_hold``). 한 번 쓰면 비운다.
        self._next_hold: dict | None = None
        #: 다음 execute의 대상 가전(``arm_execute_target``). 한 번 쓰면 비운다. 없으면 보내지 않는다.
        self._next_target: str | None = None

    @property
    def frame_tap(self):
        """RPi5↔RPi4 프레임 탭(rpi/services/link_tap.py). 실모드 트윈이 읽는다. 없으면 None."""
        return getattr(self._client, "tap", None)

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
        hold, self._next_hold = self._next_hold, None
        target, self._next_target = self._next_target, None
        if target is None:
            # RPi4는 대상 없는 execute를 거절한다(평가 H3) — 전자레인지로 가정해 보내지 않는다.
            raise ActLinkError("execute target (appliance_id) was not armed — not sent to RPi4")
        if hold:
            coro = self._client.execute(buttons, targets=targets or None, hold=hold, appliance_id=target)
        elif targets:
            coro = self._client.execute(buttons, targets=targets, appliance_id=target)
        else:
            coro = self._client.execute(buttons, appliance_id=target)
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
        """긴급 정지 — RPi4에 abort를 보낸다. **기다리지 않는다**: 진행 중이던 execute()는 RPi4 쪽 중단
        결과(error/result)로 스스로 마무리된다. 전송 실패는 로그만 남긴다 — 정지 경로에서 예외로
        호출자를 죽이는 것보다 물리 E-STOP이 최종 권한이라는 설계를 따른다.

        2026-10-13: abort에 ``stop_id``를 실어 RPi4의 정지 확인 보고를 받는다(`wait_stop_report`가 따로 기다린다)."""

        def _log_send_failure(future: "concurrent.futures.Future[dict]") -> None:
            exc = future.exception()
            if exc is not None:
                log.error("emergency abort send failed: %s", exc)

        with_report = getattr(self._client, "abort_with_report", None)
        coro = with_report() if callable(with_report) else self._client.abort()
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        future.add_done_callback(_log_send_failure)
        self._stop_future = future if callable(with_report) else None

    _stop_future: "concurrent.futures.Future[dict] | None" = None

    def wait_stop_report(self, timeout_s: float | None = None) -> dict | None:
        """마지막 `request_stop`의 확인 단계 ``{"stop_level", "ack_ms", "target", …}``를 기다린다(블로킹, 짧은 기한).

        정지를 보내지 않았으면 None. 보내지 못했으면 ``stop_level: None``과 이유. 기한이 지나면 ``sent``."""
        future = self._stop_future
        if future is None:
            return None
        wait = (getattr(self._client, "STOP_REPORT_TIMEOUT_S", 1.5) + 0.5) if timeout_s is None else timeout_s
        try:
            return dict(future.result(timeout=wait))
        except concurrent.futures.TimeoutError:
            return {"stop_level": "sent", "ack_ms": None, "target": None,
                    "stop_detail": "RPi4의 정지 확인 보고를 기다리다 기한이 지났어요"}
        except Exception as exc:  # noqa: BLE001 - 보내지 못함(링크 끊김 등)
            return {"stop_level": None, "ack_ms": None, "target": None,
                    "stop_detail": f"RPi4에 정지를 보내지 못했어요: {exc}"}

    # ── 정지 대기·확인 주행(2026-09-30) ─────────────────────────────────────

    #: 서비스가 이 표시를 보고 실행 직전에 ``arm_stop_hold``를 부른다.
    supports_stop_hold = True

    def arm_execute_target(self, appliance_id: str) -> None:
        """다음 execute 한 번의 대상 가전(2026-10-07, 평가 H3). 서비스가 실행마다 부른다."""
        self._next_target = appliance_id

    def arm_stop_hold(self, plan: "Mapping[str, object] | None") -> None:
        """다음 execute 한 번에 정지 대기 계획을 싣는다(None이면 싣지 않음)."""
        self._next_hold = dict(plan) if plan else None

    def hold_status(self) -> dict | None:
        """RPi4가 보낸 마지막 정지 대기 보고(없으면 None). 판정은 RPi4가 한다."""
        doc = getattr(self._client, "last_hold", None)
        return dict(doc) if doc else None

    #: 걸림 상태를 다시 물을 최소 간격(초). '확인 중'인 동안 실행 시도마다 hello를 보내지 않게.
    HELLO_RETRY_SECONDS = 2.0
    _last_hello = 0.0

    def estop_status(self) -> dict | None:
        """RPi4가 보고한 비상정지 걸림 ``{"latched": bool|None, "detail", "known", "trips"}``(2026-10-05).

        ``known=False``(RPi5가 다시 켜진 뒤 아직 답을 못 받음)는 '풀림'이 아니라 '확인 중'이다 — 서비스가 실행을
        거절하고, 여기서 hello를 다시 보낸다(2026-10-06 평가 C1)."""
        latched = getattr(self._client, "estop_latched", None)
        if latched is None:
            self._maybe_hello()
        return {"latched": latched, "detail": getattr(self._client, "estop_detail", None),
                "known": latched is not None, "trips": getattr(self._client, "estop_trips", None),
                # 링크가 끊긴 동안 known=False(확인 중)다 — 다시 이은 뒤 RPi4 답으로만 다시 안다.
                "link_up": getattr(self._client, "link_up", True)}

    def link_status(self) -> dict:
        """RPi4 링크 ``{"link_up": bool, "ever_connected": bool, "reason": str|None}``(2026-10-06 인계 §6)."""
        return {"link_up": bool(getattr(self._client, "link_up", True)),
                "ever_connected": bool(getattr(self._client, "ever_connected", True)),
                "reason": getattr(self._client, "link_down_reason", None)}

    def _maybe_hello(self) -> None:
        import time  # noqa: PLC0415

        now = time.monotonic()
        if now - self._last_hello < self.HELLO_RETRY_SECONDS or not hasattr(self._client, "hello"):
            return
        self._last_hello = now
        try:
            asyncio.run_coroutine_threadsafe(self._client.hello(), self._loop)
        except RuntimeError:
            log.warning("hello not sent — act client loop closed")

    # ── UART 리허설(2026-10-06) ─────────────────────────────────────────────
    # RPi4가 가짜 콘센트(또는 없음)·모의 모션으로 돌 때만 RPi4가 받는다. RPi5는 SIMPLELAY_UART_REHEARSAL=1일 때만 연다.

    def rehearsal_status(self) -> dict:
        """RPi4가 ``act_info``로 알린 구성(리허설 가능 여부 ``rehearsal``·``outlet``·``motion``)."""
        return dict(getattr(self._client, "act_info", {}) or {})

    def _rehearse(self, action: str, **fields) -> dict:
        future = asyncio.run_coroutine_threadsafe(self._client.rehearsal(action, **fields), self._loop)
        try:
            reply = future.result(timeout=5.0 + self.CALL_MARGIN_SECONDS)
        except TimeoutError as exc:
            future.cancel()
            raise ActLinkTimeoutError("rehearsal timed out") from exc
        if reply.get("ok") is not True:
            raise RuntimeError(str(reply.get("detail") or reply.get("reason") or "RPi4가 리허설 주입을 거절했어요"))
        return reply

    def uart_rehearse_outlet_estop(self, hold_button: bool = False) -> None:
        self._rehearse("outlet_estop", hold_button=bool(hold_button))

    def uart_release_rehearsal_estop_button(self) -> None:
        self._rehearse("outlet_estop_release")

    def uart_rehearse_appliance_done(self, appliance_id: str, inputs, event: str | None = None) -> dict:
        fields: dict = {"appliance_id": appliance_id, "inputs": list(inputs)}
        if event is not None:
            fields["event"] = event
        frame = self._rehearse("appliance_done", **fields).get("frame")
        if not isinstance(frame, dict):
            raise RuntimeError("RPi4가 주입한 완료 프레임을 돌려주지 않았어요")
        return frame

    def acknowledge_estop(self, timeout_s: float = 10.0) -> dict:
        """사람의 비상정지 해제 확인을 RPi4로 보내고 ``estop_state``를 기다린다(블로킹)."""
        future = asyncio.run_coroutine_threadsafe(self._client.estop_ack(timeout_s), self._loop)
        try:
            return future.result(timeout=timeout_s + self.CALL_MARGIN_SECONDS)
        except TimeoutError as exc:
            future.cancel()
            raise ActLinkTimeoutError("estop_ack timed out") from exc

    # ── 개발자 조작(2026-10-10) ─────────────────────────────────────────────

    def dev_motion_link(self) -> dict:
        """개발자 실물 어댑터가 보는 링크 한 장 ``{"link_up", "link_reason", "act_info", "estop_latched"}`` — 읽기만."""
        return {"link_up": bool(getattr(self._client, "link_up", True)),
                "link_reason": getattr(self._client, "link_down_reason", None),
                "act_info": dict(getattr(self._client, "act_info", {}) or {}),
                "estop_latched": getattr(self._client, "estop_latched", None)}

    def dev_motion(self, op: str, timeout_s: float, **fields: object) -> dict:
        """개발자 조작 한 번을 RPi4로 보내고 답을 기다린다(블로킹). 재전송 없음."""
        future = asyncio.run_coroutine_threadsafe(self._client.dev_motion(op, timeout_s, **fields), self._loop)
        try:
            return future.result(timeout=timeout_s + self.CALL_MARGIN_SECONDS)
        except TimeoutError as exc:
            future.cancel()
            raise ActLinkTimeoutError(f"dev_motion {op} timed out") from exc

    def request_drive_stop(self) -> None:
        """구동부만 멈춘다(정지 버튼을 누르지 않음) — 가전 정지와 다른 경로."""
        asyncio.run_coroutine_threadsafe(self._client.abort("drive"), self._loop)

    def verify_pass(self, targets: list[dict], on_progress=None) -> dict:
        """확인 주행을 RPi4로 보내고 결과를 기다린다(블로킹). ``on_progress``는 단계 보고."""
        listener = None
        if on_progress is not None:
            def listener(doc: dict) -> None:
                if doc.get("phase") == "verify":
                    on_progress(doc)
            self._loop.call_soon_threadsafe(self._client.add_progress_listener, listener)
        try:
            future = asyncio.run_coroutine_threadsafe(self._client.verify_pass(targets), self._loop)
            return future.result(timeout=self._client.response_timeout_for(len(targets))
                                 + self.CALL_MARGIN_SECONDS)
        finally:
            if listener is not None:
                self._loop.call_soon_threadsafe(self._client.remove_progress_listener, listener)

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


#: (idle s, interval s, count) — 무선(2026-10-12): 사라진 RPi4를 약 11 s 안에 알아채 다시 잇는다. RPi4 socat과 같은 값.
TCP_KEEPALIVE = (5, 2, 3)


def enable_tcp_keepalive(writer: object) -> bool:
    """``socket://`` 링크면 밑의 TCP 소켓에 keepalive를 켠다(시리얼 장치면 아무것도 안 하고 False).

    Wi-Fi가 끊기거나 RPi4가 꺼지면 FIN 없이 연결이 반쯤 남아 읽기가 영원히 기다린다. keepalive가
    죽은 상대를 알아채면 읽기가 오류로 끝나고 기존 재연결 경로(_read_loop → _reconnect)를 탄다."""
    import socket  # noqa: PLC0415

    sock = getattr(getattr(getattr(writer, "transport", None), "serial", None), "_socket", None)
    if not isinstance(sock, socket.socket):
        return False
    idle, interval, count = TCP_KEEPALIVE
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    for name, value in (("TCP_KEEPIDLE", idle), ("TCP_KEEPINTVL", interval), ("TCP_KEEPCNT", count)):
        opt = getattr(socket, name, None)
        if opt is not None:
            with contextlib.suppress(OSError):
                sock.setsockopt(socket.IPPROTO_TCP, opt, value)
    return True


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
    on_appliance_done: Callable[[dict], None] | None = None,
    on_act_info: Callable[[dict], None] | None = None,
) -> ActClientController:
    """Production factory -- opens the real serial port to RPi4 and starts
    the background loop + ActClient, with a connector that reopens the same
    port when the link drops (socket:// and /dev/tty* alike). The first
    connection is made in the background with the same backoff, so a
    missing RPi4 does not fail backend startup (link stays down until then). Requires
    pyserial-asyncio and a real device; the reconnect wiring is covered with a
    fake serial_asyncio in test_act_client_reconnect.py."""
    import serial_asyncio  # type: ignore[import-untyped]

    from .link_auth import link_key_from_env

    # 짝 키(2026-10-12 무선 링크 인증). 짧으면 LinkKeyError로 링크를 열지 않는다. 없으면 경고 한 번(인증 없음).
    link_key = link_key_from_env()
    loop, _thread = start_background_loop()

    config = ActClientConfig.from_env()  # 실기기 타이밍 캘리브레이션 반영
    from .link_tap import get_link_tap

    tap = get_link_tap()  # 모든 프레임을 링 버퍼(+ SIMPLELAY_SESSION_LOG_PATH면 JSONL)에 남긴다
    tap.transport = tap.transport or "uart"

    async def _connect():
        reader, writer = await serial_asyncio.open_serial_connection(url=port, baudrate=baud)
        if enable_tcp_keepalive(writer):
            log.info("ActClient: TCP keepalive on (idle %ds, every %ds × %d)", *TCP_KEEPALIVE)
        return reader, writer

    async def _open() -> ActClient:
        # 첫 연결도 배경에서 한다(2026-10-06 인계 §6) — RPi4 실행기가 꺼져 있어도 백엔드는 뜨고, 잇기 전에는
        # 링크 끊김(실행 거절·걸림 상태 모름)이다. 끊기면(RPi4 실행기 재시작·socket 끊김·USB 뽑힘) 같은 포트를
        # 다시 열고 hello로 걸림 상태를 다시 받는다. socket://·/dev/tty* 공통(2026-10-06 교차 리뷰 HIGH).
        client = ActClient(None, None, config=config, on_alert=on_alert, tap=tap,
                           on_appliance_done=on_appliance_done, on_act_info=on_act_info,
                           hello=True, connector=_connect, link_key=link_key)
        await client.start()
        return client

    client = asyncio.run_coroutine_threadsafe(_open(), loop).result(timeout=10.0)
    log.info("ActClientController connecting to RPi4 on %s @ %d baud (background, retries until up, link auth %s)",
             port, baud, "on" if link_key is not None else "OFF")
    return ActClientController(loop, client)
