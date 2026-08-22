"""데모 실패 주입 — 재시도 장면·안전 정지 장면·1회용 계약 검증."""

from rpi.controller import ButtonStatus, ClosedLoopController, ExecutionStatus
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.services.demo_failure import DemoFailureState, FailureInjectionVerifier
from rpi.verifier import MockVerifier


def _controller(state: DemoFailureState):
    verifier = FailureInjectionVerifier(MockVerifier([True] * 20), state)
    return ClosedLoopController(
        MockGrblClient(),
        verifier,
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
    )


def test_attempts_1_forces_one_retry_then_succeeds():
    state = DemoFailureState()
    state.arm(button_index=0, attempts=1)

    result = _controller(state).execute(["해동", "시작"])

    # 첫 버튼: 1차 실패(주입) → 보정 재시도 성공. 두 번째 버튼은 정상.
    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.buttons[0].attempts == 2
    assert result.buttons[1].attempts == 1


def test_second_button_can_be_targeted():
    state = DemoFailureState()
    state.arm(button_index=1, attempts=1)

    result = _controller(state).execute(["해동", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.buttons[0].attempts == 1
    assert result.buttons[1].attempts == 2


def test_attempts_3_exhausts_retries_and_safety_stops():
    state = DemoFailureState()
    state.arm(button_index=0, attempts=3)

    result = _controller(state).execute(["해동", "시작"])

    # 재시도 한도(3회) 소진 → 안전 정지, 이후 버튼은 실행되지 않는다
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.buttons[0].status is ButtonStatus.FAILED
    assert len(result.buttons) == 1


def test_injection_is_one_shot():
    state = DemoFailureState()
    controller = _controller(state)
    state.arm(button_index=0, attempts=1)

    first = controller.execute(["해동"])
    second = controller.execute(["해동"])

    assert first.buttons[0].attempts == 2
    # 소진 후 다음 실행은 완전히 정상 — 데모 뒤 실사용에 영향 없음
    assert second.buttons[0].attempts == 1


def test_disarm_cancels_pending_injection():
    state = DemoFailureState()
    state.arm(button_index=0, attempts=2)
    state.disarm()

    result = _controller(state).execute(["해동"])

    assert result.buttons[0].attempts == 1
