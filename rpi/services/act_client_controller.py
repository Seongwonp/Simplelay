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
import uuid
from collections.abc import Callable, Mapping

from rpi.controller import ButtonTarget, ExecutionMode, ExecutionResult
from rpi.controller.models import refused_before_press, stopped_before_dispatch

from .act_client import (
    ActClient,
    ActClientConfig,
    ActExecuteRefused,
    ActLinkError,
    ActLinkTimeoutError,
    AlertEvent,
)
from .aggregate_result import synthesize_from_act_result
from .link_heartbeat import LINK_LOST_ABORT_REASON

log = logging.getLogger(__name__)


class ActClientController:
    #: execute()가 ``targets``(버튼별 좌표)를 받아 RPi4로 전달한다.
    supports_button_targets = True
    supports_button_behaviors = True

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
        #: 이번 실행의 표지(``run_ref``, 2026-10-15 G2) — abort와 execute 양쪽에 실어 RPi4가 '실행 시작 전에 온 abort'를
        #: 그 실행에 묶게 한다(docs/protocol.md). ``reset_stop``(실행 시작)마다 새로 정한다. 실행을 시작한 적 없으면 None.
        self._run_ref: str | None = None
        #: 정지가 요청된 실행의 표지(2026-10-15 G2). ``request_stop``이 세우고, execute가 이벤트 루프 안에서 줄을 쓰기
        #: 직전에 자기 표지와 대조한다. 표지에 묶으므로 쉬는 중 정지가 다음 실행(새 표지)을 막지 않고, 실행 시작을
        #: 거치지 않는 호출(표지 None — 서비스 밖의 직접 호출)은 종전 그대로다.
        self._stopped_run_ref: str | None = None

    def reset_stop(self) -> None:
        """새 실행 시작 — 서비스 ``_begin_run``이 서비스 잠금 안에서 부른다(정지 요청과 직렬화된다).

        이번 실행의 표지(``run_ref``)를 새로 정한다 — 쉬는 중에 온 정지(이전 실행·실행 없음)는 옛 표지에 묶여 있어
        이 실행을 막지 않는다."""
        self._run_ref = "r" + uuid.uuid4().hex[:15]

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
        *, button_behaviors: Mapping[str, str] | None = None,
    ) -> ExecutionResult:
        buttons = list(buttons)
        call_timeout = self._timeout_for(len(buttons))
        hold, self._next_hold = self._next_hold, None
        target, self._next_target = self._next_target, None
        if target is None:
            # RPi4는 대상 없는 execute를 거절한다(평가 H3) — 전자레인지로 가정해 보내지 않는다.
            raise ActLinkError("execute target (appliance_id) was not armed — not sent to RPi4")
        kwargs: dict = {"appliance_id": target}
        if button_behaviors is not None:
            kwargs["button_behaviors"] = dict(button_behaviors)
        if hold:
            kwargs.update(targets=targets or None, hold=hold)
        elif targets:
            kwargs["targets"] = targets
        run_ref = self._run_ref
        if run_ref is not None:
            # 실행 시작(reset_stop)을 거친 실행만 — 표지 없는 호출(시험 대역 등)은 종전 줄 그대로다.
            kwargs["run_ref"] = run_ref

        async def dispatch():
            # 보내기 직전 정지 확인(2026-10-15 G2) — **이벤트 루프 안에서**. request_stop은 표시를 세운 뒤에 abort를
            # 이 루프에 올린다. 여기서 표시가 없으면 이 실행의 abort는 아직 줄에 쓰이지 않았고, 아래 execute 줄을
            # 쓰기까지 await가 없으므로(ActClient.execute → _write) abort는 반드시 execute 뒤에 나가 RPi4가 실행
            # 중에 받는다. 이 실행에 정지 표시가 있으면 보내지 않는다.
            if run_ref is not None and self._stopped_run_ref == run_ref:
                return None
            return await self._client.execute(buttons, **kwargs)

        future = asyncio.run_coroutine_threadsafe(dispatch(), self._loop)
        try:
            result = future.result(timeout=call_timeout)
        except TimeoutError as exc:
            future.cancel()
            raise ActLinkTimeoutError(
                f"ActClientController.execute() timed out after {call_timeout}s"
            ) from exc
        except ActExecuteRefused as exc:
            # 누르기 전 거절(2026-10-19) — 아무것도 누르지 않았다는 것을 안다. '링크 끊김·눌렸는지 모름'(예외)이 아니라
            # 보내지 않음·실패 결과로 돌려준다. 다시 보내지 않는다.
            log.warning("RPi4 refused before pressing (%s) — nothing pressed: %s", exc.reason, exc.detail or "")
            return refused_before_press(exc.reason)
        if result is None:
            log.warning("stop requested before the execute frame was written — %d button(s) not sent", len(buttons))
            return stopped_before_dispatch()
        if not result.success and result.abort_reason == LINK_LOST_ABORT_REASON:
            # RPi4가 생존 신호를 잃고 스스로 멈췄다(2026-10-16 G5) — 그 사이 마지막 누름이 됐는지 모른다. 링크 끊김과 같은
            # '눌렸는지 모름'(서비스의 G1 경로: 수신 unknown·unconfirmed, 다시 누르지 않음)으로 넘긴다. '안전 정지·완료되지
            # 못했어요'로 단정하지 않는다.
            raise ActLinkError(f"RPi4 stopped {result.sequence_id!r} by itself after losing the link heartbeat")

        # RPi4가 보고한 것(종료 방식·버튼별 시도·L3·실행 환경)을 그대로 싣는다 --
        # 없으면(옛 RPi4) 집계 값만으로 합성한다.
        return synthesize_from_act_result(buttons, result)

    def request_stop(self) -> "concurrent.futures.Future[dict] | None":
        """긴급 정지 — RPi4에 abort를 보낸다. **기다리지 않는다**: 진행 중이던 execute()는 RPi4 쪽 중단
        결과(error/result)로 스스로 마무리된다. 전송 실패는 로그만 남긴다 — 정지 경로에서 예외로
        호출자를 죽이는 것보다 물리 E-STOP이 최종 권한이라는 설계를 따른다.

        2026-10-13: abort에 ``stop_id``를 실어 RPi4의 정지 확인 보고를 받는다(`wait_stop_report`가 따로 기다린다).
        돌려주는 값은 이 정지의 보고 핸들 — ``wait_stop_report(handle=…)``로 넘기면 그 정지의 보고만 기다린다(H1)."""

        def _log_send_failure(future: "concurrent.futures.Future[dict]") -> None:
            exc = future.exception()
            if exc is not None:
                log.error("emergency abort send failed: %s", exc)

        # 표시를 **먼저** 세운다(2026-10-15 G2) — abort를 루프에 올리기 전에. execute가 루프 안에서 이 표시를 본다.
        self._stopped_run_ref = self._run_ref
        # 이번 실행의 표지를 abort에 싣는다 — 쉬는 중 RPi4가 받으면 같은 표지의 execute를 누르지 않는다(이중 방어).
        extra = {"run_ref": self._run_ref} if self._run_ref is not None else {}
        with_report = getattr(self._client, "abort_with_report", None)
        coro = with_report(**extra) if callable(with_report) else self._client.abort(**extra)
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        future.add_done_callback(_log_send_failure)
        self._stop_future = future if callable(with_report) else None
        return self._stop_future

    _stop_future: "concurrent.futures.Future[dict] | None" = None

    def wait_stop_report(self, timeout_s: float | None = None,
                         handle: "concurrent.futures.Future[dict] | None" = None) -> dict | None:
        """`request_stop`의 확인 단계 ``{"stop_level", "ack_ms", "target", …}``를 기다린다(블로킹, 짧은 기한).

        ``handle``이 있으면 그 정지의 보고, 없으면 마지막 정지의 보고(종전).
        정지를 보내지 않았으면 None. 보내지 못했으면 ``stop_level: None``과 이유. 기한이 지나면 ``sent``."""
        future = handle if handle is not None else self._stop_future
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

    # 정지 대기·확인 주행(2026-09-30)

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
                "reason": getattr(self._client, "link_down_reason", None),
                # RPi4가 링크를 잃고 스스로 멈춘 마지막 실행(2026-10-16 G5, 다시 이은 뒤 알림). 없으면 None.
                "last_link_stop": getattr(self._client, "last_link_stop", None)}

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

    # UART 리허설(2026-10-06)
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

    # 개발자 조작(2026-10-10)

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
    # TCP_USER_TIMEOUT(2026-10-16 G5): Linux keepalive는 보낸 줄이 확인(ACK)되지 않고 쌓여 있으면 돌지 않는다. 실행 중
    # 생존 신호를 쓰는 링크가 조용히 끊기면 재전송 한도(수 분)까지 끊김을 몰랐을 것이다 — keepalive와 같은 시간에 끊는다.
    user_timeout_ms = (idle + interval * count) * 1000
    for name, value in (("TCP_KEEPIDLE", idle), ("TCP_KEEPINTVL", interval), ("TCP_KEEPCNT", count),
                        ("TCP_USER_TIMEOUT", user_timeout_ms)):
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


def rpi5_link_real_paths() -> list[str]:
    """RPi5에서 켜진 실물 경로 — 무인증 모의 설정(off_for_mock)과 함께 켜지면 시작을 거절한다(2026-10-14).

    RPi5는 RPi4의 모션 구성을 시작 때 알 수 없다. 실물 모션·콘센트 쪽은 RPi4 실행기가 같은 규칙으로 막는다."""
    from .dev_real_motion import DEV_REAL_MOTION_ENV, dev_real_motion_requested

    return [DEV_REAL_MOTION_ENV] if dev_real_motion_requested() else []


def check_link_auth_at_startup() -> None:
    """``SIMPLELAY_ACT_MODE=uart``면 기동 때 짝 키 규칙을 확인한다 — 첫 요청이 아니라 띄울 때 거절한다."""
    import os

    from .link_auth import link_key_from_env

    if os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower() == "uart":
        link_key_from_env(real_paths=rpi5_link_real_paths())


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

    # 짝 키(2026-10-12 무선 링크 인증). 없거나 짧으면 LinkKeyError로 링크를 열지 않는다(2026-10-14 키 필수).
    link_key = link_key_from_env(real_paths=rpi5_link_real_paths())
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
