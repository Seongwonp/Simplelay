"""RPi4 entry point — opens a UART serial connection and runs UartBridge.

Environment variables:
  SIMPLELAY_UART_PORT   serial device path  (default: /dev/ttyAMA0)
  SIMPLELAY_UART_BAUD   baud rate           (default: 115200)

Usage:
  python -m rpi4.main
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import InMemoryUsageLog, RuleBasedIntentResolver
from rpi.intent.clock import SystemClock
from rpi.verifier import MockVerifier

from .services.bridge import UartBridge
from .services.sequence_store import SequenceStore

SERIAL_PORT = os.getenv("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
BAUD_RATE = int(os.getenv("SIMPLELAY_UART_BAUD", "115200"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)


def _build_bridge(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> UartBridge:
    """Wire up the bridge with current adapters.

    GrblClient and Verifier are mocks until real RPi Zero hardware is connected.
    Swap them out here once M2/M3 hardware adapters are implemented.
    """
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=MockVerifier(outcomes=[True] * 1000),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    clock = SystemClock()
    return UartBridge(
        reader=reader,
        writer=writer,
        intent=RuleBasedIntentResolver(),
        controller=controller,
        usage_log=InMemoryUsageLog(),
        store=SequenceStore(),
        clock=clock,
    )


async def _run() -> None:
    log.info("Opening %s at %d baud", SERIAL_PORT, BAUD_RATE)
    try:
        import serial_asyncio  # type: ignore[import-untyped]
    except ImportError:
        log.error(
            "pyserial-asyncio not installed.\n"
            "Install with:  pip install pyserial-asyncio\n"
            "Then retry:    python -m rpi4.main"
        )
        sys.exit(1)

    reader, writer = await serial_asyncio.open_serial_connection(
        url=SERIAL_PORT,
        baudrate=BAUD_RATE,
    )
    log.info("Serial open — waiting for ESP32 messages")
    bridge = _build_bridge(reader, writer)
    await bridge.run()


if __name__ == "__main__":
    asyncio.run(_run())
