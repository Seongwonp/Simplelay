"""L1~L3 단계별 실행 검증 — 층마다 다른 복구 정책을 못 박는다.

- L1 눌렀는가: 보정해서 다시 누른다(버튼당 max_attempts)
- L2 가전이 받아들였는가: 같은 입력을 정해진 횟수만큼 다시 넣고, 안 되면 안전 정지
- L3 실제로 동작했는가: 시퀀스 끝에 한 번 판정, **자동으로 다시 누르지 않는다**
- L2·L3 검증기가 없으면 종전(L1만) 동작과 같다
"""

import pytest

from rpi.controller import (
    ButtonStatus,
    ClosedLoopController,
    ExecutionStatus,
    LayerOutcome,
    MockAcceptanceVerifier,
    MockOperationVerifier,
    VerificationLayer,
)
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.verifier import MockVerifier


def _controller(press, acceptance=None, operation=None, reinputs=1, grbl=None):
    grbl = grbl or MockGrblClient()
    alerts = MockAlertSink()
    safety = MockSafetyController()
    waiter = MockRetryWaiter()
    controller = ClosedLoopController(
        grbl,
        MockVerifier(press),
        alerts,
        safety,
        retry_waiter=waiter,
        acceptance=acceptance,
        operation=operation,
        acceptance_reinputs=reinputs,
    )
    return controller, grbl, alerts, safety, waiter


