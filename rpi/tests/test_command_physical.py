"""기존 ExecutionResult → CommandResult 순수 매핑 (U1-a, 9/27 결정 1).

- L1 눌림 확인은 press_confirmed까지다. 가전 상태 확인으로 올리지 않는다.
- 컨트롤러 예외(근거 없음)는 failed가 아니라 unconfirmed + receipt unknown이다.
- 원격 집계 보고(버튼별 verification None)는 센서 근거가 아니다 -- reported.
"""

from datetime import datetime, timedelta, timezone

import pytest

from rpi.commands import (
    Command,
    CommandStatus,
    Confirmation,
    EvidenceMismatchError,
    Receipt,
    command_result_from_execution,
    confirmation_of,
    status_of,
)
from rpi.commands.physical import is_aggregate_report, receipt_of
from rpi.controller.models import (
    ButtonResult,
    ButtonStatus,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
    LayerOutcome,
    VerificationLayer,
)
from rpi.services.aggregate_result import synthesize_execution_result
from rpi.verifier import VerificationResult

KST = timezone(timedelta(hours=9))
T0 = datetime(2026, 9, 27, 14, 0, tzinfo=KST)
T1 = T0 + timedelta(seconds=8)
CMD = Command.physical("microwave", ["즉석밥", "시작"])


def ok(button, attempts=1):
    return ButtonResult(button, ButtonStatus.SUCCEEDED, attempts, VerificationResult(True, 0.9))


def fail(button, attempts=3, layer=VerificationLayer.PRESS):
    return ButtonResult(
        button, ButtonStatus.FAILED, attempts, VerificationResult(False, 0.2), failed_layer=layer
    )


def convert(result, **kw):
    kw.setdefault("execution_mode", ExecutionMode.MOCK)
    return command_result_from_execution(CMD, result, requested_at=T0, observed_at=T1, **kw)


# ── 센서 근거가 있는 로컬 폐루프 ─────────────────────────────────────────────

def test_l1_success_without_l3_is_press_confirmed_not_state():
    result = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")))
    out = convert(result)
    assert out.status is CommandStatus.SUCCEEDED
    assert out.receipt is Receipt.ACCEPTED
    assert out.confirmation is Confirmation.PRESS_CONFIRMED
    assert out.confirmation.has_evidence and not out.confirmation.confirms_appliance
    assert "센서로 확인" in out.detail and "가전 동작은 확인하지 않음" in out.detail


def test_l3_pass_is_operation_confirmed():
    result = ExecutionResult(
        ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")),
        operation=LayerOutcome(VerificationLayer.OPERATION, True, "전력 상승"),
    )
    out = convert(result)
    assert out.status is CommandStatus.SUCCEEDED
    assert out.confirmation is Confirmation.OPERATION_CONFIRMED
    assert out.confirmation.confirms_appliance


def test_l3_failure_keeps_press_confirmed_and_stops():
    outcome = LayerOutcome(VerificationLayer.OPERATION, False, "전력 변화 없음")
    result = ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"), ok("시작")),
        failed_layer=VerificationLayer.OPERATION, operation=outcome,
    )
    out = convert(result)
    assert out.status is CommandStatus.STOPPED
    assert out.confirmation is Confirmation.PRESS_CONFIRMED
    assert "전력 변화 없음" in out.detail
    # 근거 보존: L3 판정과 실패 층이 그대로 남는다.
    assert out.physical is result
    assert out.physical.operation is outcome
    assert out.physical.failed_layer is VerificationLayer.OPERATION


def test_l3_unobservable_is_press_confirmed_with_reason():
    result = ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"), ok("시작")),
        failed_layer=VerificationLayer.OPERATION, operation=None,
    )
    out = convert(result)
    assert out.confirmation is Confirmation.PRESS_CONFIRMED
    assert "판정 불가" in out.detail


def test_partial_press_has_no_confirmation_but_counts_sensor_presses():
    result = ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"), fail("시작")),
        failed_layer=VerificationLayer.PRESS,
    )
    out = convert(result)
    assert out.status is CommandStatus.STOPPED
    assert out.receipt is Receipt.ACCEPTED
    assert out.confirmation is Confirmation.NONE
    assert "'시작'에서 멈췄어요" in out.detail and "L1" in out.detail and "2개 중 1개" in out.detail
    # 버튼별 L1·재시도 근거 보존
    assert [b.attempts for b in out.buttons] == [1, 3]


