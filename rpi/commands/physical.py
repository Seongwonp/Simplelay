"""기존 물리 실행 결과(``ExecutionResult``) → ``CommandResult`` 순수 매핑.

컨트롤러·서비스는 건드리지 않는다. 이 함수는 결과가 나온 **뒤에** 봉투를
씌울 뿐이다. 매핑 규칙(9/27 결정 1 -- L1 눌림은 가전 상태 확인이 아니다):

| ExecutionResult                                   | status      | receipt  | confirmation        |
|---------------------------------------------------|-------------|----------|---------------------|
| SUCCEEDED, 전부 눌림, L3 통과                      | succeeded   | accepted | operation_confirmed |
| SUCCEEDED, 전부 눌림, 버튼별 센서 판정 있음         | succeeded   | accepted | press_confirmed     |
| SUCCEEDED, 전부 눌림, 센서 판정 없음(원격 집계 보고) | succeeded   | accepted | reported            |
| SAFETY_STOPPED, 전부 눌림(센서), L3 실패/미관측     | stopped     | accepted | press_confirmed     |
| SAFETY_STOPPED, 일부만 눌림 또는 0개(로컬)         | stopped     | accepted | none                |
| SAFETY_STOPPED, 원격 집계 보고(합성된 정지)         | failed      | accepted | none                |
| FAILED, 버튼 결과 있음                             | failed      | accepted | none                |
| FAILED, 버튼 결과 없음(예외 종료)                   | unconfirmed | unknown  | none                |

두 줄이 요점이다.

- 마지막 줄: 컨트롤러가 예외로 죽으면(UART 타임아웃 등) 저쪽 보드가 받았는지,
  눌렀는지 모른다. ``failed``로 적으면 "안 눌렸다"는 거짓 사실이 되고 사용자는
  다시 누르게 된다(중복 실행). 확인 불가는 실패가 아니다.
- ``reported`` 줄: 원격 실행기(RPi4 UART·ESP 노드)는 {성공, 재시도}만 집계해
  보고하고 ``synthesize_execution_result``가 버튼별로 **펼쳐 만든다**. 그 결과의
  ``verification``은 전부 None이고, 실패 시 "앞 버튼은 성공, 마지막이 실패"는
  추정이다. 그것을 "센서로 확인" 또는 "'시작'에서 멈춤"으로 적으면 집계 보고가
  센서 근거로 둔갑한다. 여기서는 보고와 직접 근거를 가른다.

``press_confirmed``는 **시퀀스 전체**가 **이쪽 센서로** 눌린 것이 확인됐을 때만이다.

정지는 **요청**과 **확인**이 다르다. ``stopped``는 컨트롤러가 멈춘 것을 스스로
보고한 결과(로컬 폐루프의 SAFETY_STOPPED)에만 붙는다. 원격 집계의 ``success=false``는
``synthesize``가 SAFETY_STOPPED로 **합성**한 것이라 정지 확인이 아니다 -- 실패 보고로
적고, 정지를 요청했다는 사실은 ``stop_requested``에 따로 남긴다.
"""

from __future__ import annotations

from datetime import datetime

from rpi.controller.models import (
    ButtonResult,
    ButtonStatus,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
    VerificationLayer,
)

from .models import (
    Command,
    CommandResult,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)


class EvidenceMismatchError(ValueError):
    """결과의 버튼 라벨이 명령의 시퀀스와 맞지 않는다 -- 다른 실행의 결과다."""


def _sensor_verified(button: ButtonResult) -> bool:
    """이 버튼의 눌림을 **이쪽 센서 판정**으로 확인했나. 집계 보고는 None이다."""
    return (
        button.status is ButtonStatus.SUCCEEDED
        and button.verification is not None
        and button.verification.pressed
    )


def is_aggregate_report(result: ExecutionResult) -> bool:
    """버튼별 센서 판정 없이 집계로만 온 결과인가(원격 실행기 경로)."""
    return bool(result.buttons) and any(b.verification is None for b in result.buttons)


