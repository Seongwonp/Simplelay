"""RPi4 entry point — opens a UART serial connection to RPi5 and runs ActExecutor.

This is the actual "Act" board per docs/protocol.md: it receives an
already-resolved button sequence from RPi5 and runs it through the closed
loop. It does not talk to ESP32 and does not resolve intent — that is
main.py/UartBridge's job, which (despite living in this package) actually
runs on RPi5. See the note at the top of main.py.

Environment variables:
  SIMPLELAY_UART_PORT   serial device path  (default: /dev/ttyAMA0)
  SIMPLELAY_UART_BAUD   baud rate           (default: 115200)

Usage:
  python -m rpi4.act_main
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier import MockVerifier

from .services.act_executor import ActExecutor

SERIAL_PORT = os.getenv("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
BAUD_RATE = int(os.getenv("SIMPLELAY_UART_BAUD", "115200"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)


def _build_executor(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> ActExecutor:
    """Wire up the executor with current adapters.

    GrblClient and Verifier are mocks until real hardware (actuator + current/
    audio sensors) is wired in — swap them out here once that's ready.
    """
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=MockVerifier(outcomes=[True] * 1000),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    return ActExecutor(reader=reader, writer=writer, controller=controller)


async def _run() -> None:
    log.info("Opening %s at %d baud", SERIAL_PORT, BAUD_RATE)
    try:
        import serial_asyncio  # type: ignore[import-untyped]
    except ImportError:
        log.error(
            "pyserial-asyncio not installed.\n"
            "Install with:  pip install pyserial-asyncio\n"
            "Then retry:    python -m rpi4.act_main"
        )
        sys.exit(1)

    reader, writer = await serial_asyncio.open_serial_connection(
        url=SERIAL_PORT,
        baudrate=BAUD_RATE,
    )
    log.info("Serial open — waiting for RPi5 execute commands")
    executor = _build_executor(reader, writer)
    await executor.run()


if __name__ == "__main__":
    asyncio.run(_run())
