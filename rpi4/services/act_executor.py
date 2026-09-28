"""ActExecutor — RPi4 side of the RPi5 <-> RPi4 UART protocol (docs/protocol.md).

RPi5 has already resolved a purpose into a button sequence; this class just
runs it through the closed loop and reports back. No intent resolution
happens here — that is entirely RPi5's job.

Message routing table (protocol.md, "UART 프로토콜 (RPi5 <-> RPi4)"):

  INBOUND (RPi5 -> RPi4)          OUTBOUND (RPi4 -> RPi5)
  ──────────────────────────────────────────────────────────
  execute {sequence_id, buttons,  →  result {sequence_id, success, retry,
           targets?}                         outcome, button_results,
                                             operation_confirmed, operation_detail,
                                             operation_source, execution_mode}
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

from rpi.controller import (
    ClosedLoopController,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
    VerificationLayer,
    outcome_of,
)
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

# 종료 시 협조적 정지가 실제로 반영되기를 기다리는 시간. 폐루프의 정지 확인
# 지점은 버튼 사이·재시도 경계라, 한 번의 누름+검증이 끝날 만큼은 줘야 한다.
SHUTDOWN_STOP_GRACE_SECONDS = 5.0


def result_detail_fields(result: ExecutionResult, controller: object) -> dict:
    """result 프레임의 확장 필드(docs/protocol.md, 2026-09-30).

    - ``button_results``: 실제로 돈 버튼마다 {button, ok, attempts, layer, corrections}.
      RPi5가 재시도 수를 버튼별로 정확히 기록하게 한다(집계 ``retry``만으로는 성공 시
      재시도가 사라졌다 — G1).
    - ``operation_confirmed``: L3 판정. true/false, 판정기가 없거나 판정하지 못했으면 null.
    - ``operation_detail``: 판정 사유 한 줄(없으면 null).
    - ``operation_source``: 판정 입력이 실물(real)인지 합성(mock)인지. 판정 없으면 null.
    - ``execution_mode``: 이 보드가 실제 모터를 돌렸나(모션 어댑터가 스스로 밝힌 값).
    """
    button_results = []
    for b in result.buttons:
        button_results.append({
            "button": b.button,
            "ok": b.status.value == "succeeded",
            "attempts": b.attempts,
            "layer": b.failed_layer.value if b.failed_layer is not None else None,
            "corrections": [
                {
                    "retry_number": c.retry_number,
                    "xy_adjustment_required": c.xy_adjustment_required,
                    "increase_press_depth": c.increase_press_depth,
                }
                for c in getattr(b, "corrections", ())
            ],
        })
    operation = result.operation
    if operation is not None:
        confirmed: bool | None = bool(operation.passed)
        detail: str | None = operation.detail or None
        source: str | None = "mock" if getattr(operation, "mock", False) else "real"
    else:
        confirmed, source = None, None
        detail = (
            "L3 판정 불가 — 전력 센서를 읽지 못했거나 판정 전에 멈춤"
            if result.failed_layer is VerificationLayer.OPERATION
            else None
        )
    mode = getattr(controller, "execution_mode", ExecutionMode.UNKNOWN)
    mode_value = mode.value if isinstance(mode, ExecutionMode) else "unknown"
    return {
        "button_results": button_results,
        "operation_confirmed": confirmed,
        "operation_detail": detail,
        "operation_source": source,
        "execution_mode": mode_value,
    }


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
            await self.shutdown()
            raise

    async def shutdown(
        self, grace_seconds: float = SHUTDOWN_STOP_GRACE_SECONDS
    ) -> bool:
        """진행 중인 실행을 협조적으로 멈추고, 실제로 멈출 때까지 기다린다.

        ``task.cancel()``만으로는 부족하다: 실행 본체는 ``asyncio.to_thread``
        안의 동기 코드라 강제 취소가 불가능하다. 취소는 코루틴만 끝내고
        (그 finally가 _busy·_execute_task를 정리해 ``wait_idle()``까지 "끝남"
        으로 보이게 한다) 정작 스레드는 계속 버튼을 누른다. 그래서 정지를
        요청한 뒤 스레드가 실제로 반환할 때까지 기다린다.

        반환값은 유예 시간 안에 실제로 멈췄는지 — False면 소프트웨어가 더 할
        수 있는 일이 없다는 뜻이고, 최종 권한은 물리 E-STOP과 모터 드라이버
        enable 차단이다(rpi/controller/ports.py의 SafetyController 참고).
        """
        task = self._execute_task
        if task is None or task.done():
            return True

        request_stop = getattr(self._controller, "request_stop", None)
        if request_stop is not None:
            request_stop()
        else:
            log.warning("shutdown: controller has no request_stop hook")

        try:
            # shield: 종료 중 우리가 또 취소돼도 실행 task 자체는 살려두고
            # 협조적 정지가 자기 경계까지 진행하게 둔다.
            await asyncio.wait_for(asyncio.shield(task), timeout=grace_seconds)
            return True
        except asyncio.TimeoutError:
            log.error(
                "execution did not stop within %.1fs — physical E-STOP is the "
                "final authority", grace_seconds,
            )
            task.cancel()
            return False
        except asyncio.CancelledError:
            # 종료 중 두 번째 취소(Ctrl+C 연타 등) — 더 기다리지 않는다
            task.cancel()
            raise
        except Exception:
            log.exception("execution task raised during shutdown")
            return True

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
            if msg.targets:
                # 좌표가 실린 실행만 targets를 넘긴다 — 좌표 없는 종전 실행은
                # 호출 모양까지 그대로 둔다.
                result = await asyncio.to_thread(
                    self._controller.execute, list(msg.buttons), msg.targets
                )
            else:
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
        # success=false 하나로는 '정지 요청으로 멈춤'과 '검증 실패로 안전 정지'가
        # 구별되지 않았다. 종료 방식을 함께 보낸다(docs/protocol.md outcome).
        # success는 옛 RPi5와의 호환을 위해 그대로 둔다.
        outcome = outcome_of(result).value

        await self._send({
            "type": "result",
            "sequence_id": msg.sequence_id,
            "success": success,
            "retry": retry,
            "outcome": outcome,
            # 2026-09-30: 버튼별 시도 수·보정, L3 판정, 실행 환경. 옛 RPi5는 무시한다.
            **result_detail_fields(result, self._controller),
        })
        log.info(
            "sequence %r finished — %s (retry=%d)",
            msg.sequence_id, outcome, retry,
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