def _complete(result: ExecutionResult, expected_count: int | None) -> bool:
    """시퀀스 **전체**가 성공으로 끝났나(보고 기준).

    결과에 든 버튼만 보면 안 된다 -- 정지가 두 번째 버튼 전에 들어오면 결과에는
    성공한 첫 버튼만 남고, 그것만 보면 '다 눌렸다'가 된다. 명령이 몇 개를
    요구했는지(``expected_count``)와 대조한다.
    """
    if not result.buttons:
        return False
    if expected_count is not None and len(result.buttons) != expected_count:
        return False
    return all(b.status is ButtonStatus.SUCCEEDED for b in result.buttons)


def receipt_of(result: ExecutionResult) -> Receipt:
    """컨트롤러가 이 시퀀스를 받아서 돌렸나.

    버튼별 결과가 하나라도 있거나 정지로 끝났으면 받은 것이다. 근거 없이
    예외로 끝난 FAILED만 모른다 -- 저쪽 보드가 받았을 수도 있다.
    """
    if result.status is ExecutionStatus.FAILED and not result.buttons:
        return Receipt.UNKNOWN
    return Receipt.ACCEPTED


def confirmation_of(
    result: ExecutionResult, expected_count: int | None = None
) -> Confirmation:
    """물리 결과에서 **무슨 근거로 무엇을 확인했는지**만 읽는다.

    ``expected_count``는 명령이 요구한 버튼 수다. 없으면 결과에 든 버튼만으로
    판단하므로, 명령을 아는 호출자는 반드시 넘긴다(``command_result_from_execution``).
    """
    if not _complete(result, expected_count):
        return Confirmation.NONE
    if result.operation is not None and result.operation.passed:
        # L3는 이쪽 전력 센서의 직접 판정이다.
        return Confirmation.OPERATION_CONFIRMED
    if all(_sensor_verified(b) for b in result.buttons):
        return Confirmation.PRESS_CONFIRMED
    # 전부 성공이라고는 하는데 센서 판정이 없다 -- 원격이 집계로 보고한 것.
    return Confirmation.REPORTED


def status_of(result: ExecutionResult) -> CommandStatus:
    if result.status is ExecutionStatus.SUCCEEDED:
        return CommandStatus.SUCCEEDED
    if result.status is ExecutionStatus.SAFETY_STOPPED:
        # 집계 보고의 SAFETY_STOPPED는 합성된 값이다. 원격이 멈췄다고 확인한
        # 것이 아니라 실패했다고 보고한 것이므로 정지로 승격하지 않는다.
        if is_aggregate_report(result):
            return CommandStatus.FAILED
        return CommandStatus.STOPPED
    # FAILED: 근거가 하나도 없으면 실패가 아니라 확인 불가다.
    return CommandStatus.UNCONFIRMED if not result.buttons else CommandStatus.FAILED


def _check_evidence(command: Command, result: ExecutionResult) -> None:
    labels = tuple(b.button for b in result.buttons)
    if labels != command.buttons[: len(labels)]:
        raise EvidenceMismatchError(
            f"result buttons {labels!r} are not a prefix of command buttons {command.buttons!r}"
        )


