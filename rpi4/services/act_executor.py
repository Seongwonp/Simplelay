"""ActExecutor — RPi4 side of the RPi5 <-> RPi4 UART protocol (docs/protocol.md).

RPi5 has already resolved a purpose into a button sequence; this class just
runs it through the closed loop and reports back. No intent resolution
happens here — that is entirely RPi5's job.

Message routing table (protocol.md, "UART 프로토콜 (RPi5 <-> RPi4)"):

  INBOUND (RPi5 -> RPi4)          OUTBOUND (RPi4 -> RPi5)
  ──────────────────────────────────────────────────────────
  execute {sequence_id, buttons,  →  result {sequence_id, appliance_id, success, retry,
           appliance_id, targets?}           outcome, button_results,
                                             operation_confirmed, operation_detail,
                                             operation_source, execution_mode}
                                 →  progress {sequence_id, n, button, step_index,
                                             attempt, phase, ...} (누름마다, 선택 —
                                             SIMPLELAY_ACT_PROGRESS=0이면 끔. 결과 아님)
                                 →  progress {phase:"hold", hold_state, stop_outcome, ...}
                                             (execute에 hold가 있으면 결과 뒤 정지 대기·보관 보고)
  abort {scope?, stop_id?}       →  (cooperative stop; 정지 대기 중이면 정지 버튼 누름 — _on_abort)
                                 →  stop_report {stop_id, target, stop_level, ack_ms, stop_detail?}
                                    (stop_id가 있을 때만, 정지 보고 규약 1 — 2026-10-13. target run·dev·hold·idle,
                                    stop_level sent·mcu_ack·verified, 아무것도 멈추지 않았으면 null)
  abort {run_ref} (쉬는 중)       →  (기억) 같은 run_ref의 execute → result {success:false, outcome:"stopped",
                                    button_results:[]} — 누르지 않는다(2026-10-15 G2, run_ref 없는 옛 RPi5는 종전대로 버림)
  verify_pass {sequence_id,      →  progress {phase:"verify", ...} + verify_result
               targets}                     {sequence_id, ok, targets:[{button,status,...}]}
  (none — self-initiated)        →  alert {kind, band_energy_ratio,
                                       mean_period_seconds} / alert_cleared
                                    (see report_danger_sound)
  (outlet module estop event)    →  alert {kind:"outlet_estop", source} + estop_state {latched:true}
                                    + 실행 중이면 정지 경로 (see handle_outlet_estop, 2026-10-05)
  hello                          →  act_info {done_watch, rehearsal, outlet, motion} + estop_state
                                    (RPi5 (재)연결 — 2026-10-06 평가 C1·B3. RPi4가 켜질 때도 한 번 스스로 보낸다)
  rehearsal {action, request_id} →  rehearsal_result {request_id, ok, reason?, frame?}
                                    (가짜 콘센트·모의 모션일 때만 — 2026-10-06 UART 리허설)
  (콘센트 모듈 재부팅으로 켜 둔 릴레이가 꺼짐) → estop_state {latched:true, source:"outlet_reboot", detail}
                                    (자동으로 켜지 않는다 — estop_ack 뒤에만, 2026-10-06 평가 A4)
  estop_ack                      →  estop_state {latched, reason, detail}
                                    (비상정지 걸림 해제 확인 — 버튼이 풀렸을 때만 풀린다)
  dev_motion {request_id, op,    →  dev_motion_result {request_id, op, ok, reason?, detail?, moved?,
              axis?, delta_mm?,                      homed?, x_mm?, y_mm?, stop_level?, ack_ms?}
              label?, reason?}      (개발자 조작 규약 2 — stop 답에 정지 확인 단계, 2026-10-13. 규약 1은 2026-10-10 — 실제 모션 어댑터가 물렸을 때만
                                    act_info.dev_motion_protocol로 알리고 받는다. rpi4/services/dev_motion.py.
                                    비상정지 걸림·콘센트 무응답·모션 연결 전·일반 실행/정지 대기 중이면
                                    움직이기 전에 거절(moved:false). stop은 언제나 받아 MCU stop을 보낸다)
  (dev_motion 진행 중 execute/verify_pass) → error {reason:"dev_busy"}
  (걸린 동안의 execute/verify_pass) → error {reason:"estop_latched"}
  (대상 appliance_id 없는 execute) → error {reason:"target_required"} (2026-10-07, 평가 H3)
  (대상 CT 채널이 없는데 L3 real) → error {reason:"target_unbound"} — 누르기 전 (target_binding.py)
  (콘센트 모듈 무응답 중 execute/verify_pass) → error {reason:"outlet_offline"}
  (after an L3-confirmed result) →  progress {phase:"power_tail", power_tail:{...}}
                                    (잔여 전류 꼬리 기록 — after_result 훅, 2026-10-05)
  (none — self-initiated)        →  appliance_done {appliance_id, event, state, confidence, inputs,
                                       source, evidence, ...} (세탁 끝: CT 전력 + 종료음 융합,
                                       appliance_done_watch, 2026-10-06 — see report_appliance_done)

Duck-typed reader/writer so this is fully testable without a real serial
port, matching services/bridge.py's pattern:
  - real hardware: asyncio.StreamReader / asyncio.StreamWriter (serial_asyncio)
  - tests:         asyncio.StreamReader.feed_data() / a fake writer
"""

from __future__ import annotations

import asyncio
import contextlib
import functools
import itertools
import json
import logging
import os
import time
from collections.abc import Callable
from typing import TYPE_CHECKING, Protocol

from rpi.controller import (
    ClosedLoopController,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
    VerificationLayer,
    outcome_of,
)
from rpi.services.demo_failure import DemoFailureState
from rpi.services.link_auth import ServerAuth
from rpi.verifier import DangerSoundResult
from rpi.verifier.done_fusion import CLOCK_ID, rehearsal_done_event

from ..models.act_messages import (
    AbortMsg,
    ClearFailureMsg,
    ClockProbeMsg,
    DevMotionMsg,
    DevMotionRefusedMsg,
    EstopAckMsg,
    EXECUTE_PROTOCOL,
    ExecuteMsg,
    ExecuteRefusedMsg,
    HelloMsg,
    InboundActMsg,
    InjectFailureMsg,
    RehearsalMsg,
    VerifyPassMsg,
    parse_act_message,
)
from .dev_motion import DEV_MOTION_PROTOCOL, DevMotionService

if TYPE_CHECKING:
    from rpi.controller.serial_motion import StopReport
from .stop_hold import HoldHardware, StopHoldSession, run_verify_pass
from .target_binding import TargetBinder, TargetBinding, TargetRefused

log = logging.getLogger(__name__)

PROGRESS_ENV = "SIMPLELAY_ACT_PROGRESS"
#: act_info로 알리는 사건 신선도 기준점 규약 판(3차 평가 M1, 2026-10-14). 1 = ``clock_probe``에 ``clock_ref``로 답한다.
CLOCK_PROTOCOL = 1
#: act_info로 알리는 정지 보고 규약 판(2026-10-13). 1 = ``abort {stop_id}``에 ``stop_report``로 답한다.
#: RPi5는 이 값이 없는 RPi4(옛 판)면 보고를 기다리지 않고 ``sent``(보냄)로만 말한다.
STOP_REPORT_PROTOCOL = 1


