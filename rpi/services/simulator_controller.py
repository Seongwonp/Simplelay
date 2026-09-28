"""Long-lived, hardware-free Act link for the normal API and Flutter clients.

Only the motor/verifier and byte transport are synthetic. ActClient,
ActExecutor and ClosedLoopController run unchanged. No serial device is opened.
"""
from __future__ import annotations

import asyncio
import json
import threading
import time
from collections import deque

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


class SimulatorController(ActClientController):
    execution_mode = ExecutionMode.MOCK

    def __init__(self, *, step_seconds: float = 0.8, on_alert=None):
        if not 0 <= step_seconds <= 3:
            raise ValueError("simulator step_seconds must be between 0 and 3")
        self._state_lock = threading.Lock()
        from .parking_rehearsal import ParkingRehearsal
        self.parking_rehearsal = ParkingRehearsal()
        from .routine_rehearsal import RoutineRehearsal
        self.routine_rehearsal = RoutineRehearsal()
        self._closed = False
        self._busy = False
        self._trace = deque(maxlen=80)
        self._loop, self._thread = start_background_loop()

        owner = self

        class Wire:
            def __init__(self, peer, direction):
                self.peer, self.direction = peer, direction

            def write(self, data):
                with owner._state_lock:
                    owner._trace.append({"direction": self.direction, "message": json.loads(data)})
                self.peer.feed_data(data)

            async def drain(self):
                await asyncio.sleep(0)

        async def open_link():
            act_reader, hub_reader = asyncio.StreamReader(), asyncio.StreamReader()
            state = DemoFailureState()
            motor = MockGrblClient()

            class RecordedController(ClosedLoopController):
                def execute(inner, buttons):
                    motor.commands.clear()
                    owner._local_result = None
                    result = super().execute(buttons)
                    owner._local_result = result
                    return result

            controller = RecordedController(
                motor, FailureInjectionVerifier(_AlwaysMockVerifier(), state),
                MockAlertSink(), MockSafetyController(),
                retry_waiter=SleepingRetryWaiter(step_seconds),
                step_pacer=lambda *_: time.sleep(step_seconds),
            )
            executor = ActExecutor(act_reader, Wire(hub_reader, "act_to_hub"), controller, state)
            client = ActClient(hub_reader, Wire(act_reader, "hub_to_act"),
                               ActClientConfig(5, 12), on_alert=on_alert)
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

    def execute(self, buttons):
        with self._state_lock:
            if self._closed or self._busy:
                raise RuntimeError("simulator closed or busy")
            self._busy = True
        try:
            return super().execute(buttons)
        finally:
            with self._state_lock:
                self._busy = False

    def snapshot(self):
        with self._state_lock:
            result = self._local_result
            return {
                "execution_mode": "mock", "transport": "in_memory", "running": self._busy,
                "frames": list(self._trace),
                "act_local": {
                    "status": result.status.value if result else None,
                    "presses": [c.button for c in self._motor.commands],
                    "note": "모의 실행기 내부 관측. 허브의 수신 증거와 별개입니다.",
                },
            }

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