def test_l2_failure_layer_is_reported():
    result = ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED,
        (ok("즉석밥"), fail("시작", layer=VerificationLayer.ACCEPTANCE)),
        failed_layer=VerificationLayer.ACCEPTANCE,
    )
    assert "L2" in convert(result).detail


def test_stop_before_first_press_is_accepted_with_zero_presses():
    result = ExecutionResult(ExecutionStatus.SAFETY_STOPPED, ())
    out = convert(result, stopped_by_user=True)
    assert out.status is CommandStatus.STOPPED
    assert out.receipt is Receipt.ACCEPTED
    assert out.confirmation is Confirmation.NONE
    assert out.stop_requested is True
    assert "실행 시작 전에 멈췄어요" in out.detail and "2개 중 0개" in out.detail
    assert "정지 요청 있음" in out.detail and "사용자 정지로" not in out.detail


def test_stop_after_first_button_is_not_press_confirmed():
    # 정지가 두 번째 버튼 전에 들어오면 결과에는 성공한 첫 버튼만 남는다.
    # 결과만 보면 '다 눌렸다'가 되므로 명령의 시퀀스 길이와 대조해야 한다.
    partial = ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"),))
    out = convert(partial, stopped_by_user=True)
    assert out.confirmation is Confirmation.NONE
    assert "2개 중 1개" in out.detail
    # 일부 실행 후 중단은 '시작 전'이 아니다.
    assert "시작 전" not in out.detail
    assert "'즉석밥' 뒤에서 멈췄어요" in out.detail and "정지 요청 있음" in out.detail


def test_partial_stop_without_user_request_is_attributed_to_executor():
    partial = ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"),))
    out = convert(partial)
    assert out.stop_requested is False
    assert "'즉석밥' 뒤에서 멈췄어요" in out.detail and "정지 요청" not in out.detail
    # 결과만 넘긴 순수 함수는 명령을 모르므로 호출자가 개수를 줘야 한다.
    assert confirmation_of(partial) is Confirmation.PRESS_CONFIRMED
    assert confirmation_of(partial, expected_count=2) is Confirmation.NONE


def test_user_stop_after_all_presses_keeps_press_confirmed():
    result = ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"), ok("시작")))
    out = convert(result, stopped_by_user=True)
    assert out.status is CommandStatus.STOPPED
    assert out.confirmation is Confirmation.PRESS_CONFIRMED
    assert "실행을 멈췄어요" in out.detail and "정지 요청 있음" in out.detail
    # 요청이 있었다는 사실만 적는다. 재시도 소진과 겹칠 수 있어 원인으로 단정하지 않는다.
    assert "사용자 정지로" not in out.detail


# ── 늦은 정지 요청: 완료 결과를 정지 문구로 덮지 않는다 ─────────────────────

def test_late_stop_request_does_not_overwrite_a_completed_result():
    # 실행이 SUCCEEDED로 끝난 뒤(또는 반환 직전) 정지 요청이 도착한 경우.
    result = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")))
    out = convert(result, stopped_by_user=True)
    assert out.status is CommandStatus.SUCCEEDED
    assert out.confirmation is Confirmation.PRESS_CONFIRMED
    assert out.stop_requested is True  # 요청 기록은 남는다
    assert "센서로 확인" in out.detail
    assert "멈췄어요" not in out.detail and "사용자 정지" not in out.detail
    # 요청 사실만. 요청이 실행 종료 뒤였는지는 플래그로 알 수 없으므로 말하지 않는다.
    assert out.detail.endswith(" · 정지 요청 있음")
    assert "이미 끝남" not in out.detail


def test_late_stop_request_on_l3_confirmed_success():
    result = ExecutionResult(
        ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")),
        operation=LayerOutcome(VerificationLayer.OPERATION, True, "전력 상승"),
    )
    out = convert(result, stopped_by_user=True)
    assert out.status is CommandStatus.SUCCEEDED
    assert out.detail.startswith("버튼 눌림과 가전 동작을 확인했어요")
    assert out.detail.endswith(" · 정지 요청 있음") and "이미 끝남" not in out.detail


def test_late_stop_request_on_failed_result_is_a_note_not_a_cause():
    result = ExecutionResult(ExecutionStatus.FAILED, (fail("즉석밥"),))
    out = convert(result, stopped_by_user=True)
    assert out.status is CommandStatus.FAILED
    assert "'즉석밥'에서 실패했어요" in out.detail
    assert "멈췄어요" not in out.detail and "이미 끝남" not in out.detail
    assert out.detail.endswith(" · 정지 요청 있음")


