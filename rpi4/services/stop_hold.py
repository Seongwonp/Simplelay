"""정지 버튼 대기·보관 — 실행기(RPi4) 쪽 절반. **모의로만 검증, 실물 미검증** (2026-09-30).

버튼 시퀀스가 끝나고 가전이 동작 중이면(L3 확인 또는 모의) 캐리지는 Z를 올린 채 정지 버튼
위로 가서 기다린다. 그동안 정지 요청(폰·키오스크·음성 모두 ``POST /stop`` → ``abort``)이
오면 정지 버튼을 등록한 횟수만큼 누르고, **전력이 떨어져야**(모의에서는 모의 가전이 꺼져야)
"정지됨"으로 판정한다. 가전이 끝나면 보관 위치로 간다.

상태 기계는 새로 만들지 않는다. 9/27 모의 모델 ``rpi4.parking_simulator.ParkingSimulator``를
그대로 쓰고(좌표만 mm, 보관 모서리 ``free``), 이 모듈은 그 모델이 내는 동작
(retract·move·press_stop)을 모션 포트로 수행한 뒤 응답을 돌려준다. 모델의 규칙이 그대로
살아 있다 — Z 복귀 근거 없이 XY 이동 안 함, 정지 버튼 중복 누름 없음, 동작 실패·구동부
정지는 잠금(자동 재가동·자동 보관 없음), 누름 확인과 가전 정지 확인은 별개.

**가전 정지 ≠ 구동부 비상정지.** ``request_appliance_stop``은 정지 버튼을 누른다.
``drive_stop``은 모션을 멈추고(누르지 않음) 잠근다. 구동부가 잠겼거나 누르다 실패하면
정지 결과는 ``drive_fault``("버튼으로 가전을 멈추지 못함")다.

``run_verify_pass``: 확인 주행 — Z를 올린 채 좌표 위를 차례로 지나간다. 누르지 않는다.
실제 어댑터에서는 ``SerialMotionClient.move_to``만 쓴다.

시간 값(확인 창·최대 대기·연속 누름 간격)은 전부 **설계 초기값**이다(추측/측정 필요).
"""

from __future__ import annotations

import itertools
import logging
import math
import os
import threading
import time
from collections.abc import Callable, Mapping as MappingABC, Sequence
from dataclasses import dataclass, field
from typing import Any, Protocol

from rpi.controller.models import ExecutionMode, PressCommand
from rpi4.models.act_messages import HoldPlan, VerifyTarget
from rpi4.parking_simulator import Mapping, MmPoint, ParkingSimulator, Phase

log = logging.getLogger(__name__)

#: 화면·/status에 나가는 대기 상태. None은 대기 없음.
HOLD_STATES = ("hovering_stop", "stopping", "parking", "parked", "fault", "released")
#: 정지 요청 결과. None은 요청 없음.
STOP_OUTCOMES = ("stopped", "requested_unconfirmed", "drive_fault")

DETAIL_STOPPED = "가전이 멈춘 것을 확인했어요 — 작은 팔이 정지 버튼을 누른 뒤 가전 전력이 떨어졌어요"
DETAIL_STOPPED_MOCK = "연습 결과 — 작은 팔이 정지 버튼을 짚은 뒤 연습용 가전이 꺼졌어요(실제 가전 아님)"
DETAIL_STOPPED_LATE = ("작은 팔이 정지 버튼을 누르고 확인 시간이 지난 뒤에 가전 전력이 떨어졌어요 — 가전이 "
                       "스스로 끝났을 수도 있어요")
DETAIL_UNCONFIRMED = ("가전이 멈췄는지 확인하지 못했어요 — 작은 팔이 정지 버튼을 {n}번 눌렀지만 가전 전력이 "
                      "떨어진 것을 확인하지 못했어요. 가전을 직접 확인해 주세요")
DETAIL_DRIVE_FAULT = "작은 팔에 이상이 생겨 정지 버튼을 누르지 못했어요 — 가전 전원을 직접 꺼 주세요"
DETAIL_DRIVE_STOPPED = "작은 팔을 멈췄어요 — 정지 버튼 위에서 기다리기를 끝냈어요. 가전은 직접 확인해 주세요"
PARK_DETAILS = {
    "appliance_finished": "가전 전력이 떨어져 작은 팔이 제자리로 돌아갔어요",
    "stop_confirmed": "가전이 멈춰 작은 팔이 제자리로 돌아갔어요",
    "hold_timeout": "최대 대기 시간이 지나 작은 팔이 제자리로 돌아갔어요(가전이 끝났는지는 확인하지 못했어요)",
}


