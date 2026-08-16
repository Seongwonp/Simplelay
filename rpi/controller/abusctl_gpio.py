"""First real (non-mock) GrblClient: drives a GPIO peripheral over D-Bus.

A "button press" is represented as one GPIO pulse: enable the peripheral
(once per process), open it, drive the line high, hold for a configurable
pulse width, drive it low, close. Calls go through the platform's D-Bus CLI
(``abusctl``) via subprocess rather than a Python D-Bus binding, since no
such binding is documented for this platform/Python combination yet -- see
rpi/controller/README.md for the tradeoff and how to swap it out later.

This module intentionally does not decide *which* button maps to *which*
physical GPIO peripheral -- that mapping depends on hardware wiring nobody
has finalized yet. Callers supply it explicitly (``button_peripheral_ids``).
"""

import subprocess
import time
from collections.abc import Callable, Mapping

from .models import PressCommand
from .ports import GrblClient

CompletedProcess = subprocess.CompletedProcess[str]
Runner = Callable[[list[str]], CompletedProcess]


class AbusctlError(RuntimeError):
    """Raised when abusctl itself is missing, times out, or a call fails."""


class UnknownButtonError(KeyError):
    """Raised when a button has no configured GPIO peripheral id."""


class AbusctlGpioClient(GrblClient):
    _MANAGER_SERVICE = "com.atlas.PeripheralManager1"
    _MANAGER_INTERFACE = "com.atlas.PeripheralManager1"
    _MANAGER_OBJECT_PATH = "/com/atlas/PeripheralManager1"
    _GPIO_INTERFACE = "com.atlas.PeripheralManager1.GPIO"
    _DIRECTION_OUT = "1"

    def __init__(
        self,
        button_peripheral_ids: Mapping[str, str],
        pulse_seconds: float = 0.2,
        abusctl_path: str = "abusctl",
        call_timeout_seconds: float = 5.0,
        runner: Runner | None = None,
    ) -> None:
        if not button_peripheral_ids:
            raise ValueError("button_peripheral_ids must not be empty")
        if pulse_seconds <= 0:
            raise ValueError("pulse_seconds must be positive")
        self._button_peripheral_ids = dict(button_peripheral_ids)
        self._pulse_seconds = pulse_seconds
        self._abusctl_path = abusctl_path
        self._call_timeout_seconds = call_timeout_seconds
        self._run = runner or self._default_runner
        self._enabled_ids: set[str] = set()

    def press(self, command: PressCommand) -> None:
        try:
            peripheral_id = self._button_peripheral_ids[command.button]
        except KeyError as exc:
            raise UnknownButtonError(
                f"no GPIO peripheral configured for button {command.button!r}"
            ) from exc

        object_path = self._object_path(peripheral_id)
        self._ensure_enabled(peripheral_id)
        self._call(self._GPIO_INTERFACE, object_path, "Open", self._DIRECTION_OUT)
        try:
            self._call(self._GPIO_INTERFACE, object_path, "WriteValue", "1")
            time.sleep(self._pulse_seconds)
            self._call(self._GPIO_INTERFACE, object_path, "WriteValue", "0")
        finally:
            self._call(self._GPIO_INTERFACE, object_path, "Close")

    def _ensure_enabled(self, peripheral_id: str) -> None:
        if peripheral_id in self._enabled_ids:
            return
        try:
            self._call(
                self._MANAGER_INTERFACE,
                self._MANAGER_OBJECT_PATH,
                "EnablePeripheral",
                peripheral_id,
            )
        except AbusctlError as exc:
            # Already enabled from an earlier run in this process's lifetime
            # (or before this process started) is not a failure for us.
            if "AlreadyEnabled" not in str(exc):
                raise
        self._enabled_ids.add(peripheral_id)

    def _object_path(self, peripheral_id: str) -> str:
        return f"{self._MANAGER_OBJECT_PATH}/{peripheral_id}"

    def _call(
        self, interface: str, object_path: str, method: str, *args: str
    ) -> str:
        argv = [
            self._abusctl_path,
            "call",
            interface,
            method,
            *args,
            "-s",
            self._MANAGER_SERVICE,
            "-o",
            object_path,
        ]
        try:
            result = self._run(argv)
        except FileNotFoundError as exc:
            raise AbusctlError(
                f"{self._abusctl_path!r} not found -- this adapter only runs "
                "inside the platform's D-Bus environment"
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise AbusctlError(
                f"abusctl {method} on {object_path} timed out after "
                f"{self._call_timeout_seconds}s"
            ) from exc

        if result.returncode != 0:
            raise AbusctlError(
                f"abusctl {method} on {object_path} failed "
                f"(exit {result.returncode}): {result.stderr.strip()}"
            )
        return result.stdout

    def _default_runner(self, argv: list[str]) -> CompletedProcess:
        return subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=self._call_timeout_seconds,
        )
