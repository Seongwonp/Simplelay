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
    # 기준선 관측(0~2.0초) 뒤 누름마다 한 샘플씩(2.1·2.2초)은 아직 대기이고,
    # 그 뒤부터 가동한다 -- 누르기 전부터 올라 있으면 이번 조작의 결과가 아니다.
    running_after_presses = [PowerSample(2.3 + i / 10, 1200.0) for i in range(60)]
    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes=[True, True]),
        MockAlertSink(),
        MockSafetyController(),
        operation=_Recording(
            MockPowerSensor(_idle_samples(2.3) + running_after_presses), sleep=_no_sleep
        ),
    )

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert order == ["관측시작:누름0회", "판정:누름2회"]


# ── 실기기처럼 시간이 흐르는 센서: 누르는 동안에도 시계가 간다 ──────────────
#
# MockPowerSensor는 누르는 동안 시각이 멈춰 있어서, '누르는 데 걸린 시간이
# 판정 제한시간을 잡아먹는' 결함을 보지 못했다. 아래 조각은 센서를 읽을 때마다
# 0.1초, 버튼 하나를 누를 때마다 press_s초씩 같은 시계를 앞으로 민다.


class _Clock:
    def __init__(self) -> None:
        self.t = 0.0


class _ClockedGrbl(MockGrblClient):
    def __init__(self, clock: _Clock, press_s: float) -> None:
        super().__init__()
        self._clock = clock
        self._press_s = press_s
        self.pressed_at: list[float] = []  # 각 누름이 끝난 시각

    def press(self, command) -> None:
        self._clock.t = round(self._clock.t + self._press_s, 6)
        self.pressed_at.append(self._clock.t)
        super().press(command)


class _ClockedSensor:
    def __init__(self, clock: _Clock, watts_at) -> None:
        self._clock = clock
        self._watts_at = watts_at
        self.reads = 0

    def read(self) -> PowerSample:
        self._clock.t = round(self._clock.t + 0.1, 6)
        self.reads += 1
        return PowerSample(self._clock.t, self._watts_at(self._clock.t))


class _ClockedRetryWaiter:
    """L1 재시도 전 대기에도 시계가 흐른다."""

    def __init__(self, clock: _Clock, wait_s: float) -> None:
        self._clock = clock
        self._wait_s = wait_s

    def wait(self, button: str, retry_number: int) -> None:
        self._clock.t = round(self._clock.t + self._wait_s, 6)


def _clocked_controller(
    watts_at_factory,
    *,
    press_s: float,
    outcomes=(True, True),
    alerts=None,
    retry_wait_s: float = 0.0,
):
    clock = _Clock()
    grbl = _ClockedGrbl(clock, press_s)
    sensor = _ClockedSensor(clock, watts_at_factory(grbl))
    safety = MockSafetyController()
    alerts = alerts or MockAlertSink()
    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes=list(outcomes)),
        alerts,
        safety,
        retry_waiter=_ClockedRetryWaiter(clock, retry_wait_s),
        operation=PowerOperationVerifier(sensor, sleep=_no_sleep, max_polls=400),
    )
    return controller, grbl, sensor, safety, alerts


def test_slow_presses_still_confirm_a_prompt_start() -> None:
    """버튼 이동·누름에 3초씩 걸려도, 마지막 누름 0.5초 뒤 오른 전력은 통과다.

    예전에는 5초 제한이 **누르기 전**부터 흘러 누르는 시간에 다 쓰였다.
    """

    def factory(grbl):
        return lambda t: (
            1200.0 if len(grbl.pressed_at) == 2 and t >= grbl.pressed_at[-1] + 0.5 else 3.0
        )

    controller, grbl, _, safety, _ = _clocked_controller(factory, press_s=3.0)

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED, (
        result.operation.detail if result.operation else safety.reasons
    )
    assert len(grbl.commands) == 2


def test_rise_right_after_a_long_final_press_is_confirmed() -> None:
    """누름이 길어 누르기 전 샘플이 기준선 창 밖으로 밀려도, 곧바로 오른 상승을 판정한다."""

    def factory(grbl):
        return lambda t: (
            1200.0 if len(grbl.pressed_at) == 2 and t >= grbl.pressed_at[-1] else 3.0
        )

    controller, _, _, safety, _ = _clocked_controller(factory, press_s=3.0)

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED, (
        result.operation.detail if result.operation else safety.reasons
    )


def test_power_already_up_before_the_final_press_is_not_credited() -> None:
    """마지막 단계를 누르기 전에 이미 돌고 있던 가전은 이번 조작의 결과가 아니다."""

    def factory(grbl):
        # 첫 버튼(30초)을 누른 직후부터 전력이 올라 있다 -- '시작'을 누르기 전
        return lambda t: 1200.0 if len(grbl.pressed_at) >= 1 else 3.0

    controller, grbl, _, safety, _ = _clocked_controller(factory, press_s=1.0)

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.OPERATION
    assert len(grbl.commands) == 2  # 다시 누르지 않았다
    assert safety.reasons and "L3" in safety.reasons[-1]


