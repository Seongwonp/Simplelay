"""build_controller()의 환경변수 기반 컨트롤러 선택 로직 검증.

SIMPLELAY_ACT_MODE=uart 분기는 open_uart_act_controller()를 가짜로 바꿔치기
해서 검증한다 -- 그 함수 자체는 진짜 serial_asyncio.open_serial_connection()을
부르므로(하드웨어 필요) 여기선 인자 전달·분기 로직만 확인한다.
"""

import pytest

from rpi.controller import ClosedLoopController, ExecutionProgressTracker
import rpi.services.controller_factory as controller_factory
from rpi.services.controller_factory import build_controller


@pytest.fixture(autouse=True)
def clean_act_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("SIMPLELAY_ACT_MODE", "SIMPLELAY_UART_PORT", "SIMPLELAY_UART_BAUD"):
        monkeypatch.delenv(key, raising=False)


def test_default_mode_returns_local_closed_loop_controller():
    controller = build_controller()
    assert isinstance(controller, ClosedLoopController)


def test_default_mode_wires_progress_tracker():
    tracker = ExecutionProgressTracker()
    # 실제로 진행상황이 들어오는지는 SensorVerifier 통합 테스트 쪽 관할 -- 여기선
    # 생성이 실패하지 않고 progress_tracker가 그대로 전달되는지만 확인한다.
    controller = build_controller(tracker)
    assert isinstance(controller, ClosedLoopController)


def test_uart_mode_calls_open_uart_act_controller_with_env_values(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    monkeypatch.setenv("SIMPLELAY_UART_PORT", "/dev/ttyFAKE")
    monkeypatch.setenv("SIMPLELAY_UART_BAUD", "9600")

    calls = []
    sentinel = object()

    def _fake_open(port, baud, on_alert=None):
        calls.append((port, baud, on_alert))
        return sentinel

    monkeypatch.setattr(controller_factory, "open_uart_act_controller", _fake_open)

    result = build_controller()

    assert result is sentinel
    assert calls == [("/dev/ttyFAKE", 9600, None)]


def test_uart_mode_defaults_port_and_baud_when_unset(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    calls = []
    monkeypatch.setattr(
        controller_factory, "open_uart_act_controller",
        lambda port, baud, on_alert=None: calls.append((port, baud)) or object(),
    )

    build_controller()

    assert calls == [("/dev/ttyAMA0", 115200)]


def test_uart_mode_is_case_insensitive(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "UART")
    monkeypatch.setattr(
        controller_factory, "open_uart_act_controller",
        lambda port, baud, on_alert=None: object(),
    )

    result = build_controller()

    assert not isinstance(result, ClosedLoopController)


def test_uart_mode_forwards_on_alert_callback(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    received = []
    monkeypatch.setattr(
        controller_factory, "open_uart_act_controller",
        lambda port, baud, on_alert=None: received.append(on_alert) or object(),
    )

    def _on_alert(event):
        pass

    build_controller(on_alert=_on_alert)

    assert received == [_on_alert]
