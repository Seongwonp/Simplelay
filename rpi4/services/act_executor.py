"""ActExecutor — RPi4 side of the RPi5 <-> RPi4 UART protocol (docs/protocol.md).

RPi5 has already resolved a purpose into a button sequence; this class just
runs it through the closed loop and reports back. No intent resolution
happens here — that is entirely RPi5's job.

Message routing table (protocol.md, "UART 프로토콜 (RPi5 <-> RPi4)"):

  INBOUND (RPi5 -> RPi4)          OUTBOUND (RPi4 -> RPi5)
  ──────────────────────────────────────────────────────────
  execute {sequence_id, buttons} →  result {sequence_id, success, retry}
  abort                          →  (cooperative stop; see _on_abort)
  (none — self-initiated)        →  alert {kind, band_energy_ratio,
                                       mean_period_seconds} / alert_cleared
                                    (see report_danger_sound)

Duck-typed reader/writer so this is fully testable without a real serial
port, matching services/bridge.py's pattern:
  - real hardware: asyncio.StreamReader / asyncio.StreamWriter (serial_asyncio)
  - tests:         asyncio.StreamReader.feed_data() / a fake writer
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from typing import Protocol

from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.services.demo_failure import DemoFailureState
from rpi.verifier import DangerSoundResult

from ..models.act_messages import (
    AbortMsg,
    ClearFailureMsg,
    ExecuteMsg,
    InboundActMsg,
    InjectFailureMsg,
    parse_act_message,
)

log = logging.getLogger(__name__)


class _WriterLike(Protocol):
    def write(self, data: bytes) -> None: ...
    async def drain(self) -> None: ...


class ActExecutor:
    """Reads newline-delimited JSON `execute` commands from RPi5, runs them
    through the closed-loop controller, writes JSON results back.

    Args:
        reader:     asyncio.StreamReader (serial or test-injected)
        writer:     asyncio.StreamWriter-compatible (serial or fake)
        controller: Executes a button sequence with closed-loop verification
    """

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: _WriterLike,
        controller: ClosedLoopController,
        failure_state: DemoFailureState | None = None,
    ) -> None:
        """failure_state: 데모 실패 주입 상태(선택). controller의 verifier가
        FailureInjectionVerifier로 같은 인스턴스를 감싸고 있어야 실제로
        발동한다 — act_main._build_executor()가 그 배선을 담당한다.
        None이면 inject_failure/clear_failure 메시지는 로그만 남기고 무시."""
        self._reader = reader
        self._writer = writer
        self._controller = controller
        self._failure_state = failure_state
        self._busy = False
        self._danger_alert_active = False
        # 실행은 별도 task — 읽기 루프가 실행 중에도 abort를 수신할 수 있어야
        # 긴급 정지가 성립한다 (여기서 await하면 루프가 통째로 멈춘다)
        self._execute_task: asyncio.Task[None] | None = None

    # ── Public API ───────────────────────────────────────────────────────────

    async def run(self) -> None:
        """Read lines until EOF or task cancellation."""
        log.info("ActExecutor running")
        try:
            while True:
                await self.run_once()
        except asyncio.IncompleteReadError:
            log.info("ActExecutor: serial stream closed (EOF)")
        except asyncio.CancelledError:
            log.info("ActExecutor: cancelled")
            self._cancel_running_execution()
            raise

    def _cancel_running_execution(self) -> None:
        task = self._execute_task
        if task is None:
            return
        # to_thread 안의 동기 실행은 강제 취소가 불가능하다 — 협조적 정지를
        # 요청해 폐루프가 다음 경계에서 스스로 멈추게 한다.
        request_stop = getattr(self._controller, "request_stop", None)
        if request_stop is not None:
            request_stop()
        task.cancel()

    async def wait_idle(self) -> None:
        """진행 중인 실행 task가 있으면 끝날 때까지 대기 — 테스트·종료 절차용."""
        task = self._execute_task
        if task is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await task

    async def run_once(self) -> None:
        """Read exactly one newline-terminated line and dispatch it.

        Exposed separately so tests can drive the executor message-by-message
        without spinning up a full asyncio task.
        """
        raw_bytes = await self._reader.readuntil(b"\n")
        raw = raw_bytes.decode("utf-8", errors="replace").strip()
        if not raw:
            return

        log.debug("RX <- %s", raw)
        msg = parse_act_message(raw)
        if msg is None:
            log.warning("ignored unrecognised line: %.120s", raw)
            return

        await self._dispatch(msg)

    async def report_danger_sound(self, result: DangerSoundResult) -> None:
        """Forward a DangerSoundDetector reading — called every frame by a
        DangerSoundMonitor task running alongside run(). Edge-triggered: only
        sends on the transition into/out of a detected alarm, so most calls
        (steady detected or steady not-detected) are no-ops.

        This is the one outbound message ActExecutor sends without RPi5
        having asked for it — everything else is a reply to `execute`/`abort`.
        Safe to call concurrently with the read/dispatch loop: `_send()`
        always writes one complete line in a single synchronous `.write()`
        before its only await point, so two in-flight `_send()` calls can
        interleave at `drain()` without corrupting either line.
        """
        if result.detected and not self._danger_alert_active:
            self._danger_alert_active = True
            await self._send({
                "type": "alert",
                "kind": "danger_sound",
                "band_energy_ratio": result.band_energy_ratio,
                "mean_period_seconds": result.mean_period_seconds,
            })
            log.warning(
                "danger sound alert raised (band_energy_ratio=%.2f, period=%s)",
                result.band_energy_ratio, result.mean_period_seconds,
            )
        elif not result.detected and self._danger_alert_active:
            self._danger_alert_active = False
            await self._send({"type": "alert_cleared", "kind": "danger_sound"})
            log.info("danger sound alert cleared")

    # ── Dispatch ─────────────────────────────────────────────────────────────

    async def _dispatch(self, msg: InboundActMsg) -> None:
        if isinstance(msg, ExecuteMsg):
            await self._on_execute(msg)
        elif isinstance(msg, AbortMsg):
            self._on_abort()
        elif isinstance(msg, InjectFailureMsg):
            self._on_inject_failure(msg)
        elif isinstance(msg, ClearFailureMsg):
            self._on_clear_failure()

    # ── Handlers ─────────────────────────────────────────────────────────────

    async def _on_execute(self, msg: ExecuteMsg) -> None:
        if self._busy:
            # RPi5 should never send a new execute before the previous result
            # arrived, but stay defensive rather than run two sequences at once.
            log.warning("execute %r ignored — already running a sequence", msg.sequence_id)
            await self._send({
                "type": "error",
                "sequence_id": msg.sequence_id,
                "reason": "busy",
            })
            return

        self._busy = True
        # 이전 run의 stale stop 제거 — 토큰 리셋 책임은 실행을 시작시키는 쪽
        reset_stop = getattr(self._controller, "reset_stop", None)
        if reset_stop is not None:
            reset_stop()
        # 실행을 별도 task로 띄우고 즉시 반환한다. 여기서 await하면 읽기
        # 루프가 실행 완료까지 멈춰서, 실행 중 도착한 abort(긴급 정지)를
        # 읽을 수 없었다 — "실행 중 정지 불가"였던 진짜 원인.
        self._execute_task = asyncio.create_task(self._execute_and_report(msg))

    async def _execute_and_report(self, msg: ExecuteMsg) -> None:
        try:
            # Run the synchronous controller in a thread so the event loop
            # stays responsive to incoming UART data during execution.
            result = await asyncio.to_thread(
                self._controller.execute, list(msg.buttons)
            )
        except Exception:
            log.exception("controller.execute raised for sequence %r", msg.sequence_id)
            await self._send({
                "type": "error",
                "sequence_id": msg.sequence_id,
                "reason": "actuator_fail",
            })
            return
        finally:
            self._busy = False
            self._execute_task = None

        success = result.status is ExecutionStatus.SUCCEEDED
        retry = max((b.attempts - 1 for b in result.buttons), default=0)

        await self._send({
            "type": "result",
            "sequence_id": msg.sequence_id,
            "success": success,
            "retry": retry,
        })
        log.info(
            "sequence %r finished — %s (retry=%d)",
            msg.sequence_id, "ok" if success else "FAILED", retry,
        )

    def _on_inject_failure(self, msg: InjectFailureMsg) -> None:
        if self._failure_state is None:
            log.warning("inject_failure ignored — no failure_state wired")
            return
        self._failure_state.arm(msg.button_index, msg.attempts)
        log.info(
            "demo failure armed — button_index=%d attempts=%d",
            msg.button_index, msg.attempts,
        )

    def _on_clear_failure(self) -> None:
        if self._failure_state is None:
            return
        self._failure_state.disarm()
        log.info("demo failure disarmed")

    def _on_abort(self) -> None:
        # A physical E-STOP is authoritative and out of band from this UART
        # link (see rpi/controller/ports.py SafetyController docstring).
        # ClosedLoopController.request_stop()이 협조적 취소를 지원한다:
        # 실행 스레드가 버튼 사이/재시도 경계에서 플래그를 확인하고
        # SAFETY_STOPPED로 종료하면, 그 result가 RPi5에 정상 회신된다 —
        # 폰/키오스크의 긴급 정지가 UART 모드에서도 끝단까지 완결되는 지점.
        if self._busy:
            request_stop = getattr(self._controller, "request_stop", None)
            if request_stop is not None:
                log.warning("abort received mid-execution — requesting cooperative stop")
                request_stop()
            else:
                log.warning(
                    "abort received mid-execution — controller has no request_stop hook"
                )
        else:
            log.info("abort received while idle — nothing to cancel")

    # ── IO helper ────────────────────────────────────────────────────────────

    async def _send(self, doc: dict) -> None:
        payload = (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
        log.debug("TX -> %s", payload.rstrip().decode())
        self._writer.write(payload)
        await self._writer.drain()
