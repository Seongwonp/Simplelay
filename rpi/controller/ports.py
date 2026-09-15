"""Ports implemented later by real GRBL, alert, and safety adapters."""

import time
from abc import ABC, abstractmethod
from collections.abc import Callable
from typing import Protocol

from .models import ExecutionMode, ExecutionResult, PressCommand


class ButtonSequenceController(Protocol):
    """Structural type for whatever runs a whole button sequence and reports
    back an ExecutionResult — satisfied by both ClosedLoopController (local,
    per-button closed loop) and ActClientController (dispatches the whole
    sequence to a real RPi4 board over UART; see rpi/services/). Callers like
    SimpleLayService only need this shape, not a specific implementation.
    """

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult: ...

    #: 선택 속성. 이 대상이 실제 액추에이터를 움직였는지 -- 실행 이력이
    #: 실제/모의를 가르는 근거다(F4). 이 속성이 없는 구현은 UNKNOWN으로
    #: 취급한다: 라우팅 결과를 보고 추측하지 않는다.
    #:
    #: execution_mode: ExecutionMode


class GrblClient(ABC):
    #: 이 클라이언트가 실제 액추에이터를 움직이는가. 구현이 스스로
    #: 밝힌다 -- 실행 이력이 실제/모의를 가르는 근거가 된다(F4).
    #: 밝히지 않으면 UNKNOWN으로 남는다: 지어내지 않는다.
    execution_mode: ExecutionMode = ExecutionMode.UNKNOWN

    @abstractmethod
    def press(self, command: PressCommand) -> None:
        """Move and press, or raise an exception for error/alarm responses."""


class AlertSink(ABC):
    @abstractmethod
    def notify_failure(self, button: str, attempts: int) -> None:
        """Notify the app/user that closed-loop recovery was exhausted."""

    def notify_operation_unconfirmed(self, detail: str) -> None:
        """L3 — 버튼은 다 들어갔는데 가전 동작이 확인되지 않았다.

        기본 구현은 기존 실패 알림으로 보낸다. 알림 채널을 새로 만들지
        않은 구현도 이 사건을 잃지 않게 하려는 것이다(누른 횟수는 0).
        """
        self.notify_failure(f"동작 확인: {detail}", 0)


class SafetyController(ABC):
    @abstractmethod
    def stop(self, reason: str) -> None:
        """Request a safe stop; a physical E-STOP remains authoritative."""


class RetryWaiter(ABC):
    @abstractmethod
    def wait(self, button: str, retry_number: int) -> None:
        """Wait for the appliance response window before retrying."""


class NoOpRetryWaiter(RetryWaiter):
    """Hardware-free default that deliberately performs no real-time delay."""

    def wait(self, button: str, retry_number: int) -> None:
        return None


class SleepingRetryWaiter(RetryWaiter):
    """데모/실기 응답창 흉내 -- 재시도 사이에 실제로 잠깐 쉬어 "재시도 중"을
    화면에 보이게 한다. 기본 경로는 여전히 NoOpRetryWaiter(지연 0)."""

    def __init__(
        self, seconds: float, sleep: Callable[[float], None] | None = None
    ) -> None:
        self._seconds = seconds
        self._sleep = sleep or time.sleep

    def wait(self, button: str, retry_number: int) -> None:
        self._sleep(self._seconds)