def progress_enabled_from_env() -> bool:
    """progress 프레임 송신 여부. 기본 켜짐 — 옛 RPi5 ActClient와 ESP32 노드 펌웨어는
    모르는 ``type``을 무시한다(docs/protocol.md). ``0``/``false``/``off``면 끈다."""
    raw = os.environ.get(PROGRESS_ENV, "").strip().lower()
    return raw not in ("0", "false", "no", "off")


# 종료 시 협조적 정지가 실제로 반영되기를 기다리는 시간. 폐루프의 정지 확인
# 지점은 버튼 사이·재시도 경계라, 한 번의 누름+검증이 끝날 만큼은 줘야 한다.
SHUTDOWN_STOP_GRACE_SECONDS = 5.0

#: 비상정지 걸림 해제 결과 사유(``estop_state.reason``) → 사람이 읽을 설명.
ESTOP_REASON_DETAIL = {
    "estop_button_pressed": "빨간 비상 버튼이 아직 눌려 있어요 — 돌려서 푼 뒤 다시 눌러 주세요",
    "outlet_unreachable": "가전 콘센트 장치가 답하지 않아 비상 버튼 걸림을 풀지 못했어요",
    "estop_retriggered": "해제하는 사이 비상 버튼이 다시 눌렸어요",
}
ESTOP_LATCHED_DETAIL = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요"
#: 콘센트 모듈 재부팅으로 켜 두었던 릴레이가 꺼졌을 때(``source:"outlet_reboot"``). rpi.verifier.outlet과 같은 문장.
POWER_LOST_LATCH_DETAIL = "가전 콘센트 장치가 다시 켜져 가전 전원이 꺼져 있어요 — 해제하면 전원을 다시 켜요"
#: 리허설 주입을 거절하는 이유(실물 모듈·모터에 붙어 있음).
REHEARSAL_REFUSED_DETAIL = "RPi4가 실물 콘센트 모듈이나 모션 MCU에 붙어 있어 리허설 주입을 받지 않아요"


