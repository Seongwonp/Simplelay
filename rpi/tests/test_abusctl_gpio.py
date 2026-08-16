import subprocess

import pytest

from rpi.controller.abusctl_gpio import (
    AbusctlError,
    AbusctlGpioClient,
    UnknownButtonError,
)
from rpi.controller.models import PressCommand


class FakeRunner:
    """Records abusctl invocations and returns scripted results."""

    def __init__(self):
        self.calls: list[list[str]] = []
        self._scripted: dict[str, subprocess.CompletedProcess] = {}
        self._raise: dict[str, Exception] = {}

    def script_error(self, method: str, stderr: str, returncode: int = 1) -> None:
        self._scripted[method] = subprocess.CompletedProcess(
            args=[], returncode=returncode, stdout="", stderr=stderr
        )

    def script_raise(self, method: str, exc: Exception) -> None:
        self._raise[method] = exc

    def __call__(self, argv: list[str]) -> subprocess.CompletedProcess:
        self.calls.append(argv)
        method = argv[3]  # [abusctl, call, <interface>, <method>, ...]
        if method in self._raise:
            raise self._raise[method]
        if method in self._scripted:
            return self._scripted[method]
        return subprocess.CompletedProcess(args=argv, returncode=0, stdout="", stderr="")


def build_client(runner: FakeRunner, **kwargs) -> AbusctlGpioClient:
    return AbusctlGpioClient(
        button_peripheral_ids={"해동": "GPIO_4", "시작": "GPIO_5"},
        pulse_seconds=0.001,  # keep tests fast
        runner=runner,
        **kwargs,
    )


def test_press_enables_opens_pulses_and_closes():
    runner = FakeRunner()
    client = build_client(runner)

    client.press(PressCommand("해동"))

    methods = [call[3] for call in runner.calls]
    assert methods == ["EnablePeripheral", "Open", "WriteValue", "WriteValue", "Close"]

    enable_call = runner.calls[0]
    assert enable_call[4] == "GPIO_4"
    assert enable_call[-2:] == ["-o", "/com/atlas/PeripheralManager1"]

    open_call = runner.calls[1]
    assert open_call[4] == "1"  # direction=OUT
    assert open_call[-2:] == ["-o", "/com/atlas/PeripheralManager1/GPIO_4"]

    write_calls = runner.calls[2:4]
    assert [c[4] for c in write_calls] == ["1", "0"]


def test_unknown_button_raises_without_calling_abusctl():
    runner = FakeRunner()
    client = build_client(runner)

    with pytest.raises(UnknownButtonError):
        client.press(PressCommand("존재하지않는버튼"))

    assert runner.calls == []


def test_enable_peripheral_only_called_once_per_id():
    runner = FakeRunner()
    client = build_client(runner)

    client.press(PressCommand("해동"))
    client.press(PressCommand("해동"))

    enable_calls = [c for c in runner.calls if c[3] == "EnablePeripheral"]
    assert len(enable_calls) == 1


def test_enable_peripheral_called_separately_per_distinct_id():
    runner = FakeRunner()
    client = build_client(runner)

    client.press(PressCommand("해동"))
    client.press(PressCommand("시작"))

    enable_ids = [c[4] for c in runner.calls if c[3] == "EnablePeripheral"]
    assert enable_ids == ["GPIO_4", "GPIO_5"]


def test_already_enabled_error_is_swallowed():
    runner = FakeRunner()
    runner.script_error(
        "EnablePeripheral",
        "com.atlas.PeripheralManager.Error.PeripheralAlreadyEnabled",
    )
    client = build_client(runner)

    client.press(PressCommand("해동"))  # must not raise

    methods = [call[3] for call in runner.calls]
    assert methods == ["EnablePeripheral", "Open", "WriteValue", "WriteValue", "Close"]


def test_other_enable_peripheral_errors_propagate():
    runner = FakeRunner()
    runner.script_error(
        "EnablePeripheral",
        "com.atlas.PeripheralManager.Error.PeripheralNotFound",
    )
    client = build_client(runner)

    with pytest.raises(AbusctlError, match="PeripheralNotFound"):
        client.press(PressCommand("해동"))

    # Open/Write/Close must never run if the peripheral could not be enabled.
    methods = [call[3] for call in runner.calls]
    assert methods == ["EnablePeripheral"]


def test_nonzero_exit_from_open_raises_abusctl_error():
    runner = FakeRunner()
    runner.script_error("Open", "com.atlas.PeripheralManager.Error.PeripheralBusy")
    client = build_client(runner)

    with pytest.raises(AbusctlError, match="PeripheralBusy"):
        client.press(PressCommand("해동"))


def test_close_is_still_attempted_when_write_value_fails():
    runner = FakeRunner()
    runner.script_error("WriteValue", "com.atlas.PeripheralManager.Error.OperationFailed")
    client = build_client(runner)

    with pytest.raises(AbusctlError):
        client.press(PressCommand("해동"))

    methods = [call[3] for call in runner.calls]
    assert "Close" in methods


def test_missing_abusctl_binary_raises_abusctl_error():
    runner = FakeRunner()
    runner.script_raise("EnablePeripheral", FileNotFoundError())
    client = build_client(runner)

    with pytest.raises(AbusctlError, match="not found"):
        client.press(PressCommand("해동"))


def test_timeout_raises_abusctl_error():
    runner = FakeRunner()
    runner.script_raise(
        "EnablePeripheral", subprocess.TimeoutExpired(cmd="abusctl", timeout=5.0)
    )
    client = build_client(runner)

    with pytest.raises(AbusctlError, match="timed out"):
        client.press(PressCommand("해동"))


def test_empty_mapping_rejected_at_construction():
    with pytest.raises(ValueError):
        AbusctlGpioClient(button_peripheral_ids={})


def test_nonpositive_pulse_seconds_rejected_at_construction():
    with pytest.raises(ValueError):
        AbusctlGpioClient(button_peripheral_ids={"해동": "GPIO_4"}, pulse_seconds=0)