def test_stop_request_note_is_identical_across_states():
    # 상태가 무엇이든 부가 문구는 같은 한 마디다 -- 플래그가 말할 수 있는 전부다.
    cases = [
        ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작"))),
        ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"),)),
        ExecutionResult(ExecutionStatus.FAILED, (fail("즉석밥"),)),
        ExecutionResult(ExecutionStatus.FAILED, ()),
        synthesize_execution_result(["즉석밥", "시작"], False, 1),
    ]
    for result in cases:
        with_note = convert(result, stopped_by_user=True).detail
        without = convert(result).detail
        assert with_note == without + " · 정지 요청 있음"


def test_unknown_receipt_with_stop_request_asserts_neither_end_nor_stop():
    # 컨트롤러가 예외로 죽었고 정지도 요청됐다: 받았는지·멈췄는지·끝났는지 전부 모른다.
    out = convert(ExecutionResult(ExecutionStatus.FAILED, ()), stopped_by_user=True)
    assert out.status is CommandStatus.UNCONFIRMED
    assert out.receipt is Receipt.UNKNOWN
    assert out.stop_requested is True
    assert "알 수 없어요" in out.detail and out.detail.endswith(" · 정지 요청 있음")
    for forbidden in ("멈췄어요", "끝남", "완료", "사용자 정지로"):
        assert forbidden not in out.detail


def test_success_with_unpressed_verification_is_not_sensor_confirmed():
    # 상태는 SUCCEEDED인데 검증 객체가 '안 눌림'이라면 센서 근거로 볼 수 없다.
    odd = ButtonResult("시작", ButtonStatus.SUCCEEDED, 1, VerificationResult(False, 0.1))
    result = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), odd))
    assert convert(result).confirmation is Confirmation.REPORTED


# ── 예외 종료 ────────────────────────────────────────────────────────────────

def test_controller_exception_is_unconfirmed_with_unknown_receipt():
    # service._run_job이 예외 시 만드는 형태: FAILED + 버튼 근거 없음.
    result = ExecutionResult(ExecutionStatus.FAILED, ())
    out = convert(result, execution_mode=ExecutionMode.UNKNOWN)
    assert out.status is CommandStatus.UNCONFIRMED
    assert out.receipt is Receipt.UNKNOWN
    assert out.confirmation is Confirmation.NONE
    assert out.accepted_at is None and out.confirmed_at is None
    assert out.observed_at == T1
    assert "다시 누르지 않아요" in out.detail
    assert out.execution_mode is ExecutionMode.UNKNOWN


def test_failed_with_evidence_stays_failed_but_accepted():
    result = ExecutionResult(ExecutionStatus.FAILED, (fail("즉석밥"),))
    out = convert(result)
    assert out.status is CommandStatus.FAILED
    assert out.receipt is Receipt.ACCEPTED
    assert out.confirmation is Confirmation.NONE


# ── 원격 집계 보고(UART·노드): 센서 근거가 아니다 ────────────────────────────

def test_aggregate_success_is_reported_not_press_confirmed():
    success = synthesize_execution_result(["즉석밥", "시작"], True, 0)
    assert is_aggregate_report(success)
    out = convert(success)
    assert out.status is CommandStatus.SUCCEEDED
    assert out.receipt is Receipt.ACCEPTED
    assert out.confirmation is Confirmation.REPORTED
    assert not out.confirmation.has_evidence
    assert "보고" in out.detail and "센서" not in out.detail.split("(")[0]
    assert "센서로 확인" not in out.detail


def test_aggregate_failure_is_a_failure_report_not_a_confirmed_stop():
    # synthesize는 success=false를 SAFETY_STOPPED로 **합성**한다. 원격이 멈췄다고
    # 확인한 것이 아니므로 stopped로 승격하지 않는다.
    failure = synthesize_execution_result(["즉석밥", "시작"], False, 2)
    assert failure.status is ExecutionStatus.SAFETY_STOPPED  # 합성된 입력임을 고정
    out = convert(failure)
    assert out.status is CommandStatus.FAILED
    assert out.stop_requested is False
    assert status_of(failure) is CommandStatus.FAILED


