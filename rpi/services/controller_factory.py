"""Chooses which ButtonSequenceController implementation to build, from
environment variables -- shared by both RPi5 entry points that need one:
rpi/api/deps.py (Flutter app HTTP path) and rpi4/main.py (ESP32 BLE path,
despite the package name -- see that module's docstring).

Kept separate from act_client_controller.py so that module stays a pure
sync/async bridge with no policy knowledge of mocks or env vars.
"""

from __future__ import annotations

import os
from collections.abc import Callable

from rpi.controller import (
    ButtonSequenceController,
    ClosedLoopController,
    ExecutionProgressTracker,
)
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier import MockVerifier

from .act_client import AlertEvent
from .act_client_controller import open_uart_act_controller


def build_controller(
    progress_tracker: ExecutionProgressTracker | None = None,
    on_alert: Callable[[AlertEvent], None] | None = None,
) -> ButtonSequenceController:
    """``SIMPLELAY_ACT_MODE=uart``: dispatch to a real RPi4 board over UART
    (ActClientController) -- aggregate result only, no live per-button
    progress (see docs/roadmap.md M2), so ``progress_tracker`` is unused in
    this mode. Otherwise (default, offline-first): a local
    ClosedLoopController against mock hardware, with ``progress_tracker``
    wired in via its on_progress callback if given.
    """
    mode = os.environ.get("SIMPLELAY_ACT_MODE", "").strip().lower()
    if mode == "uart":
        port = os.environ.get("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
        baud = int(os.environ.get("SIMPLELAY_UART_BAUD", "115200"))
        return open_uart_act_controller(port, baud, on_alert=on_alert)

    grbl = MockGrblClient()
    verifier = MockVerifier(outcomes=[True] * 100)
    return ClosedLoopController(
        grbl,
        verifier,
        MockAlertSink(),
        MockSafetyController(),
        on_progress=progress_tracker.update if progress_tracker else None,
    )
