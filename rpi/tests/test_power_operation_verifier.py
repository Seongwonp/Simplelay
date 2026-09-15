"""L3 동작 확인 어댑터 — 전력 판정기가 컨트롤러의 L3 정책으로 이어지는가."""

import pytest

from rpi.controller import ClosedLoopController, ExecutionStatus, VerificationLayer
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.power_operation import PowerOperationVerifier
from rpi.verifier import MockVerifier
from rpi.verifier.power import MockPowerSensor, PowerSample, microwave_profile


def _no_sleep(_s: float) -> None:
    return None


def _idle_samples(seconds: float = 10.0, hz: float = 10.0, watts: float = 3.0):
    return [PowerSample(i / hz, watts) for i in range(int(seconds * hz))]


def test_microwave_start_is_confirmed_as_l3_pass() -> None:
    verifier = PowerOperationVerifier(
        MockPowerSensor(microwave_profile()), sleep=_no_sleep
    )

    outcome = verifier.verify_operation(("30초", "시작"))

    assert outcome.layer is VerificationLayer.OPERATION
    assert outcome.passed is True
    assert "W" in outcome.detail


def test_no_power_rise_is_an_l3_failure_with_reason() -> None:
    verifier = PowerOperationVerifier(MockPowerSensor(_idle_samples()), sleep=_no_sleep)

    outcome = verifier.verify_operation(("시작",))

    assert outcome.passed is False
    assert "확인되지 않음" in outcome.detail


def test_stalled_sensor_does_not_hang_and_is_not_a_pass() -> None:
    polls: list[float] = []
    verifier = PowerOperationVerifier(
        MockPowerSensor([PowerSample(0.0, 3.0)]),
        max_polls=15,
        sleep=polls.append,
    )

    outcome = verifier.verify_operation(("시작",))

    assert outcome.passed is False
    assert len(polls) == 15  # 상한만큼만 기다리고 끝낸다


def test_controller_safety_stops_when_power_never_rises() -> None:
    grbl = MockGrblClient()
    safety = MockSafetyController()
    controller = ClosedLoopController(
        grbl,
        MockVerifier([True, True]),
        MockAlertSink(),
        safety,
        operation=PowerOperationVerifier(
            MockPowerSensor(_idle_samples()), sleep=_no_sleep
        ),
    )

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.OPERATION
    assert len(grbl.commands) == 2  # 다시 누르지 않았다
    assert safety.reasons and "L3" in safety.reasons[0]


def test_invalid_poll_limit_is_rejected() -> None:
    with pytest.raises(ValueError):
        PowerOperationVerifier(MockPowerSensor(_idle_samples()), max_polls=0)