def test_aggregate_failure_does_not_claim_button_position_or_press_count():
    failure = synthesize_execution_result(["즉석밥", "시작"], False, 2)
    out = convert(failure)
    assert out.receipt is Receipt.ACCEPTED
    assert out.confirmation is Confirmation.NONE
    # synthesize가 채운 '즉석밥 성공, 시작 실패'는 추정이다 -- 문구에 쓰지 않는다.
    assert "'시작'에서" not in out.detail
    assert "눌림 확인" not in out.detail
    assert "재시도 2회 보고" in out.detail and "보고되지 않음" in out.detail
    # 원본은 그대로 보존된다(추정임을 아는 쪽이 해석한다).
    assert out.buttons[-1].attempts == 3 and out.buttons[-1].verification is None


def test_aggregate_failure_with_user_stop_separates_request_from_confirmation():
    failure = synthesize_execution_result(["즉석밥", "시작"], False, 0)
    out = convert(failure, stopped_by_user=True)
    # 요청은 남기되 정지가 확인됐다고 말하지 않는다.
    assert out.stop_requested is True
    assert out.status is CommandStatus.FAILED
    assert "실패를 보고" in out.detail and out.detail.endswith(" · 정지 요청 있음")
    assert "멈췄어요" not in out.detail and "'시작'에서" not in out.detail
    assert "정지 여부는 보고되지 않음" in out.detail
    # 집계 보고에는 종료·정지 근거가 없다 -- 어느 쪽도 단정하지 않는다.
    for forbidden in ("끝남", "완료", "사용자 정지로"):
        assert forbidden not in out.detail


def test_local_safety_stop_is_a_confirmed_stop():
    # 로컬 폐루프의 SAFETY_STOPPED는 컨트롤러가 스스로 멈춘 것이라 stopped다.
    local = ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (ok("즉석밥"), fail("시작")))
    assert status_of(local) is CommandStatus.STOPPED
    assert convert(local).status is CommandStatus.STOPPED


def test_local_results_are_not_aggregate():
    assert not is_aggregate_report(ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작"))))
    assert not is_aggregate_report(ExecutionResult(ExecutionStatus.FAILED, ()))


# ── 시각 ────────────────────────────────────────────────────────────────────

def test_observed_at_is_not_used_as_accepted_at():
    result = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")))
    out = convert(result)
    assert out.observed_at == T1
    assert out.accepted_at is None and out.confirmed_at is None


def test_accepted_at_is_kept_only_when_caller_knows_it():
    result = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")))
    out = convert(result, accepted_at=T0 + timedelta(seconds=1))
    assert out.accepted_at == T0 + timedelta(seconds=1)
    with pytest.raises(ValueError, match="accepted_at"):
        convert(ExecutionResult(ExecutionStatus.FAILED, ()), accepted_at=T0)


# ── 실행 환경 축 독립 ────────────────────────────────────────────────────────

@pytest.mark.parametrize("mode", list(ExecutionMode))
def test_execution_mode_is_passed_through_not_inferred(mode):
    result = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")))
    out = convert(result, execution_mode=mode)
    assert out.execution_mode is mode
    assert out.confirmation is Confirmation.PRESS_CONFIRMED


# ── 근거 대조 ────────────────────────────────────────────────────────────────

def test_evidence_from_another_command_is_rejected():
    other = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("해동"), ok("시작")))
    with pytest.raises(EvidenceMismatchError):
        convert(other)


def test_success_without_any_button_evidence_is_inconsistent():
    with pytest.raises(ValueError, match="succeeded"):
        convert(ExecutionResult(ExecutionStatus.SUCCEEDED, ()))


def test_non_physical_command_cannot_be_mapped():
    cloud = Command.thinq("purifier", "fan_speed", {"level": 3})
    with pytest.raises(ValueError, match="physical"):
        command_result_from_execution(
            cloud, ExecutionResult(ExecutionStatus.SUCCEEDED, ()), execution_mode=ExecutionMode.MOCK
        )


# ── 순수 함수 단독 ───────────────────────────────────────────────────────────

def test_pure_functions_are_consistent():
    r = ExecutionResult(ExecutionStatus.SUCCEEDED, (ok("즉석밥"), ok("시작")))
    assert receipt_of(r) is Receipt.ACCEPTED
    assert confirmation_of(r) is Confirmation.PRESS_CONFIRMED
    assert status_of(r) is CommandStatus.SUCCEEDED
    gone = ExecutionResult(ExecutionStatus.FAILED, ())
    assert receipt_of(gone) is Receipt.UNKNOWN
    assert status_of(gone) is CommandStatus.UNCONFIRMED
    assert status_of(ExecutionResult(ExecutionStatus.FAILED, (fail("x"),))) is CommandStatus.FAILED
