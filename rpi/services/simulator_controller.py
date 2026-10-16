"""Long-lived, hardware-free Act link for the normal API and Flutter clients.

Only the motor/verifier and byte transport are synthetic. ActClient,
ActExecutor and ClosedLoopController run unchanged. No serial device is opened.
"""
from __future__ import annotations

import asyncio
import json
import os
import threading
import time
from collections import deque
from dataclasses import replace

from rpi.controller import ClosedLoopController, ExecutionMode
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.ports import SleepingRetryWaiter
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor

from .act_client import ActClient, ActClientConfig
from .act_client_controller import ActClientController, start_background_loop
from .demo_failure import DemoFailureState, FailureInjectionVerifier


class _AlwaysMockVerifier(MockVerifier):
    # MockVerifier eagerly consumes its iterable, so do not give it repeat().
    def __init__(self):
        super().__init__([])

    def verify(self, button):
        from rpi.verifier import VerificationResult
        return VerificationResult(True, 1.0, "모의 눌림 검증 — 실제 센서 아님")


def _correction(correction):
    if correction is None:
        return None
    return {"retry_number": correction.retry_number,
            "xy_adjustment_required": correction.xy_adjustment_required,
            "increase_press_depth": correction.increase_press_depth}


class _UnknownAfterStopRun:
    """모의 위치 대기(M3)용 모의 가전 — 정지 버튼을 누르기 전에는 감싼 모의 가전을 따르고
    (동작 시간이 지나면 꺼짐 → 보관), 누른 뒤에는 켜짐/꺼짐을 **모른다**(None). 전력 하강을
    흉내 내지 않으므로 정지 결과는 '정지 요청함·미확인'을 넘지 않는다."""

    def __init__(self, inner):
        self._inner = inner
        self.source = getattr(inner, "source", "mock")
        self._pressed = False

    def start(self) -> None:
        self._inner.start()

    def running(self):
        return None if self._pressed else self._inner.running()

    def note_stop_presses(self, count: int) -> None:
        self._pressed = True


async def _call(fn):
    """이벤트 루프 스레드에서 동기 함수를 부른다(실행기 상태는 그 스레드 것이다)."""
    fn()