def test_without_layer_verifiers_behaviour_is_unchanged() -> None:
    controller, grbl, _, safety, _ = _controller([False, True, True])

    result = controller.execute(["해동", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [b.attempts for b in result.buttons] == [2, 1]
    assert result.failed_layer is None
    assert result.operation is None  # L3를 확인하지 않았다 ≠ 확인해서 통과했다
    assert safety.reasons == []
    assert len(grbl.commands) == 3


def test_l1_retries_with_correction_then_fails_at_l1() -> None:
    controller, grbl, alerts, safety, _ = _controller([False, False, False])

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.PRESS
    [button] = result.buttons
    assert button.failed_layer is VerificationLayer.PRESS
    assert button.attempts == 3
    assert [c.correction is None for c in grbl.commands] == [True, False, False]
    assert alerts.failures == [("시작", 3)]
    assert len(safety.reasons) == 1


def test_l2_is_not_consulted_when_l1_never_confirmed() -> None:
    acceptance = MockAcceptanceVerifier([])
    controller, _, _, _, _ = _controller([False, False, False], acceptance=acceptance)

    controller.execute(["시작"])

    assert acceptance.calls == []


def test_l2_rejection_reinputs_the_same_button_once_then_succeeds() -> None:
    acceptance = MockAcceptanceVerifier([False, True])
    controller, grbl, alerts, safety, waiter = _controller(
        [True, True], acceptance=acceptance
    )

    result = controller.execute(["30초"])

    assert result.status is ExecutionStatus.SUCCEEDED
    [button] = result.buttons
    assert button.status is ButtonStatus.SUCCEEDED
    assert button.reinputs == 1
    assert button.attempts == 2
    # 재입력은 같은 입력이다 -- 보정 요청을 붙이지 않는다.
    assert [c.correction for c in grbl.commands] == [None, None]
    assert acceptance.calls == ["30초", "30초"]
    assert waiter.calls == [("30초", 1)]  # 재입력 경계에서 응답창을 기다린다
    assert alerts.failures == [] and safety.reasons == []


def test_l2_rejected_again_after_reinput_safety_stops_without_more_presses() -> None:
    acceptance = MockAcceptanceVerifier(
        [LayerOutcome(VerificationLayer.ACCEPTANCE, False, "조작음 없음")] * 2
    )
    controller, grbl, alerts, safety, _ = _controller(
        [True, True, True], acceptance=acceptance
    )

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.ACCEPTANCE
    [button] = result.buttons  # 두 번째 버튼은 누르지 않는다
    assert button.failed_layer is VerificationLayer.ACCEPTANCE
    assert button.reinputs == 1
    assert len(grbl.commands) == 2  # 첫 누름 + 재입력 1회
    assert "L2" in safety.reasons[0]
    assert any("조작음 없음" in e for e in button.errors)
    assert alerts.failures == [("30초", 2)]


def test_zero_reinputs_stops_at_first_l2_rejection() -> None:
    acceptance = MockAcceptanceVerifier([False])
    controller, grbl, _, _, _ = _controller([True], acceptance=acceptance, reinputs=0)

    result = controller.execute(["시작"])

    assert result.failed_layer is VerificationLayer.ACCEPTANCE
    assert len(grbl.commands) == 1


def test_l3_confirmed_operation_is_reported_on_success() -> None:
    operation = MockOperationVerifier(
        [LayerOutcome(VerificationLayer.OPERATION, True, "3W → 1,180W")]
    )
    controller, _, _, _, _ = _controller([True, True], operation=operation)

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.operation is not None and result.operation.passed
    assert operation.calls == [("30초", "시작")]  # 시퀀스 끝에 한 번만


def test_l3_failure_stops_and_never_presses_again() -> None:
    operation = MockOperationVerifier(
        [LayerOutcome(VerificationLayer.OPERATION, False, "전력 상승 없음")]
    )
    controller, grbl, alerts, safety, _ = _controller(
        [True, True], operation=operation
    )

    result = controller.execute(["30초", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is VerificationLayer.OPERATION
    assert result.operation is not None and not result.operation.passed
    assert len(grbl.commands) == 2  # 버튼마다 한 번씩만, L3 뒤 재입력 없음
    assert all(b.status is ButtonStatus.SUCCEEDED for b in result.buttons)
    assert "L3" in safety.reasons[0]
    assert alerts.failures == [("동작 확인: 전력 상승 없음", 0)]


def test_stop_request_is_honoured_at_the_reinput_boundary() -> None:
    class _StopOnReject(MockAcceptanceVerifier):
        def __init__(self, controller_ref):
            super().__init__([False, True])
            self._ref = controller_ref

        def verify_acceptance(self, button):
            outcome = super().verify_acceptance(button)
            self._ref[0].request_stop()  # 불수용 판정 직후 사용자가 정지
            return outcome

    ref: list = []
    acceptance = _StopOnReject(ref)
    controller, grbl, _, safety, _ = _controller([True, True], acceptance=acceptance)
    ref.append(controller)

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.failed_layer is None  # 사용자 정지는 층 실패가 아니다
    assert len(grbl.commands) == 1  # 재입력을 누르지 않았다
    assert safety.reasons == ["emergency stop requested"]


def test_stop_request_before_l3_skips_the_operation_check() -> None:
    operation = MockOperationVerifier([True])

    class _StopAfterLastPress(MockGrblClient):
        def __init__(self, ref):
            super().__init__()
            self._ref = ref

        def press(self, command):
            super().press(command)
            self._ref[0].request_stop()

    ref: list = []
    grbl = _StopAfterLastPress(ref)
    controller, _, _, safety, _ = _controller([True], operation=operation, grbl=grbl)
    ref.append(controller)

    result = controller.execute(["시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert operation.calls == []
    assert safety.reasons == ["emergency stop requested"]


def test_presses_per_button_are_bounded_by_attempts_times_rounds() -> None:
    # L1은 매번 두 번째 시도에 확인되고, L2는 끝까지 거절한다.
    acceptance = MockAcceptanceVerifier([False] * 3)
    controller, grbl, _, _, _ = _controller(
        [False, True] * 3, acceptance=acceptance, reinputs=2
    )

    result = controller.execute(["시작"])

    assert result.failed_layer is VerificationLayer.ACCEPTANCE
    assert len(grbl.commands) == 6  # 라운드(1+2) × 라운드당 2회
    assert len(grbl.commands) <= 3 * (1 + 2)


def test_negative_reinputs_is_rejected() -> None:
    with pytest.raises(ValueError):
        _controller([True], reinputs=-1)
