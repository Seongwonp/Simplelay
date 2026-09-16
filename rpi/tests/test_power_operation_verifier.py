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


# ── 기준선은 누르기 전 구간에서 온다 ────────────────────────────────────────


def _running_samples(seconds: float = 6.0, hz: float = 10.0, watts: float = 1200.0):
    """이미 전력이 올라간 뒤부터 시작하는 파형 — 실기기에서 누른 직후의 모습."""
    return [PowerSample(2.0 + i / hz, watts) for i in range(int(seconds * hz))]


def test_baseline_comes_from_samples_taken_before_the_press() -> None:
    """누른 뒤부터 읽으면 조작 전 구간이 비어 '기준선 없음'으로 실패한다.

    실기기 센서는 과거 샘플을 돌려주지 않는다. 컨트롤러가 첫 누름 전에
    begin_observation을 불러 대기 구간을 채워야 상승을 판정할 수 있다.
    """
    verifier = PowerOperationVerifier(
        MockPowerSensor(_idle_samples(2.0) + _running_samples()), sleep=_no_sleep
    )

    verifier.begin_observation()
    outcome = verifier.verify_operation(("시작",))

    assert outcome.passed is True, outcome.detail
    assert "기준선" in outcome.detail

    # 같은 파형을 누른 뒤부터 보기 시작하면 판정할 근거가 없다
    late = PowerOperationVerifier(MockPowerSensor(_running_samples()), sleep=_no_sleep)
    late_outcome = late.verify_operation(("시작",))
    assert late_outcome.passed is False
    assert "기준선 없음" in late_outcome.detail


def test_controller_observes_before_the_first_press() -> None:
    order: list[str] = []

    class _Recording(PowerOperationVerifier):
        def begin_observation(self) -> None:
            order.append(f"관측시작:누름{len(grbl.commands)}회")
            super().begin_observation()

        def verify_operation(self, buttons):
            order.append(f"판정:누름{len(grbl.commands)}회")
            return super().verify_operation(buttons)

    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes=[True, True]),
        MockAlertSink(),
        MockSafetyController(),
        operation=_Recording(
            MockPowerSensor(_idle_samples(2.0) + _running_samples()), sleep=_no_sleep
        ),
    )

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert order == ["관측시작:누름0회", "판정:누름2회"]


def test_stop_request_during_l3_wait_is_observed() -> None:
    """L3는 수십 초를 기다릴 수 있다 — 그동안 정지 요청이 묻히면 안 된다."""
    grbl = MockGrblClient()
    alerts = MockAlertSink()
    safety = MockSafetyController()
    controller: ClosedLoopController

    def _stop_after_first_wait(_s: float) -> None:
        controller.request_stop()

    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes=[True]),
        alerts,
        safety,
        operation=PowerOperationVerifier(
            MockPowerSensor(_idle_samples(60.0)), sleep=_stop_after_first_wait
        ),
    )

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    # 정지로 중단한 것이라 '동작 확인 실패' 알림은 울리지 않는다
    assert alerts.failures == []
    assert safety.reasons and "emergency stop" in safety.reasons[-1]


def test_stop_request_during_baseline_collection_is_observed() -> None:
    """기준선을 모으는 동안에도 정지를 본다 -- 아직 누르기 전인데 기다릴 이유가 없다."""
    stopped = False

    def _should_stop() -> bool:
        return stopped

    reads = 0

    class _CountingSensor:
        def read(self) -> PowerSample:
            nonlocal reads
            reads += 1
            return PowerSample(reads * 0.1, 3.0)

    verifier = PowerOperationVerifier(_CountingSensor(), sleep=_no_sleep)
    verifier.set_stop_check(_should_stop)
    stopped = True

    verifier.begin_observation()

    # 첫 샘플 하나만 읽고 빠져나온다(기준선 창을 다 기다리지 않는다)
    assert reads == 1
