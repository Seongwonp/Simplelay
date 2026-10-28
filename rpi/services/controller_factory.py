"""Chooses which ButtonSequenceController implementation to build, from
environment variables -- shared by both RPi5 entry points that need one:
rpi/api/deps.py (Flutter app HTTP path) and rpi4/main.py (ESP32 BLE path,
despite the package name -- see that module's docstring).

Kept separate from act_client_controller.py so that module stays a pure
sync/async bridge with no policy knowledge of mocks or env vars.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable

from rpi.controller import (
    ButtonSequenceController,
    ClosedLoopController,
    ExecutionProgressTracker,
)
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.ports import SleepingRetryWaiter
from rpi.verifier import MockVerifier

from .act_client import AlertEvent
from .act_client_controller import open_uart_act_controller
from .demo_failure import DemoFailureState, FailureInjectionVerifier


def build_controller(
    progress_tracker: ExecutionProgressTracker | None = None,
    on_alert: Callable[[AlertEvent], None] | None = None,
    failure_state: DemoFailureState | None = None,
    on_appliance_done: Callable[[dict], None] | None = None,
    on_act_info: Callable[[dict], None] | None = None,
) -> ButtonSequenceController:
    """``SIMPLELAY_ACT_MODE=uart``: dispatch to a real RPi4 board over UART
    (ActClientController) -- aggregate result only, no live per-button
    progress (see docs/roadmap.md M2), so ``progress_tracker`` is unused in
    this mode. Otherwise (default, offline-first): a local
    ClosedLoopController against mock hardware, with ``progress_tracker``
    wired in via its on_progress callback if given.

    ``failure_state``: 데모 실패 주입(POST /demo/inject-failure) 상태 —
    로컬 모드에서만 verifier에 래핑된다. UART 모드는 검증이 RPi4에서
    일어나므로 여기서는 배선 불가(demo_failure.py 모듈 docstring 참고).
    """
    mode = os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower()
    if mode == "simulator":
        from .simulator_controller import SimulatorController
        return SimulatorController(on_alert=on_alert, on_appliance_done=on_appliance_done)
    if mode == "uart":
        port = os.environ.get("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
        baud = int(os.environ.get("SIMPLELAY_UART_BAUD", "115200"))
        # 완료 콜백이 없으면 종전 호출 모양 그대로(2026-10-06 appliance_done 이전과 같게).
        extra = {"on_appliance_done": on_appliance_done} if on_appliance_done is not None else {}
        if on_act_info is not None:
            extra["on_act_info"] = on_act_info  # RPi4 끝 관찰 목록 대조(평가 B3)
        return open_uart_act_controller(port, baud, on_alert=on_alert, **extra)

    grbl = MockGrblClient()
    verifier: object = MockVerifier(outcomes=[True] * 100)
    if failure_state is not None:
        verifier = FailureInjectionVerifier(verifier, failure_state)
    # 모의 실행의 진행을 시연할 수 있도록 단계와 재시도 사이에 지연을 넣는다.
    # 기본은 지연 0이며, 실제 하드웨어에서는 이 옵션을 끄고 모터 동작 시간을 따른다.
    step_pacer = None
    retry_waiter = None
    if os.environ.get("SIMPLELAY_DEMO_PACING", "").strip().lower() in (
        "1", "true", "yes", "on",
    ):
        seconds = float(os.environ.get("SIMPLELAY_DEMO_PACING_SECONDS", "1.2"))

        def step_pacer(button: str, completed_steps: int) -> None:
            time.sleep(seconds)

        retry_waiter = SleepingRetryWaiter(seconds)
    return ClosedLoopController(
        grbl,
        verifier,
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=retry_waiter,
        on_progress=progress_tracker.update if progress_tracker else None,
        step_pacer=step_pacer,
    )
