"""RPi4 entry point — opens a UART serial connection to RPi5 and runs ActExecutor.

This is the actual "Act" board per docs/protocol.md: it receives an
already-resolved button sequence from RPi5 and runs it through the closed
loop. It does not talk to ESP32 and does not resolve intent — that is
main.py/UartBridge's job, which (despite living in this package) actually
runs on RPi5. See the note at the top of main.py.

Environment variables:
  SIMPLELAY_UART_PORT             serial device path  (default: /dev/ttyAMA0)
  SIMPLELAY_UART_BAUD             baud rate           (default: 115200)
  SIMPLELAY_SENSORS_ENABLED       "true" → SensorVerifier (ADS1115 전류 +
                                  마이크 음향 퓨전 검증). 기본 false = mock —
                                  센서 하드웨어 없이도 실행 경로가 살아있어야
                                  하므로 (SIMPLELAY_GPIO_ENABLED와 같은 관례)
  SIMPLELAY_DANGER_SOUND_ENABLED  "true" → 위험소리(경보음) 상시 감지 태스크
                                  가동, 감지 시 RPi5로 alert 자체발신

Usage:
  python -m rpi4.act_main
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import sys

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier import MockVerifier, Verifier

from .services.act_executor import ActExecutor

SERIAL_PORT = os.getenv("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
BAUD_RATE = int(os.getenv("SIMPLELAY_UART_BAUD", "115200"))


def _flag(name: str) -> bool:
    return os.getenv(name, "false").strip().lower() == "true"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)


def _build_verifier() -> Verifier:
    """SIMPLELAY_SENSORS_ENABLED=true면 실제 센서 퓨전 검증, 아니면 mock.

    SensorVerifier의 하드웨어 리더(Ads1115Reader·SounddeviceReader)는 생성
    시점에 장치를 연다 — 센서가 없는 보드에서 기본값이 mock이어야 실행
    경로 자체가 죽지 않는다.
    """
    if _flag("SIMPLELAY_SENSORS_ENABLED"):
        from rpi.verifier import SensorVerifier

        log.info("SensorVerifier active — ADS1115 current + microphone fusion")
        return SensorVerifier()
    log.info("MockVerifier active (set SIMPLELAY_SENSORS_ENABLED=true for real sensors)")
    return MockVerifier(outcomes=[True] * 1000)


def _build_executor(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> ActExecutor:
    """Wire up the executor with current adapters.

    GrblClient는 아직 mock — 실물 모션 어댑터(Arduino PID 시리얼)는 W5
    HW 통합에서 이 자리에 꽂는다. Verifier는 env로 실물 전환 가능.
    """
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=_build_verifier(),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    return ActExecutor(reader=reader, writer=writer, controller=controller)


def _maybe_start_danger_monitor(executor: ActExecutor) -> "asyncio.Task[None] | None":
    """위험소리 감지 태스크 — 코드·테스트는 완성돼 있었지만 그동안 어느
    엔트리포인트도 기동하지 않아 /alerts가 실기기에서도 절대 울리지 않았다.

    검증용과 별개의 SounddeviceReader 인스턴스를 연다 — 같은 마이크에 입력
    스트림 2개가 공존하는지는 실기기에서 확인 필요(문제 시 프레임 팬아웃
    공유 리더로 교체).
    """
    if not _flag("SIMPLELAY_DANGER_SOUND_ENABLED"):
        log.info(
            "DangerSoundMonitor off (set SIMPLELAY_DANGER_SOUND_ENABLED=true to enable)"
        )
        return None

    from rpi.verifier import SensorConfig
    from rpi.verifier.audio_sensor import SounddeviceReader

    from .services.danger_sound_monitor import DangerSoundMonitor

    reader = SounddeviceReader(SensorConfig().audio)
    monitor = DangerSoundMonitor(reader, executor)
    log.info("DangerSoundMonitor active — continuous alarm-sound detection")
    return asyncio.create_task(monitor.run())


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
    monitor_task = _maybe_start_danger_monitor(executor)
    try:
        await executor.run()
    finally:
        if monitor_task is not None:
            monitor_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await monitor_task


if __name__ == "__main__":
    asyncio.run(_run())