class HoldMotionUnavailable(RuntimeError):
    """이 모션 어댑터로는 누르지 않고 이동할 수 없다."""


class HoldMotion(Protocol):
    execution_mode: ExecutionMode

    def move_to(self, x_mm: float, y_mm: float) -> None: ...
    def press_at(self, button: str, x_mm: float, y_mm: float, press_ms: int | None) -> None: ...
    def retract(self) -> None: ...
    def request_stop(self) -> None: ...


class MockHoldMotion:
    """하드웨어 없는 모션 — 명령을 기록만 한다. ``fault``를 채우면 다음 동작이 실패한다."""

    execution_mode = ExecutionMode.MOCK

    def __init__(self, step_seconds: float = 0.0, sleep: Callable[[float], None] = time.sleep) -> None:
        self.step_seconds = step_seconds
        self._sleep = sleep
        self.log: list[tuple] = []
        self.fault: str | None = None
        self._stopped = threading.Event()
        self._lock = threading.Lock()

    def _check(self, what: str) -> None:
        if self._stopped.is_set():
            raise RuntimeError(f"{what}: 구동부 정지 요청 중(모의)")
        if self.fault:
            raise RuntimeError(f"{what}: {self.fault}")

    def _pause(self) -> None:
        if self.step_seconds > 0:
            # 정지 요청이 오면 기다림을 끊는다(모의 이동 중 정지).
            self._stopped.wait(self.step_seconds)

    def move_to(self, x_mm: float, y_mm: float) -> None:
        self._check("XY 이동")
        self._pause()
        self._check("XY 이동")
        with self._lock:
            self.log.append(("move", float(x_mm), float(y_mm)))

    def press_at(self, button: str, x_mm: float, y_mm: float, press_ms: int | None) -> None:
        self._check(f"'{button}' 누름")
        self._pause()
        with self._lock:
            self.log.append(("press", button, float(x_mm), float(y_mm)))

    def retract(self) -> None:
        self._check("Z 복귀")
        with self._lock:
            self.log.append(("retract",))

    def request_stop(self) -> None:
        self._stopped.set()

    def reset_stop(self) -> None:
        self._stopped.clear()

    def moves(self) -> list[tuple[float, float]]:
        with self._lock:
            return [(e[1], e[2]) for e in self.log if e[0] == "move"]

    def presses(self) -> list[str]:
        with self._lock:
            return [e[1] for e in self.log if e[0] == "press"]


class GrblHoldMotion:
    """실제 모션 어댑터(SerialMotionClient)용. **실물 미검증.**

    - 이동은 어댑터의 ``move_to``만 쓴다(누르지 않는다). 없으면 거절한다 — ``press``로
      이동을 흉내 내면 누름이 따라온다.
    - 누름은 ``press(PressCommand)`` — 어댑터가 이동→누름→복귀까지 끝나야 응답한다.
      스위치봇 Z 모듈은 시간 누름(``press_mode=duration``)이라 깊이 값이 없다.
    - Z 복귀는 별도 명령이 없다: 누름 응답이 복귀까지 포함한다.
    """

    def __init__(self, press_client: Any, move_client: Any | None = None) -> None:
        self._press = press_client
        self._move = move_client if move_client is not None else press_client
        mode = getattr(press_client, "execution_mode", ExecutionMode.UNKNOWN)
        self.execution_mode = mode if isinstance(mode, ExecutionMode) else ExecutionMode.UNKNOWN

    def move_to(self, x_mm: float, y_mm: float) -> None:
        move = getattr(self._move, "move_to", None)
        if not callable(move):
            raise HoldMotionUnavailable("이 모션 어댑터에는 누르지 않고 이동하는 명령(move_to)이 없어요")
        move(x_mm, y_mm)

    def press_at(self, button: str, x_mm: float, y_mm: float, press_ms: int | None) -> None:
        self._press.press(PressCommand(button, x_mm=x_mm, y_mm=y_mm, press_ms=press_ms))

    def retract(self) -> None:
        state = getattr(self._move, "state", None)
        value = getattr(state, "value", state)
        if value in ("alarm", "stopped"):
            raise RuntimeError(f"구동부 상태가 {value}라 Z 복귀를 확인할 수 없어요")

    def request_stop(self) -> None:
        stop = getattr(self._move, "request_stop", None)
        if callable(stop):
            stop()