class SimulatorController(ActClientController):
    execution_mode = ExecutionMode.MOCK

    def __init__(self, *, step_seconds: float = 0.8, on_alert=None, operation=None, tap=None,
                 on_appliance_done=None):
        """``operation``: L3 검증기(선택). 없으면 ``SIMPLELAY_L3_MODE``(기본 off)로 고른다 --
        mock이면 합성 전력 판정이 결과 프레임에 ``operation_source=mock``으로 실린다."""
        if not 0 <= step_seconds <= 3:
            raise ValueError("simulator step_seconds must be between 0 and 3")
        self._state_lock = threading.Lock()
        from .parking_rehearsal import ParkingRehearsal
        self.parking_rehearsal = ParkingRehearsal()
        from .routine_rehearsal import RoutineRehearsal
        self.routine_rehearsal = RoutineRehearsal()
        self._closed = False
        self._busy = False
        #: 이번 실행의 정지 대기 위치 출처(mock | calibrated)와 대기를 못 한 이유(M3).
        self._hold_position_source: str | None = None
        self._hold_unavailable: dict | None = None
        # 재시도가 긴 시퀀스에서도 execute 프레임이 밀려나지 않게 넉넉히 둔다.
        # 그래도 밀려나면 마지막 execute 프레임을 따로 고정해 둔다(_last_execute).
        self._trace = deque(maxlen=400)
        self._last_execute = None
        self._loop, self._thread = start_background_loop()

        owner = self
        if operation is None:
            from rpi.controller.power_operation import operation_verifier_from_env
            operation = operation_verifier_from_env()
        self.operation_verifier = operation

        class Wire:
            def __init__(self, peer, direction):
                self.peer, self.direction = peer, direction

            def write(self, data):
                with owner._state_lock:
                    frame = {"direction": self.direction, "message": json.loads(data)}
                    owner._trace.append(frame)
                    if self.direction == "hub_to_act" and frame["message"].get("type") == "execute":
                        owner._last_execute = frame
                self.peer.feed_data(data)

            async def drain(self):
                await asyncio.sleep(0)

        if tap is None:
            from .link_tap import get_link_tap
            tap = get_link_tap()
            tap.transport = tap.transport or "in_memory"

        async def open_link():
            act_reader, hub_reader = asyncio.StreamReader(), asyncio.StreamReader()
            state = DemoFailureState()
            motor = MockGrblClient()

            class RecordedController(ClosedLoopController):
                def execute(inner, buttons, targets=None, *, button_behaviors=None):
                    # 보정된 가전은 좌표(targets)가 함께 온다 — 받지 않으면 TypeError로
                    # actuator_fail이 됐다(2026-09-30 수리).
                    motor.commands.clear()
                    owner._local_result = None
                    result = super().execute(buttons, targets, button_behaviors=button_behaviors)
                    owner._local_result = result
                    return result

            controller = RecordedController(
                motor, FailureInjectionVerifier(_AlwaysMockVerifier(), state),
                MockAlertSink(), MockSafetyController(),
                retry_waiter=SleepingRetryWaiter(step_seconds),
                step_pacer=lambda *_: time.sleep(step_seconds),
                operation=operation,
            )
            # 정지 대기·보관·확인 주행도 같은 모의 속도로 보인다(모의 가전: SIMPLELAY_HOLD_MOCK_*).
            from rpi4.services.stop_hold import mock_hold_hardware
            self.hold_hardware = mock_hold_hardware(step_seconds)
            # 모의 위치 대기(M3)에서는 정지 버튼을 누른 뒤의 가전 상태를 '모름'으로 둔다 — 실물 좌표도
            # 전력 근거도 없으니 '정지됨'을 지어내지 않고 '정지 요청함·미확인'으로 끝난다(전력 리더 없는
            # 실기기와 같은 결과). 그 뒤 최대 대기 시간(모의 위치일 때는 모의 가전 동작 시간으로 줄임)이
            # 지나면 보관 위치로 간다.
            base_probe = self.hold_hardware.probe_factory
            self._base_hold_timing = self.hold_hardware.timing
            from rpi4.services.stop_hold import _env_float
            self._mock_run_s = _env_float(os.environ, "SIMPLELAY_HOLD_MOCK_RUN_S", 30.0)

            def probe_factory(plan):
                probe = base_probe(plan)
                with owner._state_lock:
                    mock_position = owner._hold_position_source == "mock"
                return _UnknownAfterStopRun(probe) if mock_position else probe

            self.hold_hardware.probe_factory = probe_factory
            executor = ActExecutor(act_reader, Wire(hub_reader, "act_to_hub"), controller, state,
                                   hold=self.hold_hardware)
            # UART 모드와 같은 프레임 탭을 쓴다 — 실모드 트윈(/twin)·세션 기록이 두 모드에서 같다.
            client = ActClient(hub_reader, Wire(act_reader, "hub_to_act"),
                               ActClientConfig(5, 12), on_alert=on_alert, tap=tap,
                               on_appliance_done=on_appliance_done, hello=True)
            self._reader, self._executor, self._motor = act_reader, executor, motor
            self._local_result = None
            self._executor_task = asyncio.create_task(executor.run())
            await client.start()
            return client

        try:
            client = asyncio.run_coroutine_threadsafe(open_link(), self._loop).result(5)
        except BaseException:
            self._loop.call_soon_threadsafe(self._loop.stop)
            self._thread.join(5)
            self._loop.close()
            raise
        super().__init__(self._loop, client)

    def execute(self, buttons, targets=None, *, button_behaviors=None):
        with self._state_lock:
            if self._closed or self._busy:
                raise RuntimeError("simulator closed or busy")
            self._busy = True
        try:
            return super().execute(buttons, targets, button_behaviors=button_behaviors)
        finally:
            with self._state_lock:
                self._busy = False

    # ── 정지 대기 흉내(2026-10-06, 시연 v3 갭 M3) ───────────────────────────────
    # 전부 모의 등급에는 정지 버튼 mm·보관 위치가 없어 대기 장면이 없었다. 정지 버튼이 등록된
    # 가전이면 모의 위치로 같은 hold 계획을 실어 보낸다 — RPi4 실행기·상태 기계·보고 프레임은
    # UART 모드와 같은 코드다. UART(ActClientController)는 이 표시가 없어 종전 그대로다.

    #: 서비스가 이 표시를 보고 ``arm_stop_hold`` 대신 ``arm_simulated_stop_hold``를 부른다.
    simulates_stop_hold = True

    def arm_simulated_stop_hold(self, registry, appliance_id) -> None:
        from .stop_park import HOLD_UNAVAILABLE_DETAILS, simulated_hold_plan

        plan, reason = simulated_hold_plan(registry, appliance_id)
        wire = None
        with self._state_lock:
            if plan is None:
                self._hold_position_source = None
                self._hold_unavailable = {
                    "hold_state": None, "unavailable_reason": reason,
                    "detail": HOLD_UNAVAILABLE_DETAILS.get(reason), "appliance_id": appliance_id,
                    "execution_mode": "mock",
                }
            else:
                wire = dict(plan)
                self._hold_position_source = wire.pop("position_source", None)
                self._hold_unavailable = None
        # 모의 위치면 최대 대기를 모의 가전 동작 시간으로 줄인다 — 정지 뒤 '미확인'으로 남은 대기가
        # 30분(실기기 설계 초기값)을 기다리지 않고 리허설 안에 보관 위치로 간다. 세션은 시작할 때
        # 이 값을 한 번 읽는다(다음 arm은 이번 실행이 끝난 뒤).
        base = self._base_hold_timing
        self.hold_hardware.timing = (
            replace(base, max_hold_s=min(base.max_hold_s, self._mock_run_s))
            if wire is not None and self._hold_position_source == "mock" else base
        )
        # 선(RPi4 execute 메시지)에는 종전 필드만 싣는다 — 위치 출처는 허브 쪽 표시다.
        self.arm_stop_hold(wire)

    def hold_status(self):
        doc = super().hold_status()
        with self._state_lock:
            source, unavailable = self._hold_position_source, self._hold_unavailable
        if doc:
            if source is not None:
                doc["position_source"] = source
            return doc
        # 대기 보고가 없고 이번 실행에 계획을 못 실었으면 그 이유를 보인다(hold_state는 null).
        return dict(unavailable) if unavailable else None

    def snapshot(self):
        with self._state_lock:
            result = self._local_result
            return {
                "execution_mode": "mock", "transport": "in_memory", "running": self._busy,
                "frames": list(self._trace),
                "last_execute_frame": self._last_execute,
                "act_local": {
                    "status": result.status.value if result else None,
                    "presses": [c.button for c in self._motor.commands],
                    # 재시도 누름의 정성 보정 요청(거리 없음). 첫 누름은 None.
                    "press_corrections": [_correction(c.correction) for c in self._motor.commands],
                    "note": "모의 실행기 내부 관측. 허브의 수신 증거와 별개입니다.",
                },
            }

    # ── 리허설 비상 버튼(2026-10-06, 시연 v3 갭 S3) ────────────────────────────
    # 실물 콘센트 모듈이 아니다. 모의 RPi4 실행기의 ``handle_outlet_estop``(실물 모듈의 estop 이벤트가
    # 부르는 것과 같은 함수)을 부르고, 해제 확인 때 버튼이 눌린 채인지만 흉내 낸다.

    def rehearse_outlet_estop(self, hold_button: bool = False) -> None:
        with self._state_lock:
            if self._closed:
                raise RuntimeError("simulator closed")
            self._rehearsal_button_held = bool(hold_button)
        executor = self._executor

        def reset() -> tuple[bool, str | None]:
            with self._state_lock:
                held = getattr(self, "_rehearsal_button_held", False)
            return (False, "estop_button_pressed") if held else (True, None)

        def trip() -> None:
            executor.set_estop_reset(reset)
            executor.handle_outlet_estop("button")

        asyncio.run_coroutine_threadsafe(_call(trip), self._loop).result(5)

    def release_rehearsal_estop_button(self) -> None:
        with self._state_lock:
            self._rehearsal_button_held = False

    # ── 리허설 세탁 끝(2026-10-06, 시연 v3 갭 S8) ──────────────────────────────
    # 실물 세탁기·CT·마이크가 아니다. 모의 RPi4 실행기가 같은 융합 규칙으로 ``appliance_done``
    # (``source:"injected"``) 프레임을 보내고, RPi5 ActClient → 루틴 엔진은 실물 프레임과 같은 길로 받는다.

    def rehearse_appliance_done(self, appliance_id: str, inputs, event: str | None = None) -> dict:
        with self._state_lock:
            if self._closed:
                raise RuntimeError("simulator closed")
        executor = self._executor

        async def inject() -> dict:
            return executor.inject_appliance_done(appliance_id, list(inputs), event)

        return asyncio.run_coroutine_threadsafe(inject(), self._loop).result(5)

    def close(self):
        with self._state_lock:
            if self._closed:
                return
            self._closed = True

        async def shutdown():
            self._reader.feed_eof()
            await self._executor_task
            await self._executor.shutdown()
            await self._client.stop()
            await self._loop.shutdown_asyncgens()
            await self._loop.shutdown_default_executor()

        try:
            asyncio.run_coroutine_threadsafe(shutdown(), self._loop).result(10)
        finally:
            self._loop.call_soon_threadsafe(self._loop.stop)
            self._thread.join(5)
            if not self._thread.is_alive():
                self._loop.close()