def _detail(
    result: ExecutionResult,
    receipt: Receipt,
    confirmation: Confirmation,
    stop_requested: bool,
    total: int,
) -> str:
    """사람이 읽을 한 줄. **결과가 말하는 것**만 적는다.

    정지 요청(``stop_requested``)은 원인이 아니라 사실 하나다. 요청이 실행 종료
    뒤에 도착할 수 있고(서비스 주석 "교차 리뷰 #8"), 재시도 소진과 동시에 올 수도
    있다. 플래그에는 요청 시점도, 실행이 그 전에 끝났는지도 없다. 그래서 어떤
    상태에서든 같은 한 마디("정지 요청 있음")만 덧붙이고, 원인·순서·종료 여부는
    말하지 않는다.
    """
    # total은 **명령이 요구한** 버튼 수다. 결과에 든 버튼 수로 세면 정지로 잘린
    # 시퀀스가 '1개 중 1개'가 되어 다 눌린 것처럼 읽힌다.
    stopped = result.status is ExecutionStatus.SAFETY_STOPPED and not is_aggregate_report(result)
    note = " · 정지 요청 있음" if stop_requested else ""

    if receipt is Receipt.UNKNOWN:
        return "실행기 응답이 없어 눌렸는지 알 수 없어요 -- 자동으로 다시 누르지 않아요" + note
    if confirmation is Confirmation.OPERATION_CONFIRMED:
        return "버튼 눌림과 가전 동작을 확인했어요" + note
    if confirmation is Confirmation.REPORTED:
        return "실행기가 완료를 보고했어요 (이쪽 센서 근거 없음, 가전 동작은 확인하지 않음)" + note
    if confirmation is Confirmation.PRESS_CONFIRMED:
        if result.failed_layer is VerificationLayer.OPERATION:
            reason = result.operation.detail if result.operation is not None else "판정 불가"
            return f"버튼은 모두 눌렸지만 가전 동작을 확인하지 못했어요 (L3: {reason})" + note
        if stopped:
            return "버튼은 모두 눌렸지만 실행을 멈췄어요 (가전 동작은 확인하지 않음)" + note
        return "버튼 눌림을 센서로 확인했어요 (가전 동작은 확인하지 않음)" + note

    # confirmation NONE -- 시퀀스가 끝나지 않았다.
    if is_aggregate_report(result):
        # 집계 보고: 어느 버튼에서 멈췄는지, 몇 개가 눌렸는지, 멈췄는지는 보고에 없다.
        # synthesize가 채운 버튼별 값은 추정이므로 사실로 적지 않는다.
        retries = sum(max(0, b.attempts - 1) for b in result.buttons)
        return (
            f"실행기가 실패를 보고했어요 (재시도 {retries}회 보고, "
            "멈춘 버튼·눌림 개수·정지 여부는 보고되지 않음)"
        ) + note
    pressed = sum(1 for b in result.buttons if _sensor_verified(b))
    counts = f"{total}개 중 {pressed}개 눌림 확인"
    verb = "멈췄어요" if stopped else "실패했어요"
    if not result.buttons:
        return f"실행 시작 전에 {verb} ({counts})" + note
    failed = next((b for b in result.buttons if b.status is ButtonStatus.FAILED), None)
    if failed is not None:
        layer = failed.failed_layer.value if failed.failed_layer is not None else "L1"
        return f"'{failed.button}'에서 {verb} ({layer}, {failed.attempts}회 시도, {counts})" + note
    # 실패한 버튼 없이 도중에 끊겼다 -- 일부 실행 후 중단. '시작 전'이 아니다.
    last = result.buttons[-1].button
    return f"'{last}' 뒤에서 {verb} ({counts})" + note


def command_result_from_execution(
    command: Command,
    result: ExecutionResult,
    *,
    execution_mode: ExecutionMode,
    requested_at: datetime | None = None,
    accepted_at: datetime | None = None,
    observed_at: datetime | None = None,
    stopped_by_user: bool = False,
) -> CommandResult:
    """물리 실행 결과에 명령 봉투를 씌운다. 근거(``ExecutionResult``)는 통째로 보존.

    ``execution_mode``는 호출자가 **실행한 컨트롤러에서 읽어** 넘긴다 -- 이
    함수가 추측하지 않는다(기존 ``_mode_of`` 규칙). ``observed_at``은 결과를
    관측한 시각이고, ``accepted_at``은 상대가 접수를 알린 시각을 **아는 경우에만**
    넘긴다. 관측 시각으로 접수 시각을 채우지 않는다. 근거 확인 시각
    (``confirmed_at``)은 ``ExecutionResult``에 없으므로 비워 둔다.
    """
    if command.route is not ControlRoute.PHYSICAL:
        raise ValueError("only physical commands map from ExecutionResult")
    _check_evidence(command, result)
    receipt = receipt_of(result)
    if accepted_at is not None and receipt is not Receipt.ACCEPTED:
        raise ValueError("accepted_at given but the result does not show a receipt")
    confirmation = confirmation_of(result, expected_count=len(command.buttons))
    status = status_of(result)
    return CommandResult(
        command=command,
        status=status,
        receipt=receipt,
        confirmation=confirmation,
        execution_mode=execution_mode,
        detail=_detail(result, receipt, confirmation, stopped_by_user, len(command.buttons)),
        requested_at=requested_at,
        accepted_at=accepted_at,
        confirmed_at=None,
        observed_at=observed_at,
        stop_requested=stopped_by_user,
        physical=result,
    )