class ApplianceRunProbe(Protocol):
    #: "mock" | "real" | "none"
    source: str

    def start(self) -> None: ...
    def running(self) -> bool | None: ...
    def note_stop_presses(self, count: int) -> None: ...


class MockApplianceRun:
    """모의 가전 — ``run_seconds`` 동안 켜져 있다가 꺼진다. 정지 버튼을 ``presses_needed``번
    눌리면(``honors_stop``) 바로 꺼진다. 실제 전력 근거가 아니다."""

    source = "mock"

    def __init__(self, run_seconds: float = 30.0, *, honors_stop: bool = True, presses_needed: int = 1,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.run_seconds = run_seconds
        self.honors_stop = honors_stop
        self.presses_needed = presses_needed
        self._clock = clock
        self._t0: float | None = None
        self._off = False
        self.presses_seen = 0

    def start(self) -> None:
        self._t0 = self._clock()

    def running(self) -> bool | None:
        if self._off:
            return False
        if self._t0 is not None and self._clock() - self._t0 >= self.run_seconds:
            return False
        return True

    def note_stop_presses(self, count: int) -> None:
        self.presses_seen += count
        if self.honors_stop and self.presses_seen >= self.presses_needed:
            self._off = True


class NoRunProbe:
    """전력(CT) 리더가 아직 없다 — 켜짐/꺼짐을 모른다(None). 정지는 '미확인'으로만 끝난다."""

    source = "none"

    def start(self) -> None:
        return None

    def running(self) -> bool | None:
        return None

    def note_stop_presses(self, count: int) -> None:
        return None


def _env_float(env: MappingABC[str, str], name: str, default: float) -> float:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not math.isfinite(value) or value < 0:
        raise RuntimeError(f"{name}는 0 이상의 유한한 수여야 합니다: {raw!r}")
    return value


@dataclass(frozen=True)
class HoldTiming:
    """설계 초기값 — CT 응답 지연·가전 반응 실측 뒤 조정(추측/측정 필요)."""

    #: 상태 확인 주기(초).
    poll_s: float = 0.2
    #: 정지 버튼을 누른 뒤 전력이 떨어지기를 기다리는 시간(초). 지나면 '미확인'.
    stop_confirm_s: float = 5.0
    #: 정지 버튼 위 최대 대기(초). 지나면 보관 위치로 간다(종료 미확인으로 기록).
    max_hold_s: float = 1800.0
    #: 연속 누름 사이 간격(초) — 전자레인지 '2번=취소'가 한 번으로 읽히지 않게.
    press_gap_s: float = 0.6

    @classmethod
    def from_env(cls, env: MappingABC[str, str] | None = None) -> "HoldTiming":
        src = os.environ if env is None else env
        base = cls()
        return cls(
            poll_s=base.poll_s,
            stop_confirm_s=_env_float(src, "SIMPLELAY_HOLD_STOP_CONFIRM_S", base.stop_confirm_s),
            max_hold_s=_env_float(src, "SIMPLELAY_HOLD_MAX_S", base.max_hold_s),
            press_gap_s=_env_float(src, "SIMPLELAY_HOLD_PRESS_GAP_S", base.press_gap_s),
        )


@dataclass
class HoldHardware:
    """실행기가 정지 대기에 쓰는 부품 묶음."""

    motion: Any
    probe_factory: Callable[[HoldPlan], Any]
    timing: HoldTiming = field(default_factory=HoldTiming)


def mock_hold_hardware(step_seconds: float = 0.0, env: MappingABC[str, str] | None = None,
                       motion: MockHoldMotion | None = None) -> HoldHardware:
    """모의 모션 + 모의 가전. ``SIMPLELAY_HOLD_MOCK_RUN_S``(기본 30초)·
    ``SIMPLELAY_HOLD_MOCK_STOP``(honor | ignore — ignore면 정지 버튼에 반응하지 않는 가전)."""
    src = os.environ if env is None else env
    run_s = _env_float(src, "SIMPLELAY_HOLD_MOCK_RUN_S", 30.0)
    honors = (src.get("SIMPLELAY_HOLD_MOCK_STOP") or "honor").strip().lower() != "ignore"
    return HoldHardware(
        motion=motion or MockHoldMotion(step_seconds),
        probe_factory=lambda plan: MockApplianceRun(run_s, honors_stop=honors,
                                                    presses_needed=plan.stop_presses),
        timing=HoldTiming.from_env(src),
    )


def real_hold_hardware(press_client: Any, move_client: Any | None = None,
                       env: MappingABC[str, str] | None = None,
                       probe_factory: Callable[[HoldPlan], Any] | None = None) -> HoldHardware:
    """실제 모션 어댑터 + 가전 켜짐 확인. ``probe_factory``가 없으면 전력 리더 없음(NoRunProbe) —
    정지는 '미확인'으로만 끝난다. 콘센트 모듈이 있으면 act_main이 `OutletRunProbe`를 넘긴다."""
    return HoldHardware(GrblHoldMotion(press_client, move_client),
                        probe_factory or (lambda plan: NoRunProbe()), HoldTiming.from_env(env))


_TERMINAL = ("parked", "fault", "released")


class StopHoldSession:
    """한 번의 정지 대기. 배경 스레드 하나가 상태 기계를 **혼자** 움직인다 —
    바깥 호출(정지·구동부 정지·해제)은 표시만 남기고 깨운다."""

    def __init__(
        self,
        plan: HoldPlan,
        motion: Any,
        probe: Any,
        emit: Callable[[dict], None],
        *,
        timing: HoldTiming | None = None,
        start_position: tuple[float, float] | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.plan = plan
        self._motion = motion
        self._probe = probe
        self._emit_fn = emit
        self._timing = timing or HoldTiming()
        self._clock = clock
        self._sleep = sleep
        self._sim = ParkingSimulator(Mapping(MmPoint(plan.stop_x_mm, plan.stop_y_mm),
                                             MmPoint(plan.park_x_mm, plan.park_y_mm), "free"))
        self._start_position = start_position
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop_flag = False
        self._stop_handled = False
        self._drive_flag = False
        self._release_flag = False
        self._stop_requested_at: float | None = None
        self.state: str | None = None
        self.stop_outcome: str | None = None
        self.detail: str | None = None
        self.park_reason: str | None = None
        self.presses_done = 0
        self.target: tuple[float, float] | None = None
        self._thread = threading.Thread(target=self._run, daemon=True, name="stop-hold")

    # ── 바깥 호출 ─────────────────────────────────────────────────────────────

    def start(self) -> None:
        with self._lock:
            self.state = "hovering_stop"
        self._thread.start()

    @property
    def active(self) -> bool:
        with self._lock:
            return self.state is not None and self.state not in _TERMINAL

    def request_appliance_stop(self) -> str:
        """정지 버튼 누름 요청. ``accepted`` | ``duplicate``(이미 처리 중·처리함) | ``not_holding``."""
        with self._lock:
            if self.state is None or self.state in _TERMINAL:
                return "not_holding"
            if self._stop_flag:
                return "duplicate"
            self._stop_flag = True
        self._wake.set()
        return "accepted"

    def drive_stop(self) -> None:
        """구동부 정지 — 누르지 않는다. 진행 중 이동도 끊는다."""
        with self._lock:
            self._drive_flag = True
        try:
            self._motion.request_stop()
        except Exception:  # noqa: BLE001 - 정지 경로에서 호출자를 죽이지 않는다
            log.exception("hold drive stop failed — physical E-STOP is the final authority")
        self._wake.set()

    def release(self) -> bool:
        """새 실행을 위해 대기를 푼다. 누르거나 보관 이동 중이면 False."""
        with self._lock:
            if self.state in ("stopping", "parking"):
                return False
            if self.state is None or self.state in _TERMINAL:
                return True
            self._release_flag = True
        self._wake.set()
        return True

    def join(self, timeout: float | None = None) -> bool:
        if self._thread.is_alive():
            self._thread.join(timeout)
        return not self._thread.is_alive()

    def snapshot(self) -> dict:
        with self._lock:
            return self._view()

    # ── 배경 스레드 ───────────────────────────────────────────────────────────

    def _view(self, **extra: object) -> dict:
        plan = self.plan
        doc = {
            "hold_state": self.state,
            "stop_outcome": self.stop_outcome,
            "detail": self.detail,
            "stop_button": plan.stop_button,
            "stop_presses": plan.stop_presses,
            "presses_done": self.presses_done,
            "stop": {"x_mm": plan.stop_x_mm, "y_mm": plan.stop_y_mm},
            "park": {"x_mm": plan.park_x_mm, "y_mm": plan.park_y_mm},
            "target": None if self.target is None else {"x_mm": self.target[0], "y_mm": self.target[1]},
            "park_reason": self.park_reason,
            "appliance_id": plan.appliance_id,
            "probe_source": getattr(self._probe, "source", "none"),
            "sim_phase": self._sim.phase.value,
        }
        doc.update(extra)
        return doc

    def _set(self, state: str, detail: str | None = None, **extra: object) -> None:
        with self._lock:
            self.state = state
            if detail is not None:
                self.detail = detail
            doc = self._view(**extra)
        try:
            self._emit_fn(doc)
        except Exception:  # noqa: BLE001 - 보고 실패가 대기를 막지 않는다
            log.exception("hold progress emit failed")

    def _run(self) -> None:
        sim = self._sim
        try:
            # 모델은 '보관 위치에서 시작'을 전제한다. 여기서는 방금 끝난 버튼 시퀀스(누름은 복귀까지
            # 끝나야 응답한다)가 그 위치·Z 근거를 대신한다 — 마지막 누름 좌표를 출발점으로 넘긴다.
            sim.locate_at_park()
            sim.begin()
            start = None
            if self._start_position is not None:
                try:
                    start = MmPoint(*self._start_position)
                except ValueError:
                    start = None
            sim.sequence_finished(start)
            self._probe.start()
            self._set("hovering_stop", "작은 팔이 정지 버튼 위로 가는 중이에요")
            if not self._advance():
                return
            self._set("hovering_stop", f"작은 팔이 '{self.plan.stop_button}' 버튼 위에서 기다리는 중이에요")
            started = self._clock()
            while True:
                self._wake.wait(self._timing.poll_s)
                self._wake.clear()
                with self._lock:
                    drive, release, stop = self._drive_flag, self._release_flag, self._stop_flag
                if drive:
                    sim.lock("actuator_emergency_stop")
                    self._set("fault", DETAIL_DRIVE_STOPPED)
                    return
                if release and (not stop or self.stop_outcome is not None):
                    self._set("released", "새 실행이 시작돼 작은 팔이 정지 버튼 위에서 기다리기를 끝냈어요")
                    return
                if stop and not self._stop_handled:
                    self._stop_handled = True
                    self._do_stop()
                    if sim.phase is Phase.LOCKED:
                        return
                running = self._probe.running()
                now = self._clock()
                if sim.phase is Phase.STOP_CHECK:
                    if running is False:
                        late = self.stop_outcome == "requested_unconfirmed"
                        self.stop_outcome = "stopped"
                        self.detail = (DETAIL_STOPPED_LATE if late
                                       else DETAIL_STOPPED_MOCK if getattr(self._probe, "source", "") == "mock"
                                       else DETAIL_STOPPED)
                        self._park("stop_confirmed")
                        return
                    if (self.stop_outcome is None and self._stop_requested_at is not None
                            and now - self._stop_requested_at >= self._timing.stop_confirm_s):
                        self.stop_outcome = "requested_unconfirmed"
                        # 다시 누르지 않는다(9/27 모델 규칙) — 정지 버튼 위에서 계속 기다린다.
                        self._set("hovering_stop", DETAIL_UNCONFIRMED.format(n=self.plan.stop_presses))
                elif sim.phase is Phase.WAITING and running is False:
                    self._park("appliance_finished")
                    return
                if now - started >= self._timing.max_hold_s:
                    self._park("hold_timeout")
                    return
        except Exception as exc:  # noqa: BLE001 - 어떤 고장이든 잠금으로 끝낸다
            log.exception("stop hold failed")
            try:
                sim.lock("hold_internal_error")
            except Exception:  # noqa: BLE001
                pass
            self._set("fault", f"작은 팔이 정지 버튼 위에서 기다리다 오류가 났어요({exc}) — 가전은 직접 확인해 주세요")

    def _do_stop(self) -> None:
        sim = self._sim
        self._stop_requested_at = self._clock()
        if sim.phase is Phase.LOCKED:
            self.stop_outcome = "drive_fault"
            self._set("fault", DETAIL_DRIVE_FAULT)
            return
        self._set("stopping", f"작은 팔이 정지 버튼 '{self.plan.stop_button}'을 {self.plan.stop_presses}번 누르는 중이에요")
        try:
            sim.request_appliance_stop()
        except ValueError:
            self.stop_outcome = "drive_fault"
            sim.lock("stop_route_unavailable")
            self._set("fault", DETAIL_DRIVE_FAULT)
            return
        if not self._advance(on_fail_outcome="drive_fault"):
            return
        self._set("stopping", "작은 팔이 정지 버튼을 눌렀어요 — 가전 전력이 떨어지는지 확인하는 중이에요")

    def _park(self, reason: str) -> None:
        self.park_reason = reason
        self._sim.confirm_operation_ended()
        self._set("parking", self.detail if self.stop_outcome == "stopped" else "작은 팔이 제자리로 돌아가는 중이에요")
        if self._advance():
            detail = PARK_DETAILS.get(reason, "작은 팔이 제자리로 돌아갔어요")
            if self.stop_outcome == "stopped":
                detail = f"{self.detail} · {detail}"
            elif self.stop_outcome == "requested_unconfirmed":
                detail = f"{DETAIL_UNCONFIRMED.format(n=self.plan.stop_presses)} · {detail}"
            self._set("parked", detail)

    def _advance(self, on_fail_outcome: str | None = None) -> bool:
        sim = self._sim
        while sim.pending is not None:
            action = sim.pending
            ok, error = self._perform(action)
            sim.acknowledge(action.id, success=ok)
            if not ok:
                with self._lock:
                    drive = self._drive_flag
                if on_fail_outcome is not None:
                    self.stop_outcome = on_fail_outcome
                detail = DETAIL_DRIVE_STOPPED if drive and on_fail_outcome is None else (
                    DETAIL_DRIVE_FAULT if on_fail_outcome == "drive_fault"
                    else f"작은 팔에 이상이 생겼어요({error}) — 정지 버튼 위에서 기다리기를 멈췄어요. 가전은 직접 확인해 주세요")
                self._set("fault", detail, error=error)
                return False
        return True

    def _perform(self, action: Any) -> tuple[bool, str | None]:
        plan = self.plan
        try:
            if action.kind == "retract":
                self._motion.retract()
            elif action.kind == "move":
                target = (action.target.x, action.target.y)
                self.target = target
                parking = target == (plan.park_x_mm, plan.park_y_mm) and self._sim.operation_ended
                self._set("parking" if parking else self.state or "hovering_stop", action="move")
                self._motion.move_to(*target)
            elif action.kind == "press_stop":
                self.target = (plan.stop_x_mm, plan.stop_y_mm)
                for i in range(plan.stop_presses):
                    if i:
                        self._sleep(self._timing.press_gap_s)
                    self._motion.press_at(plan.stop_button, plan.stop_x_mm, plan.stop_y_mm, plan.press_ms)
                    self.presses_done = i + 1
                    self._set("stopping", action="press")
                self._probe.note_stop_presses(plan.stop_presses)
            else:
                return False, f"unknown action {action.kind}"
        except Exception as exc:  # noqa: BLE001 - 모든 동작 실패는 잠금으로
            return False, str(exc)
        return True, None


def run_verify_pass(
    motion: Any,
    targets: Sequence[VerifyTarget],
    emit: Callable[[dict], None],
    should_stop: Callable[[], bool] = lambda: False,
) -> list[dict]:
    """확인 주행. 좌표마다 이동만 하고(누르지 않음) 결과를 돌려준다.

    ``reached``는 모션 어댑터가 도착을 응답했다는 뜻이다(모의에서는 기록만). 버튼 위에 정말
    있는지는 사람이 눈으로 확인한다. 한 곳이라도 실패하면 나머지는 ``skipped``.
    """
    results: list[dict] = []
    halted = False
    counter = itertools.count(1)
    for index, target in enumerate(targets):
        entry = {"index": index, "button": target.button, "kind": target.kind,
                 "target": {"x_mm": target.x_mm, "y_mm": target.y_mm}}
        if halted or should_stop():
            halted = True
            entry.update(status="skipped", detail="앞 단계가 멈춰 건너뛰었어요")
            results.append(entry)
            emit({"phase": "verify", "n_step": next(counter), **entry})
            continue
        emit({"phase": "verify", "n_step": next(counter), **entry, "status": "moving", "detail": None})
        try:
            motion.move_to(target.x_mm, target.y_mm)
        except Exception as exc:  # noqa: BLE001 - 실패는 결과로 보고한다
            halted = True
            entry.update(status="failed", detail=str(exc))
        else:
            entry.update(status="reached",
                         detail="Z를 올린 채 도착(모의 기록)" if getattr(motion, "execution_mode", None)
                         is ExecutionMode.MOCK else "Z를 올린 채 도착 응답 — 버튼 위인지 눈으로 확인해 주세요")
        results.append(entry)
        emit({"phase": "verify", "n_step": next(counter), **entry})
    return results