def result_detail_fields(result: ExecutionResult, controller: object) -> dict:
    """result 프레임의 확장 필드(docs/protocol.md, 2026-09-29).

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
        progress: bool | None = None,
        job_observer: "Callable[[str, dict], None] | None" = None,
        readiness: "Callable[[], str | None] | None" = None,
        hold: "HoldHardware | None" = None,
        after_result: "Callable[[str, ExecutionResult, Callable[[dict], None]], None] | None" = None,
        outlet_readiness: "Callable[[], str | None] | None" = None,
        target_binder: "TargetBinder | None" = None,
        dev_motion: "DevMotionService | None" = None,
        link_key: "str | bytes | None" = None,
        motion_stop: object | None = None,
    ) -> None:
        """failure_state: 데모 실패 주입 상태(선택). controller의 verifier가
        FailureInjectionVerifier로 같은 인스턴스를 감싸고 있어야 실제로
        발동한다 — act_main._build_executor()가 그 배선을 담당한다.
        None이면 inject_failure/clear_failure 메시지는 로그만 남기고 무시.

        progress: 누름마다 ``progress`` 프레임을 보낼지. None이면 SIMPLELAY_ACT_PROGRESS
        (기본 켜짐). 컨트롤러가 ``set_press_observer``를 가져야 실제로 나간다.
        job_observer: 실행 시작·끝(``job_start``/``job_end``, sequence_id 포함)을 받는
        함수(선택). act_main이 모션 줄 기록·원시 기록기에 같은 sequence_id를 찍는 데 쓴다.
        readiness: 실행 전에 부르는 준비 확인(선택). 이유 문자열을 돌려주면 execute를 시작하지 않고
        ``{"type":"error","reason":"motion_not_ready","detail":…}``로 거절한다(모션 MCU 연결 확인 전).
        hold: 정지 버튼 대기·보관·확인 주행에 쓸 모션·가전 확인 부품(선택, 2026-09-30).
        None이면 execute의 ``hold``를 무시하고 ``verify_pass``는 ``verify_unavailable``로 거절한다.
        after_result: 결과를 보낸 뒤 부르는 훅(선택, 2026-10-05) ``(sequence_id, result, emit)``.
        콘센트 모듈의 잔여 전류 꼬리 관찰(`outlet_watch.OutletTailHook`)이 쓴다. ``emit``은
        ``progress {phase:"power_tail"}`` 프레임을 보낸다. 훅에 ``stop()``이 있으면 새 실행·종료 때 부른다.
        outlet_readiness: 콘센트 모듈 생존 확인(선택, 2026-10-05). 이유 문자열이면 execute·verify_pass를
        ``outlet_offline``으로 거절한다 — 모듈이 조용하면 물리 비상정지를 볼 수 없으므로 안전 쪽으로 멈춘다.
        target_binder: 실행 대상 가전 → L3 판정기·잔여 전류 꼬리 결속(선택, 2026-10-07 평가 H3). 있으면 execute마다
        대상의 판정기를 컨트롤러에 꽂고(``use_operation``) 그 대상의 꼬리 훅을 ``after_result`` 대신 쓴다.
        결속할 수 없는 대상(L3 real인데 CT 채널 없음)은 누르기 전에 ``error {reason}``으로 거절한다.
        None이면 컨트롤러에 꽂힌 판정기를 그대로 쓴다(시험·시뮬레이터).
        dev_motion: 개발자 조작(``dev_motion`` 프레임)을 모션 MCU로 넘기는 서비스(선택, 2026-10-10). 실제 모션
        어댑터(serial)일 때만 act_main이 꽂는다 — 있을 때만 ``act_info.dev_motion_protocol``을 알린다.
        link_key: 짝 키(``SIMPLELAY_LINK_KEY``, 2026-10-12 무선 링크 인증, 16자 이상 — 짧으면 `LinkKeyError`). 주면
        서명된 hello마다 새 세션을 열고(첫 답 act_info에 ``cn``·``sn``), 그 세션의 서명·``seq``가 맞는 프레임만
        받는다. 나머지(서명 없음·MAC 틀림·``seq`` 되돌림·이미 쓴 hello)는 답 없이 버린다 — 정지(abort)도 같다.
        세션 전에는 아무것도 보내지 않는다(켜질 때의 자발 알림도). None이면 종전 그대로.
        motion_stop: 실행 중 정지의 확인 단계를 읽을 실제 모션 어댑터(``confirm_stop()``을 가진 것, 2026-10-13).
        act_main이 serial 모드면 `SerialMotionClient`를 꽂는다. None(모의 모션)이면 실행 중 정지는 ``sent``로 보고한다.

        비상정지 걸림(2026-10-05): 콘센트 모듈의 비상정지(이벤트·ready·status 보고)를 받으면
        ``estop_latched``가 켜지고, RPi5가 ``estop_ack``로 해제를 확인할 때까지 execute·verify_pass를
        ``estop_latched``로 거절한다. 해제 때 모듈 쪽 해제는 ``set_estop_reset``으로 꽂은 함수가 한다
        (버튼이 아직 눌려 있으면 풀지 않는다)."""
        self._auth = None if link_key is None else ServerAuth(link_key)
        self._reader = reader
        self._writer = writer
        self._controller = controller
        self._failure_state = failure_state
        self._busy = False
        self._danger_alert_active = False
        # 실행은 별도 task — 읽기 루프가 실행 중에도 abort를 수신할 수 있어야
        # 긴급 정지가 성립한다 (여기서 await하면 루프가 통째로 멈춘다)
        self._execute_task: asyncio.Task[None] | None = None
        self._progress = progress_enabled_from_env() if progress is None else progress
        self._job_observer = job_observer
        self._readiness = readiness
        self._drain_tasks: set[asyncio.Task[None]] = set()
        self._hold_hw = hold
        #: 지금(또는 마지막) 정지 대기. 끝난 뒤에도 상태 조회용으로 남는다.
        self.hold_session: StopHoldSession | None = None
        self._verify_stop = False
        self._after_result = after_result
        self._target_binder = target_binder
        #: 마지막 결과에 쓴 꼬리 훅(새 실행·종료 때 멈춘다).
        self._active_after_result = after_result
        #: 콘센트 모듈 비상정지 이벤트 수(시험·상태 확인용).
        self.outlet_estops = 0
        self._outlet_readiness = outlet_readiness
        #: 호스트 쪽 비상정지 걸림. 사람의 해제 확인(``estop_ack``) 전에는 움직이지 않는다.
        self.estop_latched = False
        #: 걸린 원인(button·ready·status). 풀리면 None.
        self.estop_source: str | None = None
        self._estop_gen = 0  # 걸릴 때마다 1 증가 — 해제 확인 중 다시 걸렸는지 가린다
        self._estop_reset: "Callable[[], tuple[bool, str | None]] | None" = None
        #: 해제 확인(estop_ack) 처리 task — 읽기 루프를 막지 않게 따로 돈다(2026-10-06 평가 C2).
        self._ack_task: asyncio.Task[None] | None = None
        #: RPi5에 알리는 구성(``act_info``): 끝 관찰 가전·리허설 가능 여부 등. act_main이 채운다.
        self.act_info: dict = {}
        #: 리허설 주입 부품(가짜 콘센트·모의 모션일 때만 act_main이 꽂는다). None이면 rehearsal을 거절한다.
        self._rehearsal: object | None = None
        #: 개발자 조작 서비스와 진행 중 조작(한 번에 하나).
        self._dev_motion = dev_motion
        self._dev_task: asyncio.Task[None] | None = None
        self._motion_stop = motion_stop
        #: 정지 확인을 기다렸다 답하는 task(dev_motion stop 답·stop_report) — 읽기 루프를 막지 않게 따로 돈다.
        self._stop_tasks: set[asyncio.Task[None]] = set()
        #: 쉬는 중에 받은 abort의 실행 표지(``run_ref``, 2026-10-15 G2). 같은 표지의 execute는 누르지 않고 정지 결과로
        #: 답한다(한 번 쓰면 지운다). 다른 표지의 execute가 오면 그 실행은 이미 끝난 것이라 지운다.
        self._aborted_run_ref: str | None = None

    # ── Public API ───────────────────────────────────────────────────────────

    async def run(self) -> None:
        """Read lines until EOF or task cancellation."""
        log.info("ActExecutor running")
        # 켜질 때 한 번 스스로 알린다 — RPi5가 먼저 떠 있었으면 hello를 다시 보내지 않으니(2026-10-06 평가 C1).
        self._announce()
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
        self._close_hold()
        self._stop_after_result()
        self._stop_dev("shutdown")
        task = self._execute_task
        if task is None or task.done():
            return True

        self._verify_stop = True
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
        if self._auth is not None and not self._authentic(raw):
            return  # 답하지 않는다
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

    # ── 가전 완료(세탁 끝, 2026-10-06) ───────────────────────────────────────

    def report_appliance_done(self, frame: dict) -> None:
        """세탁 끝 관찰(`appliance_done_watch.ApplianceDoneWatch`)이 낸 ``appliance_done`` 프레임을 RPi5로 보낸다.

        **이벤트 루프 스레드에서** 부른다(다른 스레드는 `thread_safe_done_emitter`). 실행 중이어도 보낸다 —
        결과(``result``)가 아니라 자체발신 알림이다. 아무것도 움직이지 않는다.
        """
        if not isinstance(frame, dict) or frame.get("type") != "appliance_done":
            log.warning("report_appliance_done ignored a non-appliance_done frame: %r", frame)
            return
        self._write_now(frame)

    def thread_safe_done_emitter(self, loop: asyncio.AbstractEventLoop) -> "Callable[[dict], None]":
        """관찰 스레드(전력 읽기)·오디오 루프 어디서든 부를 수 있는 보내기 함수."""

        def emit(frame: dict) -> None:
            try:
                loop.call_soon_threadsafe(self.report_appliance_done, dict(frame))
            except RuntimeError:  # 루프가 닫힌 뒤
                log.error("appliance_done arrived after the event loop closed — not sent")

        return emit

    def inject_appliance_done(self, appliance_id: str, inputs: "list[str] | tuple[str, ...]",
                              event: str | None = None) -> dict:
        """리허설 주입(시연 v3 갭 S8) — **시뮬레이터 실행기 전용**. 같은 융합 규칙에 주입 입력을 넣어
        ``source:"injected"`` 프레임을 보내고 그 프레임을 돌려준다. 실물 경로(act_main)는 이것을 부르지 않는다."""
        done = rehearsal_done_event(appliance_id, list(inputs), now_s=time.monotonic(), event=event)
        frame = done.to_frame(time.monotonic_ns())
        self._write_now(frame)
        return frame

    # ── Dispatch ─────────────────────────────────────────────────────────────

    async def _dispatch(self, msg: InboundActMsg) -> None:
        if isinstance(msg, ExecuteMsg):
            await self._on_execute(msg)
        elif isinstance(msg, ExecuteRefusedMsg):
            log.warning("execute %r refused — %s", msg.sequence_id, msg.reason)
            await self._send({"type": "error", "sequence_id": msg.sequence_id, "reason": msg.reason,
                              "detail": msg.detail})
        elif isinstance(msg, EstopAckMsg):
            self._start_estop_ack()
        elif isinstance(msg, HelloMsg):
            self._announce()
        elif isinstance(msg, ClockProbeMsg):
            # 사건 신선도 기준점(3차 평가 M1) — 읽은 즉시 이 프로세스의 단조 시각으로 답한다.
            self._write_now({"type": "clock_ref", "probe": msg.probe, "clock_id": CLOCK_ID,
                             "t_monotonic_ns": time.monotonic_ns()})
        elif isinstance(msg, RehearsalMsg):
            await self._on_rehearsal(msg)
        elif isinstance(msg, AbortMsg):
            self._on_abort(msg)
        elif isinstance(msg, VerifyPassMsg):
            await self._on_verify_pass(msg)
        elif isinstance(msg, InjectFailureMsg):
            self._on_inject_failure(msg)
        elif isinstance(msg, ClearFailureMsg):
            self._on_clear_failure()
        elif isinstance(msg, DevMotionMsg):
            await self._on_dev_motion(msg)
        elif isinstance(msg, DevMotionRefusedMsg):
            await self._send({"type": "dev_motion_result", "request_id": msg.request_id, "op": msg.op, "ok": False,
                              "reason": msg.reason, "detail": msg.detail, "moved": False})

    # ── Handlers ─────────────────────────────────────────────────────────────

    async def _on_execute(self, msg: ExecuteMsg) -> None:
        if self._dev_running():
            # 개발자 조작과 일반 실행은 같은 모터를 쓴다 — RPi5 중재자가 먼저 막지만 여기서도 막는다.
            log.warning("execute %r refused — a developer motion op is running", msg.sequence_id)
            await self._send({"type": "error", "sequence_id": msg.sequence_id, "reason": "dev_busy",
                              "detail": "개발자 조작이 진행 중이에요"})
            return
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

        # 실행 시작 전에 온 정지(2026-10-15 G2, 이중 방어): RPi5가 이 실행의 abort를 먼저 보냈다면(쉬는 중에 받음)
        # 이 시퀀스는 누르지 않는다. 표지가 없는 옛 RPi5 프레임은 종전 그대로다.
        aborted, self._aborted_run_ref = self._aborted_run_ref, None
        if msg.run_ref is not None and msg.run_ref == aborted:
            log.warning("execute %r not started — its run was aborted before it arrived", msg.sequence_id)
            await self._send({
                "type": "result",
                "sequence_id": msg.sequence_id,
                "appliance_id": msg.appliance_id,
                "success": False,
                "retry": 0,
                "outcome": "stopped",
                # 누른 버튼이 없다는 것을 RPi4가 안다 — 빈 목록(RPi5는 '0개 눌림'으로 읽는다).
                "button_results": [],
                "execution_mode": self._mode_value(),
            })
            return

        if await self._refuse_if_unsafe("execute", msg.sequence_id):
            return

        # 대상 결속은 대기 해제보다 먼저 — 결속할 수 없는 실행이 지금 정지 대기를 건드리지 않게.
        binding: TargetBinding | None = None
        if self._target_binder is not None:
            try:
                binding = self._target_binder.bind(msg.appliance_id)
            except TargetRefused as exc:
                log.warning("execute %r refused — %s: %s", msg.sequence_id, exc.reason, exc.detail)
                await self._send({"type": "error", "sequence_id": msg.sequence_id, "reason": exc.reason,
                                  "detail": exc.detail})
                return
            except Exception as exc:  # noqa: BLE001 - 결속 고장이 실행기 루프를 죽이지 않게(교차 리뷰 92876bd)
                log.exception("execute %r — target bind failed", msg.sequence_id)
                await self._send({"type": "error", "sequence_id": msg.sequence_id,
                                  "reason": "target_bind_failed",
                                  "detail": f"실행 대상 결속 실패로 누르지 않았어요: {exc}"})
                return

        if not await self._release_hold_for_new_run():
            await self._send({
                "type": "error",
                "sequence_id": msg.sequence_id,
                "reason": "hold_busy",
                "detail": "작은 팔이 정지 버튼을 누르거나 제자리로 돌아가는 중이에요",
            })
            return

        # 대기 해제를 기다리는(await) 사이에는 _busy가 False라 비상정지가 '쉬는 중'으로 처리됐을 수 있다.
        # 여기서 다시 확인하고, 이 뒤로는 await 없이 _busy를 세운다(이벤트 루프 한 턴 안).
        if await self._refuse_if_unsafe("execute", msg.sequence_id):
            return

        self._busy = True
        self._stop_after_result()  # 지난 실행의 꼬리 관찰은 새 실행에서 끊는다(status=stopped)
        # 이전 run의 stale stop 제거 — 토큰 리셋 책임은 실행을 시작시키는 쪽
        reset_stop = getattr(self._controller, "reset_stop", None)
        if reset_stop is not None:
            reset_stop()
        if binding is not None:
            # 이번 실행의 L3는 대상 CT 채널(또는 없음) — 전자레인지 채널로 다른 가전을 확인하지 않는다.
            self._controller.use_operation(binding.operation)
        # 실행을 별도 task로 띄우고 즉시 반환한다. 여기서 await하면 읽기
        # 루프가 실행 완료까지 멈춰서, 실행 중 도착한 abort(긴급 정지)를
        # 읽을 수 없었다 — "실행 중 정지 불가"였던 진짜 원인.
        self._execute_task = asyncio.create_task(self._execute_and_report(msg, binding))

    def _not_ready_reason(self) -> str | None:
        return self._check(self._readiness, "readiness")

    @staticmethod
    def _check(fn: "Callable[[], str | None] | None", name: str) -> str | None:
        if fn is None:
            return None
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - 확인 고장은 준비 안 됨으로 본다
            log.exception("%s check failed", name)
            return f"준비 확인 실패: {exc}"

    def _unsafe_reason(self) -> tuple[str, str] | None:
        """움직이면 안 되는 이유 (reason, detail). 비상정지 → 콘센트 무응답 → 모션 준비 순."""
        if self.estop_latched:
            return "estop_latched", self._latch_detail()
        outlet = self._check(self._outlet_readiness, "outlet readiness")
        if outlet is not None:
            return "outlet_offline", outlet
        motion = self._not_ready_reason()
        if motion is not None:
            return "motion_not_ready", motion
        return None

    async def _refuse_if_unsafe(self, what: str, sequence_id: str) -> bool:
        unsafe = self._unsafe_reason()
        if unsafe is None:
            return False
        reason, detail = unsafe
        log.warning("%s %r refused — %s: %s", what, sequence_id, reason, detail)
        await self._send({"type": "error", "sequence_id": sequence_id, "reason": reason, "detail": detail})
        return True

    def _notify_job(self, event: str, fields: dict) -> None:
        if self._job_observer is None:
            return
        try:
            self._job_observer(event, fields)
        except Exception:  # noqa: BLE001 - 기록 고장이 실행을 막지 않는다
            log.exception("job observer failed")

    def _attach_progress(self, sequence_id: str) -> bool:
        setter = getattr(self._controller, "set_press_observer", None)
        if not self._progress or not callable(setter):
            return False
        loop = asyncio.get_running_loop()
        counter = 0
        mode = getattr(self._controller, "execution_mode", ExecutionMode.UNKNOWN)
        mode_value = mode.value if isinstance(mode, ExecutionMode) else "unknown"

        def observer(event: dict) -> None:
            # 실행 스레드에서 불린다. 줄 쓰기는 이벤트 루프로 넘긴다(순서 유지: 결과
            # 프레임보다 먼저 예약되므로 먼저 써진다).
            nonlocal counter
            counter += 1
            doc = {"type": "progress", "sequence_id": sequence_id, "n": counter, **event,
                   "execution_mode": mode_value, "t_monotonic_ns": time.monotonic_ns()}
            loop.call_soon_threadsafe(self._write_now, doc)

        setter(observer)
        return True

    def _detach_progress(self) -> None:
        setter = getattr(self._controller, "set_press_observer", None)
        if callable(setter):
            setter(None)

    def _write_now(self, doc: dict) -> None:
        """이벤트 루프 스레드에서 한 줄을 즉시 쓰고 drain은 뒤로 미룬다."""
        try:
            payload = self._encode(doc)
            if payload is None:
                return
            self._writer.write(payload)
        except Exception:  # noqa: BLE001 - 진행 보고 실패가 실행을 막지 않는다
            log.exception("progress frame write failed")
            return

        async def _drain() -> None:
            with contextlib.suppress(Exception):
                await self._writer.drain()

        task = asyncio.ensure_future(_drain())
        self._drain_tasks.add(task)
        task.add_done_callback(self._drain_tasks.discard)

    async def _execute_and_report(self, msg: ExecuteMsg, binding: "TargetBinding | None" = None) -> None:
        progress_on = self._attach_progress(msg.sequence_id)
        self._notify_job("job_start", {"sequence_id": msg.sequence_id, "buttons": list(msg.buttons),
                                       "progress": progress_on})
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
            self._notify_job("job_end", {"sequence_id": msg.sequence_id, "outcome": "error"})
            await self._send({
                "type": "error",
                "sequence_id": msg.sequence_id,
                "reason": "actuator_fail",
            })
            return
        finally:
            if progress_on:
                self._detach_progress()
            self._busy = False
            self._execute_task = None

        success = result.status is ExecutionStatus.SUCCEEDED
        retry = max((b.attempts - 1 for b in result.buttons), default=0)
        # success=false 하나로는 '정지 요청으로 멈춤'과 '검증 실패로 안전 정지'가
        # 구별되지 않았다. 종료 방식을 함께 보낸다(docs/protocol.md outcome).
        # success는 옛 RPi5와의 호환을 위해 그대로 둔다.
        outcome = outcome_of(result).value
        self._notify_job("job_end", {"sequence_id": msg.sequence_id, "outcome": outcome, "retry": retry})
        # 결과를 보내기 전에 대기를 연다 — 결과를 본 RPi5가 바로 보낸 정지(abort)가 대기를
        # 놓치지 않게 한다(대기 보고 프레임은 배경 스레드에서 결과 뒤에 나간다).
        self._maybe_start_hold(msg, result)

        await self._send({
            "type": "result",
            "sequence_id": msg.sequence_id,
            # 2026-10-07: 결과가 어느 대상의 것인지. RPi5가 보낸 대상과 다르면 RPi5가 오류로 본다.
            "appliance_id": msg.appliance_id,
            "success": success,
            "retry": retry,
            "outcome": outcome,
            # 2026-09-29: 버튼별 시도 수·보정, L3 판정, 실행 환경. 옛 RPi5는 무시한다.
            **result_detail_fields(result, self._controller),
            # 2026-10-14: 모션 걸림·재시작·기한 초과·준비 안 됨으로 재시도 없이 멈췄으면 그 원인. 없으면 필드 없음.
            **({"abort_reason": result.abort_reason} if getattr(result, "abort_reason", None) else {}),
        })
        after_result = binding.after_result if binding is not None else self._after_result
        self._active_after_result = after_result
        if after_result is not None:
            try:
                after_result(msg.sequence_id, result,
                                   self._frame_emitter(msg.sequence_id, "power_tail"))
            except Exception:  # noqa: BLE001 - 기록 훅 고장이 실행 보고를 막지 않게
                log.exception("after_result hook failed for %r", msg.sequence_id)
        log.info(
            "sequence %r finished — %s (retry=%d)",
            msg.sequence_id, outcome, retry,
        )

    # ── 정지 대기·보관·확인 주행(2026-09-30) ───────────────────────────────────

    def _mode_value(self) -> str:
        mode = getattr(self._controller, "execution_mode", ExecutionMode.UNKNOWN)
        return mode.value if isinstance(mode, ExecutionMode) else "unknown"

    def _frame_emitter(self, sequence_id: str, phase: str) -> "Callable[[dict], None]":
        loop = asyncio.get_running_loop()
        counter = itertools.count(1)
        mode_value = self._mode_value()

        def emit(event: dict) -> None:
            doc = {"type": "progress", "sequence_id": sequence_id, "n": next(counter), "phase": phase,
                   **event, "execution_mode": mode_value, "t_monotonic_ns": time.monotonic_ns()}
            try:
                loop.call_soon_threadsafe(self._write_now, doc)
            except RuntimeError:  # 루프가 닫힌 뒤(종료 중)
                log.debug("progress frame dropped after loop close: %s", phase)

        return emit

    def _maybe_start_hold(self, msg: ExecuteMsg, result: ExecutionResult) -> None:
        """시퀀스가 성공하고 가전이 동작 중이면(L3 확인 또는 모의) 정지 버튼 위로 가서 기다린다."""
        plan = msg.hold
        if plan is None or self._hold_hw is None:
            return
        if result.status is not ExecutionStatus.SUCCEEDED:
            return  # 정지·실패로 끝난 실행 뒤에는 움직이지 않는다
        emit = self._frame_emitter(msg.sequence_id, "hold")
        operation = result.operation
        confirmed = operation is not None and bool(operation.passed)
        mock = getattr(self._controller, "execution_mode", None) is ExecutionMode.MOCK
        if not (confirmed or mock):
            emit({"hold_state": None, "stop_outcome": None, "appliance_id": plan.appliance_id,
                  "stop_button": plan.stop_button,
                  "detail": "가전 동작이 확인되지 않아 작은 팔이 정지 버튼 위에서 기다리지 않아요"})
            return
        last = msg.targets.get(msg.buttons[-1]) if msg.targets else None
        start = (last.x_mm, last.y_mm) if last is not None else None
        session = StopHoldSession(plan, self._hold_hw.motion, self._hold_hw.probe_factory(plan), emit,
                                  timing=self._hold_hw.timing, start_position=start)
        self.hold_session = session
        session.start()

    async def _release_hold_for_new_run(self) -> bool:
        session = self.hold_session
        if session is None or not session.active:
            return True
        if not session.release():
            return False
        return await asyncio.to_thread(session.join, 3.0)

    def _close_hold(self) -> None:
        session = self.hold_session
        if session is not None and session.active:
            if not session.release():
                session.drive_stop()
            session.join(3.0)

    async def _on_verify_pass(self, msg: VerifyPassMsg) -> None:
        reason = detail = None
        unsafe = None if self._busy else self._unsafe_reason()
        if self._dev_running():
            reason, detail = "dev_busy", "개발자 조작이 진행 중이에요"
        elif unsafe is not None and unsafe[0] != "motion_not_ready":
            reason, detail = unsafe  # 비상정지 걸림·콘센트 무응답이면 확인 주행도 움직이지 않는다
        elif self._busy:
            reason, detail = "busy", "다른 동작을 실행하는 중이에요"
        elif self.hold_session is not None and self.hold_session.active:
            reason, detail = "hold_active", "가전이 동작 중이라 작은 팔이 정지 버튼 위에서 기다리는 중이에요"
        elif self._hold_hw is None:
            reason, detail = "verify_unavailable", "이 실행기에는 확인 주행용 모션이 연결되지 않았어요"
        if reason is not None:
            await self._send({"type": "error", "sequence_id": msg.sequence_id, "reason": reason,
                              "detail": detail})
            return
        self._busy = True
        self._verify_stop = False
        self._execute_task = asyncio.create_task(self._verify_and_report(msg))

    async def _verify_and_report(self, msg: VerifyPassMsg) -> None:
        emit = self._frame_emitter(msg.sequence_id, "verify")
        motion = self._hold_hw.motion  # type: ignore[union-attr]
        reset = getattr(motion, "reset_stop", None)
        if callable(reset):
            reset()
        try:
            results = await asyncio.to_thread(run_verify_pass, motion, list(msg.targets), emit,
                                              lambda: self._verify_stop)
        except Exception:
            log.exception("verify pass raised for %r", msg.sequence_id)
            await self._send({"type": "error", "sequence_id": msg.sequence_id, "reason": "actuator_fail"})
            return
        finally:
            self._busy = False
            self._execute_task = None
        await self._send({
            "type": "verify_result",
            "sequence_id": msg.sequence_id,
            "ok": all(r["status"] == "reached" for r in results),
            "targets": results,
            "execution_mode": self._mode_value(),
        })

    def _stop_after_result(self) -> None:
        stop = getattr(self._active_after_result, "stop", None)
        if callable(stop):
            try:
                stop()
            except Exception:  # noqa: BLE001
                log.exception("after_result stop failed")

    def set_outlet_readiness(self, fn: "Callable[[], str | None] | None") -> None:
        """콘센트 모듈 생존 확인 함수를 (다시) 꽂는다 — 생성자 ``outlet_readiness``와 같다."""
        self._outlet_readiness = fn

    def set_estop_reset(self, fn: "Callable[[], tuple[bool, str | None]] | None") -> None:
        """해제 확인 때 모듈 쪽 걸림을 푸는 함수(작업 스레드에서 불림). ``(풀렸나, 사유)``를 돌려준다."""
        self._estop_reset = fn

    def handle_outlet_estop(self, source: str = "button") -> None:
        """콘센트 모듈 물리 비상정지 — **이벤트 루프 스레드에서** 부른다.

        ``source``: ``button``(estop 이벤트) · ``ready``(재부팅 배너가 걸림을 보고) · ``status``(주기 조회가
        걸림을 보고). 모듈은 이미 스스로 가전 전원 릴레이를 열었다(호스트와 무관). 여기서는:
        - **호스트 걸림**(``estop_latched``)을 켠다 — ``estop_ack`` 전에는 execute·verify_pass를 거절한다.
        - 실행 중이면 ``abort``와 같은 협조적 정지(`ClosedLoopController.request_stop` — 모션 어댑터
          정지 명령도 즉시 나간다).
        - 정지 버튼 대기 중이면 **구동부 정지**(``drive_stop``) — 전원이 이미 끊겼으니 정지 버튼을 누르지
          않는다.
        - ``{"type":"alert","kind":"outlet_estop","source":…}``와 ``estop_state``를 보낸다.
        이미 걸린 상태에서 온 ready·status 보고는 같은 걸림의 재확인이라 다시 알리지 않는다(재부팅 걸림 위의
        보고는 예외 — 새 비상 버튼 걸림이다, B11).
        """
        already = self.estop_latched
        self.estop_latched = True
        if already and source != "button" and self.estop_source != "outlet_reboot":
            return  # 같은 걸림의 재확인 — 해제 확인 중이어도 '다시 걸림'으로 세지 않는다
        # 재부팅 걸림(outlet_reboot) 위에 온 모듈 보고는 새 비상 버튼 걸림이다 — 원인을 바꿔 '다시 켜져'(해제하면
        # 전원을 다시 켬) 문장이 남지 않게 한다(B11, 2026-10-15). 콘센트 링크도 같은 때 power_lost를 지운다.
        self._estop_gen += 1
        self.estop_source = source
        self.outlet_estops += 1
        log.warning("outlet E-STOP (source=%s) — appliance relay opened by the module; stopping drive",
                    source)
        session = self.hold_session
        if session is not None and session.active:
            session.drive_stop()
        self._stop_dev("outlet_estop")
        if self._busy:
            self._verify_stop = True
            request_stop = getattr(self._controller, "request_stop", None)
            if request_stop is not None:
                request_stop()
            else:
                log.warning("outlet estop mid-execution — controller has no request_stop hook")
        self._write_now({"type": "alert", "kind": "outlet_estop", "source": source,
                         "t_monotonic_ns": time.monotonic_ns()})
        self._write_now(self._estop_state_doc())

    def handle_outlet_power_lost(self, source: str = "ready") -> None:
        """콘센트 모듈이 다시 켜져 켜 두었던 릴레이가 꺼졌다 — **이벤트 루프 스레드에서** 부른다(2026-10-06 평가 A4).

        안전 쪽: 자동으로 다시 켜지 않는다. 비상정지와 같은 호스트 걸림(``source:"outlet_reboot"``)으로 두고
        사람의 해제 확인(``estop_ack`` = RPi5 ``POST /stop/ack``) 뒤에만 켠다(`OutletLink.acknowledge_and_restore`).
        실행 중이면 멈춘다(가전 전원이 없으니 누름이 의미 없다). 이미 걸려 있으면 원인을 덮어쓰지 않는다.
        """
        if self.estop_latched:
            return
        self.estop_latched = True
        self._estop_gen += 1
        self.estop_source = "outlet_reboot"
        log.error("outlet module restarted (%s) — relay OFF, latched until operator acknowledgement", source)
        self._stop_dev("outlet_reboot")
        if self._busy:
            self._verify_stop = True
            request_stop = getattr(self._controller, "request_stop", None)
            if request_stop is not None:
                request_stop()
        self._write_now(self._estop_state_doc())

    def emergency_stop_sync(self, source: str = "button") -> None:
        """이벤트 루프가 닫힌 뒤 온 비상정지(Copilot#2) — 어느 스레드에서든 부를 수 있는 안전 쪽 대체 경로.

        프레임은 보내지 못하지만(루프 없음) 호스트 걸림을 켜고 구동부 정지를 **동기로** 요청한다.
        ``request_stop``(협조적 정지 플래그 + 모션 어댑터 정지)과 정지 대기의 ``drive_stop``을 바로 부른다.
        """
        self.estop_latched = True
        self.estop_source = source
        self._verify_stop = True
        try:
            self._stop_dev("sync_estop")
        except Exception:  # noqa: BLE001 - 대체 경로는 가능한 것을 다 한다
            log.exception("sync emergency stop: dev motion stop failed")
        request_stop = getattr(self._controller, "request_stop", None)
        if request_stop is not None:
            try:
                request_stop()
            except Exception:  # noqa: BLE001 - 대체 경로는 가능한 것을 다 한다
                log.exception("sync emergency stop: request_stop failed")
        session = self.hold_session
        if session is not None and session.active:
            try:
                session.drive_stop()
            except Exception:  # noqa: BLE001
                log.exception("sync emergency stop: drive_stop failed")

    def _latch_detail(self) -> str:
        return POWER_LOST_LATCH_DETAIL if self.estop_source == "outlet_reboot" else ESTOP_LATCHED_DETAIL

    def _estop_state_doc(self, reason: str | None = None) -> dict:
        detail = ESTOP_REASON_DETAIL.get(reason) if reason else None
        if detail is None and self.estop_latched:
            detail = self._latch_detail()
        return {"type": "estop_state", "latched": self.estop_latched, "source": self.estop_source,
                "reason": reason, "detail": detail}

    def _start_estop_ack(self) -> None:
        """해제 확인을 따로 돈다(2026-10-06 평가 C2) — 모듈 응답을 기다리는 동안에도 읽기 루프가 abort를 처리한다.
        이미 처리 중이면 같은 확인으로 본다(두 번 보내지 않는다 — 결과 estop_state는 한 번 간다)."""
        if self._ack_task is not None and not self._ack_task.done():
            log.info("estop_ack already in progress — ignored duplicate")
            return
        self._ack_task = asyncio.create_task(self._on_estop_ack())

    async def wait_ack(self) -> None:
        """진행 중인 해제 확인이 끝날 때까지(시험·종료 절차용)."""
        task = self._ack_task
        if task is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await task

    async def _on_estop_ack(self) -> None:
        """사람의 비상정지 해제 확인. 모듈 버튼이 아직 눌려 있으면(또는 모듈이 답하지 않으면) 풀지 않는다.

        읽기 루프와 따로 돈다(`_start_estop_ack`) — 모듈 응답을 기다리는 사이 abort·hello가 막히지 않는다.
        """
        reason: str | None = None
        if self.estop_latched:
            gen = self._estop_gen
            ok = True
            if self._estop_reset is not None:
                try:
                    ok, reason = await asyncio.to_thread(self._estop_reset)
                except Exception:  # noqa: BLE001 - 모듈 고장은 '풀지 못함'으로
                    log.exception("outlet estop reset failed")
                    ok, reason = False, "outlet_unreachable"
            if ok and gen != self._estop_gen:
                ok, reason = False, "estop_retriggered"
            if ok:
                self.estop_latched = False
                self.estop_source = None
                log.warning("outlet E-STOP latch cleared by operator acknowledgement")
            else:
                log.warning("outlet E-STOP acknowledgement refused: %s", reason)
        await self._send(self._estop_state_doc(reason))

    # ── 연결 알림·리허설(2026-10-06) ─────────────────────────────────────────

    def set_rehearsal(self, hooks: object | None) -> None:
        """리허설 주입 부품을 꽂는다(act_main: 가짜 콘센트·모의 모션일 때만). None이면 rehearsal을 거절한다."""
        self._rehearsal = hooks

    def _announce(self) -> None:
        """``act_info``와 ``estop_state``를 보낸다 — RPi5가 (다시) 연결했거나 RPi4가 막 켜졌을 때."""
        info = {"type": "act_info", "done_watch": [], "execute_protocol": EXECUTE_PROTOCOL, **self.act_info,
                "rehearsal": self._rehearsal is not None, "stop_report_protocol": STOP_REPORT_PROTOCOL,
                # 사건 신선도 기준점 규약(3차 평가 M1): clock_probe에 clock_ref로 답한다.
                "clock_protocol": CLOCK_PROTOCOL}
        if self._dev_motion is not None:
            # 실제 모션 어댑터가 물렸을 때만 — RPi5는 이 값이 없으면 개발자 조작을 보내지 않는다(2026-10-10).
            info["dev_motion_protocol"] = DEV_MOTION_PROTOCOL
        self._write_now(info)
        # announce: 해제 확인(estop_ack)의 답이 아니라 상태 알림이다 — RPi5가 대기 중인 확인으로 착각하지 않게.
        self._write_now({**self._estop_state_doc(), "announce": True})

    async def _on_rehearsal(self, msg: RehearsalMsg) -> None:
        hooks = self._rehearsal
        if hooks is None:
            log.warning("rehearsal %s refused — real outlet/motion attached", msg.action)
            await self._send({"type": "rehearsal_result", "request_id": msg.request_id, "ok": False,
                              "reason": "rehearsal_refused", "detail": REHEARSAL_REFUSED_DETAIL})
            return
        reply: dict = {"type": "rehearsal_result", "request_id": msg.request_id, "ok": True,
                       "action": msg.action, "source": "injected"}
        try:
            if msg.action == "outlet_estop":
                hooks.outlet_estop(self, msg.hold_button)  # type: ignore[attr-defined]
            elif msg.action == "outlet_estop_release":
                hooks.release_button(self)  # type: ignore[attr-defined]
            else:
                reply["frame"] = self.inject_appliance_done(msg.appliance_id, list(msg.inputs), msg.event)
        except Exception as exc:  # noqa: BLE001 - 주입 실패는 결과로 알린다
            log.exception("rehearsal %s failed", msg.action)
            reply = {"type": "rehearsal_result", "request_id": msg.request_id, "ok": False,
                     "reason": "rehearsal_failed", "detail": str(exc)}
        await self._send(reply)

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

    def _on_abort(self, msg: AbortMsg | None = None) -> None:
        # A physical E-STOP is authoritative and out of band from this UART
        # link (see rpi/controller/ports.py SafetyController docstring).
        # ClosedLoopController.request_stop()이 협조적 취소를 지원한다:
        # 실행 스레드가 버튼 사이/재시도 경계에서 플래그를 확인하고
        # SAFETY_STOPPED로 종료하면, 그 result가 RPi5에 정상 회신된다 —
        # 폰/키오스크의 긴급 정지가 UART 모드에서도 끝단까지 완결되는 지점.
        scope = msg.scope if msg is not None else "appliance"
        stop_id = msg.stop_id if msg is not None else None
        target, probe = self._abort(scope)
        run_ref = msg.run_ref if msg is not None else None
        if target == "idle" and run_ref is not None:
            # 실행 시작 전에 온 정지(2026-10-15 G2) — 그 실행의 execute가 뒤이어 와도 누르지 않게 기억한다.
            log.warning("abort for run %s received before its execute — remembering it", run_ref)
            self._aborted_run_ref = run_ref
        if stop_id is not None:
            # 정지는 위에서 이미 나갔다 — 확인 단계만 따로 기다렸다 보고한다(읽기 루프를 막지 않는다).
            self._spawn_stop_task(self._report_stop(stop_id, target, probe))

    def _abort(self, scope: str) -> "tuple[str, Callable[[], StopReport] | str | None]":
        """정지를 보내고 (보고 대상, 확인 방법)을 돌려준다. 확인 방법은 ``confirm_stop`` 함수, 고정 단계 문자열,
        또는 None(멈출 것이 없었다)."""
        if self._dev_running():
            # 일반 정지(abort)도 진행 중인 개발자 조작을 멈춘다 — RPi5 /stop이 개발자 정지와 함께 보낸다.
            log.warning("abort received during a developer motion op — sending MCU stop")
            assert self._dev_motion is not None
            before = self._dev_motion.last_stop_id
            self._stop_dev("abort")
            return "dev", self._bound_probe(self._dev_motion, before)
        session = self.hold_session
        if not self._busy and session is not None and session.active:
            # 정지 버튼 위 대기 중: 가전 정지(정지 버튼 누름). drive면 구동부만 멈춘다(누르지 않음).
            if scope == "drive":
                log.warning("drive stop received while holding — stopping motion, no stop press")
                before = self._motion_stop_id()
                session.drive_stop()
                return "hold", self._motion_probe(before)
            log.warning("stop received while holding — pressing the appliance stop button: %s",
                        session.request_appliance_stop())
            # 가전 정지 결과는 정지 대기 보고(progress phase "hold"의 stop_outcome)가 따로 알린다.
            return "hold", None
        if self._busy:
            self._verify_stop = True
            request_stop = getattr(self._controller, "request_stop", None)
            if request_stop is not None:
                log.warning("abort received mid-execution — requesting cooperative stop")
                before = self._motion_stop_id()
                request_stop()
                return "run", self._motion_probe(before)
            log.warning(
                "abort received mid-execution — controller has no request_stop hook"
            )
            return "run", None
        log.info("abort received while idle — nothing to cancel")
        return "idle", None

    def _motion_stop_id(self) -> int | None:
        """실제 모션 어댑터가 마지막으로 보낸 MCU 정지 id(없으면 None) — 정지 전송 직전에 읽어 둔다."""
        return getattr(self._motion_stop, "last_stop_id", None)

    def _motion_probe(self, before: int | None) -> "Callable[[], StopReport] | str":
        """실제 모션 어댑터가 있으면 이번에 보낸 MCU 정지에 묶은 ``confirm_stop``, 없으면(모의 모션) ``sent``."""
        if self._motion_stop is None:
            return "sent"
        return self._bound_probe(self._motion_stop, before)

    @staticmethod
    def _bound_probe(motion: object, before: int | None) -> "Callable[[], StopReport] | str":
        """정지 전송 직후 ``motion.last_stop_id``로 **이번 정지의 불변 id**를 얻어 확인 함수에 묶는다(2차 평가 M-N2).

        정지 전송은 이 이벤트 루프 안에서 동기로 끝나므로 직후의 id가 이번 정지다. 확인하는 사이 다른 abort가 MCU
        정지를 또 보내도 이 확인은 자기 정지의 기록만 돌려준다. 이번 요청이 MCU 정지를 쓰지 않았으면(id가 그대로)
        다른 정지의 기록을 빌려 오지 않고 넘긴 것까지(``sent``)만 말한다."""
        confirm = getattr(motion, "confirm_stop", None)
        if not callable(confirm):
            return "sent"
        after = getattr(motion, "last_stop_id", None)
        if after is None or after == before:
            return "sent"
        return functools.partial(confirm, stop_id=after)

    async def _confirm(self, probe: "Callable[[], StopReport] | str | None") -> dict:
        """확인 방법을 돌려 ``{"stop_level", "ack_ms"(, "stop_detail")}``. 실패해도 예외를 내지 않는다."""
        if probe is None:
            return {"stop_level": None, "ack_ms": None}
        if isinstance(probe, str):
            return {"stop_level": probe, "ack_ms": None}
        try:
            report = await asyncio.to_thread(probe)
        except Exception as exc:  # noqa: BLE001 - 확인 실패는 '보냄'까지만으로 낮춘다
            log.exception("stop confirmation failed")
            return {"stop_level": "sent", "ack_ms": None, "stop_detail": f"정지 확인 중 오류: {exc}"}
        return report.fields()

    async def _report_stop(self, stop_id: str, target: str, probe) -> None:
        fields = await self._confirm(probe)
        log.warning("stop report %s: target=%s level=%s ack_ms=%s", stop_id, target,
                    fields.get("stop_level"), fields.get("ack_ms"))
        await self._send({"type": "stop_report", "stop_id": stop_id, "target": target, **fields})

    def _spawn_stop_task(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._stop_tasks.add(task)
        task.add_done_callback(self._stop_tasks.discard)

    # ── 개발자 조작(2026-10-10) ──────────────────────────────────────────────

    def _dev_running(self) -> bool:
        return self._dev_task is not None and not self._dev_task.done()

    def _stop_dev(self, reason: str) -> None:
        """진행 중인 개발자 조작이 있으면 MCU 정지를 보낸다(없으면 아무것도 하지 않는다)."""
        if self._dev_motion is not None and self._dev_running():
            self._dev_motion.stop(reason)

    async def wait_dev(self) -> None:
        """진행 중인 개발자 조작과 정지 확인 보고가 끝날 때까지(시험·종료 절차용)."""
        task = self._dev_task
        if task is not None:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        while self._stop_tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await asyncio.gather(*list(self._stop_tasks), return_exceptions=True)
            # 끝난 태스크를 집합에서 빼는 완료 콜백이 돌 틈을 준다 — 모두 끝난 gather는 루프에 양보하지 않아 여기서 돈다.
            await asyncio.sleep(0)

    def _dev_refusal(self) -> tuple[str, str] | None:
        """개발자 조작을 시작하면 안 되는 이유 (reason, detail). 순서: 미지원 → 비상정지·콘센트·모션 준비 →
        일반 실행·정지 대기 → 다른 개발자 조작."""
        if self._dev_motion is None:
            return ("dev_unsupported",
                    "이 RPi4는 실제 모션 어댑터가 없어 개발자 조작을 받지 않아요(SIMPLELAY_MOTION_MODE=serial)")
        unsafe = self._unsafe_reason()
        if unsafe is not None:
            return unsafe
        if self._busy:
            return "execution_busy", "일반 실행이나 확인 주행이 진행 중이에요"
        if self.hold_session is not None and self.hold_session.active:
            return "execution_busy", "가전 정지 버튼 위에서 기다리는 중이에요 — 정지 뒤에 조작해 주세요"
        if self._dev_running():
            return "dev_busy", "이전 개발자 조작이 아직 끝나지 않았어요"
        return None

    async def _on_dev_motion(self, msg: DevMotionMsg) -> None:
        base = {"type": "dev_motion_result", "request_id": msg.request_id, "op": msg.op}
        if msg.op == "stop":
            # 정지는 어떤 거절에도 걸리지 않는다 — 걸림·실행 중이어도 MCU stop을 보낸다.
            if self._dev_motion is None:
                await self._send({**base, "ok": False, "reason": "dev_unsupported",
                                  "detail": "개발자 조작을 받지 않는 RPi4예요", "moved": False})
                return
            before = self._dev_motion.last_stop_id
            sent = self._dev_motion.stop(msg.reason or "dev_stop")
            reply = {**base, "ok": bool(sent)}
            if not sent:
                reply.update(reason="stop_send_failed",
                             detail="모션 보드에 정지를 보내지 못했어요 — 물리 비상정지를 눌러 주세요",
                             stop_level=None, ack_ms=None)
                await self._send(reply)
                return
            # 정지 줄은 이미 나갔다. MCU 확인·멈춤 확인은 따로 기다렸다 답한다(규약 2, 2026-10-13).
            self._spawn_stop_task(self._reply_dev_stop(reply, self._bound_probe(self._dev_motion, before)))
            return
        refusal = self._dev_refusal()
        if refusal is not None:
            reason, detail = refusal
            log.warning("dev_motion %s %r refused — %s: %s", msg.op, msg.request_id, reason, detail)
            await self._send({**base, "ok": False, "reason": reason, "detail": detail, "moved": False})
            return
        self._dev_task = asyncio.create_task(self._run_dev(msg, base))

    async def _reply_dev_stop(self, reply: dict, probe) -> None:
        await self._send({**reply, **await self._confirm(probe)})

    async def _run_dev(self, msg: DevMotionMsg, base: dict) -> None:
        service = self._dev_motion
        assert service is not None
        try:
            fields = await asyncio.to_thread(service.run, msg)
        except Exception as exc:  # noqa: BLE001 - run은 예외를 내지 않지만 실행기 루프를 지킨다
            log.exception("dev_motion %s crashed", msg.op)
            fields = {"ok": False, "reason": "motion_error", "detail": str(exc), "moved": None}
        await self._send({**base, **fields})

    # ── IO helper ────────────────────────────────────────────────────────────

    async def _send(self, doc: dict) -> None:
        payload = self._encode(doc)
        if payload is None:
            return
        log.debug("TX -> %s", payload.rstrip().decode())
        self._writer.write(payload)
        await self._writer.drain()

    # ── 링크 인증(2026-10-12) ───────────────────────────────────────────────────

    def _authentic(self, raw: str) -> bool:
        """키가 있을 때: 받은 줄이 올바른 hello이거나 지금 세션의 서명·``seq``가 맞는지."""
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            return False
        return isinstance(doc, dict) and self._auth.open(doc) is not None  # type: ignore[union-attr]

    def _encode(self, doc: dict) -> bytes | None:
        """보낼 줄. 키가 있으면 봉투를 씌우고(서명·``seq``), 세션이 아직 없으면 None(보내지 않는다).
        이벤트 루프 스레드에서만 부르고 곧바로 쓴다 — ``seq`` 순서가 줄 순서와 같아야 한다."""
        if self._auth is not None:
            sealed = self._auth.seal(doc)
            if sealed is None:
                log.debug("link auth: no session yet — %s not sent", doc.get("type"))
                return None
            doc = sealed
        return (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