def test_retry_of_the_final_button_counts_from_its_first_press() -> None:
    """마지막 버튼의 첫 누름이 실제로는 들어가 전력이 오르는 중에 L1이 재시도하면,

    그 상승은 재시도 전에 시작됐어도 **이 단계**의 결과다.
    """

    def factory(grbl):
        # '시작' 첫 누름(두 번째 명령) 0.5초 뒤부터 가동
        return lambda t: (
            1200.0 if len(grbl.pressed_at) >= 2 and t >= grbl.pressed_at[1] + 0.5 else 3.0
        )

    # 재시도 전 1초 대기 -- 상승(첫 누름 0.5초 뒤)이 재시도 누름보다 **먼저** 시작된다
    controller, grbl, _, safety, _ = _clocked_controller(
        factory, press_s=0.5, outcomes=(True, False, True), retry_wait_s=1.0
    )

    result = controller.execute(["30초", "시작"])

    assert len(grbl.commands) == 3  # 시작을 한 번 더 눌렀다
    assert result.status is ExecutionStatus.SUCCEEDED, (
        result.operation.detail if result.operation else safety.reasons
    )


def test_stop_request_during_l3_wait_is_observed() -> None:
    """버튼을 다 누른 뒤 L3 판정을 기다리는 동안 들어온 정지는 곧바로 반영된다.

    예전 테스트는 기준선을 모으는 중에 정지를 걸어, 판정 대기 코드에 닿지도
    않고 통과했다(판정 대기 중 정지 확인을 지워도 통과).
    """
    stop_at_read: list[int] = []
    sensor_ref: list[_ClockedSensor] = []
    controller: ClosedLoopController

    def factory(grbl):
        polls = [0]

        def watts_at(t: float) -> float:
            # 두 버튼을 다 누르고 판정 대기에서 샘플을 3번 읽은 시점에 정지
            if len(grbl.commands) == 2 and not stop_at_read:
                polls[0] += 1
                if polls[0] == 3:
                    controller.request_stop()
                    stop_at_read.append(sensor_ref[0].reads)
            return 3.0

        return watts_at

    controller, grbl, sensor, safety, alerts = _clocked_controller(factory, press_s=0.5)
    sensor_ref.append(sensor)

    result = controller.execute(["30초", "시작"])

    assert len(grbl.commands) == 2  # 판정 대기까지 갔다
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert stop_at_read, "정지가 판정 대기 중에 걸리지 않았다"
    # 정지 뒤 센서를 더 읽지 않고 멈췄다(제한시간까지 기다리지 않는다)
    assert sensor.reads - stop_at_read[0] <= 1
    # 정지로 중단한 것이라 '동작 확인 실패' 알림은 울리지 않는다
    assert alerts.failures == []
    assert safety.reasons and "emergency stop" in safety.reasons[-1]


def test_a_real_l3_failure_is_still_reported_when_a_stop_arrives_late() -> None:
    """판정이 이미 '확인 안 됨'으로 끝난 뒤 들어온 정지가 실패 알림을 삼키면 안 된다."""
    from rpi.controller import LayerOutcome, OperationVerifier

    controller: ClosedLoopController

    class _FailsThenStopArrives(OperationVerifier):
        def verify_operation(self, buttons):
            controller.request_stop()
            return LayerOutcome(
                VerificationLayer.OPERATION, False, "시작 전력 상승이 확인되지 않음 (테스트)"
            )

    alerts = MockAlertSink()
    controller = ClosedLoopController(
        MockGrblClient(),
        MockVerifier(outcomes=[True]),
        alerts,
        MockSafetyController(),
        operation=_FailsThenStopArrives(),
    )

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.OPERATION
    assert alerts.failures and "동작 확인" in alerts.failures[-1][0]


class _BrokenSensor:
    """정해 준 순번의 읽기에서만 고장 난다(그 밖에는 대기 3 W)."""

    def __init__(self, fail_reads: set[int]) -> None:
        self.fail_reads = set(fail_reads)
        self.reads = 0

    def read(self) -> PowerSample:
        self.reads += 1
        if self.reads in self.fail_reads:
            raise OSError("ADC not responding")
        return PowerSample(self.reads * 0.1, 3.0)


def test_sensor_failure_before_pressing_stops_without_pressing() -> None:
    """누르기 전 관측을 못 하면 L3를 판정할 수 없다 -- 누르지 않고 안전 정지."""
    grbl = MockGrblClient()
    safety = MockSafetyController()
    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes=[True]),
        MockAlertSink(),
        safety,
        # 첫 읽기(누르기 전 관측)만 고장 -- 이걸 삼키면 그 뒤 읽기는 멀쩡해 누르게 된다
        operation=PowerOperationVerifier(_BrokenSensor(fail_reads={1}), sleep=_no_sleep),
    )

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.OPERATION
    assert grbl.commands == []
    assert safety.reasons and "L3" in safety.reasons[-1]


def test_sensor_failure_mid_sequence_stops_before_the_next_press() -> None:
    grbl = MockGrblClient()
    safety = MockSafetyController()
    sensor = _BrokenSensor(fail_reads=set())
    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes=[True, True]),
        MockAlertSink(),
        safety,
        operation=PowerOperationVerifier(sensor, sleep=_no_sleep),
    )
    original_press = grbl.press

    def press_then_break(command):
        original_press(command)
        sensor.fail_reads = {sensor.reads + 1}  # 첫 누름 뒤 다음 읽기(두 번째 누름 직전)에서 고장

    grbl.press = press_then_break

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert [c.button for c in grbl.commands] == ["30초"]  # 고장 뒤에는 누르지 않았다
    assert safety.reasons and "L3" in safety.reasons[-1]


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
