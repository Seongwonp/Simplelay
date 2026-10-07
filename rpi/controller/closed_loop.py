"""Closed-loop orchestration with bounded recovery and fail-safe behavior."""

import logging
import threading
from collections.abc import Callable, Mapping

from rpi.verifier import SensorUnavailable, VerificationResult, Verifier

from .layered import (
    DEFAULT_ACCEPTANCE_REINPUTS,
    OPERATION_STOPPED_DETAIL,
    AcceptanceVerifier,
    OperationVerifier,
)
from .models import (
    ButtonResult,
    ButtonStatus,
    ButtonTarget,
    ExecutionMode,
    ExecutionProgress,
    ExecutionResult,
    ExecutionStatus,
    PressCommand,
    VerificationLayer,
)
from .ports import AlertSink, GrblClient, NoOpRetryWaiter, RetryWaiter, SafetyController
from .progress import ProgressCallback
from .retry import DocumentedRetryPolicy, RetryPolicy

log = logging.getLogger(__name__)

#: 누름 관찰자(``set_press_observer``)가 받는 단계 이름.
PRESS_PHASES = ("retry", "move", "press", "verify", "accept")


class _EmergencyStopRequested(Exception):
    """Internal control-flow signal: a stop was requested mid-execution."""


class MissingButtonCoordinates(ValueError):
    """좌표가 필요한 모션 어댑터인데 시퀀스의 일부 버튼에 좌표가 없다.

    **아무것도 누르기 전에** 거절한다. 중간 버튼에서 알게 되면 앞 단계가 이미
    눌려 반쯤 설정된 가전이 남는다(appliance_registry.validate_functions와 같은 이유).
    """

    def __init__(self, missing: tuple[str, ...]) -> None:
        self.missing = missing
        super().__init__(
            "좌표(x_mm, y_mm)가 없는 버튼이 있어 실행을 거절합니다: "
            + ", ".join(missing)
            + " — 먼저 보정(PUT /appliances/{id}/calibration)으로 좌표를 기록해 주세요"
        )


class _OperationObservationFailed(Exception):
    """L3 관측(전력 센서 읽기)이 실패했다 — 확인할 수 없으니 더 누르지 않는다."""


class _PressObservationFailed(Exception):
    """L1 누름 센서(전류·마이크)를 읽을 수 없다 — 단절은 '안 눌림'이 아니라 다시 누르지 않는다."""

    def __init__(self, result: ButtonResult) -> None:
        super().__init__(result.errors[-1] if result.errors else "press sensor unavailable")
        self.result = result


class ClosedLoopController:
    #: execute()가 ``targets``(버튼별 좌표)를 받는다. 서비스는 이 표시가 있는
    #: 대상에만 좌표를 넘긴다 -- 다른 ButtonSequenceController 구현은 모른다.
    supports_button_targets = True

    def __init__(
        self,
        grbl: GrblClient,
        verifier: Verifier,
        alerts: AlertSink,
        safety: SafetyController,
        retry_policy: RetryPolicy | None = None,
        retry_waiter: RetryWaiter | None = None,
        on_progress: ProgressCallback | None = None,
        step_pacer: Callable[[str, int], None] | None = None,
        acceptance: AcceptanceVerifier | None = None,
        operation: OperationVerifier | None = None,
        acceptance_reinputs: int = DEFAULT_ACCEPTANCE_REINPUTS,
    ) -> None:
        if acceptance_reinputs < 0:
            raise ValueError("acceptance_reinputs must not be negative")
        self._grbl = grbl
        self._verifier = verifier
        self._alerts = alerts
        self._safety = safety
        self._retry_policy = retry_policy or DocumentedRetryPolicy()
        self._retry_waiter = retry_waiter or NoOpRetryWaiter()
        self._on_progress = on_progress
        self._step_pacer = step_pacer
        # L2·L3 검증기는 선택이다(layered.py). 없으면 L1만 쓰는 종전 동작.
        self._acceptance = acceptance
        self._operation = operation
        self._acceptance_reinputs = acceptance_reinputs
        # /stop(긴급 정지)용. 실행은 별도 스레드(asyncio.to_thread)에서 돌고
        # 정지 요청은 FastAPI 요청 스레드에서 오므로 threading.Event를 쓴다.
        self._stop_requested = threading.Event()
        # 이번 execute()의 버튼 → 좌표. 실행은 한 번에 하나라 인스턴스에 둔다.
        self._targets: dict[str, ButtonTarget] = {}
        if operation is not None:
            # L3가 판정을 기다리는 동안에도 정지 요청을 볼 수 있게 한다.
            operation.set_stop_check(self._stop_requested.is_set)
        # 누름 단계 관찰자(선택). RPi4 ActExecutor가 progress 프레임으로 내보낸다.
        self._press_observer: Callable[[dict], None] | None = None

    @property
    def operation(self) -> OperationVerifier | None:
        """지금 꽂힌 L3 판정기(없으면 None)."""
        return self._operation

    def use_operation(self, operation: OperationVerifier | None) -> None:
        """다음 execute()의 L3 판정기를 바꾼다 — **실행과 실행 사이에만** 부른다.

        RPi4 실행기가 실행 대상 가전마다 그 가전 CT 채널의 판정기를 고른다(2026-10-07, 평가 H3).
        None이면 L3 판정 없음(결과의 operation은 None).
        """
        self._operation = operation
        if operation is not None:
            operation.set_stop_check(self._stop_requested.is_set)

    def set_press_observer(self, observer: "Callable[[dict], None] | None") -> None:
        """누름 시도마다 단계 이벤트를 받을 함수를 건다(실행 스레드에서 호출된다).

        이벤트 모양: ``{"phase", "button", "step_index", "attempt", ...}`` —
        ``retry``(보정 요청), ``move``(누름 명령 직전, 좌표 ``target``), ``press``(어댑터 반환,
        ``ok``·``error``·어댑터가 아는 ``position``), ``verify``(L1 ``pressed``), ``accept``(L2).
        관찰은 결과를 바꾸지 않는다. 관찰자 예외는 로그만 남긴다.
        """
        self._press_observer = observer

    @property
    def execution_mode(self) -> ExecutionMode:
        """이 컨트롤러가 실제 액추에이터를 움직였는가.

        판단은 **자기가 쥔 클라이언트**에게 묻는다. 서버 전역 설정으로
        정하면, 같은 서버가 로컬 mock과 원격 실기기를 함께 쓰는 통합
        기간에 이력이 둘을 섞어버린다.
        """
        return getattr(
            self._grbl, "execution_mode", ExecutionMode.UNKNOWN
        )

    def request_stop(self) -> None:
        """Ask a running execute() to safety-stop at the next button/attempt
        boundary.

        모션 어댑터가 ``request_stop``을 가지면 **즉시** 함께 부른다 -- 블로킹
        누름(이동·Z 하강) 도중에도 정지 명령이 MCU로 나가야 한다
        (docs/하드웨어-연결-설계.md §2 "이동 중 정지"). 플래그를 먼저 세워서,
        어댑터가 중단 예외로 돌아오면 재시도하지 않고 다음 경계에서 멈춘다.
        """
        self._stop_requested.set()
        adapter_stop = getattr(self._grbl, "request_stop", None)
        if callable(adapter_stop):
            adapter_stop()

    def reset_stop(self) -> None:
        """Discard any stale stop request. 호출 책임은 '실행을 시작시키는 쪽'
        (SimpleLayService._begin_run, ActExecutor)에 있다 — execute()가
        스스로 clear하면, job 접수 직후 스레드가 뜨기 전에 들어온 정지
        요청이 시작 시점에 지워져 유실된다(리뷰 지적 #5)."""
        self._stop_requested.clear()
        adapter_reset = getattr(self._grbl, "reset_stop", None)
        if callable(adapter_reset):
            adapter_reset()

    def execute(
        self,
        buttons: list[str] | tuple[str, ...],
        targets: Mapping[str, ButtonTarget] | None = None,
    ) -> ExecutionResult:
        """``targets``: 버튼 → 갠트리 좌표(mm). 없으면 좌표 없는 종전 명령을 보낸다.

        어댑터가 ``requires_coordinates``를 밝히면(실제 모션 어댑터) 좌표 없는
        버튼이 하나라도 있을 때 누르기 전에 `MissingButtonCoordinates`로 거절한다.
        """
        targets = dict(targets or {})
        if getattr(self._grbl, "requires_coordinates", False) is True:
            missing = tuple(dict.fromkeys(b for b in buttons if b not in targets))
            if missing:
                raise MissingButtonCoordinates(missing)
        self._targets = targets
        results: list[ButtonResult] = []
        completed_steps = 0
        self._operation_observing = False
        for button in buttons:
            try:
                self._check_stop()
                result = self._execute_button(button, completed_steps)
            except _EmergencyStopRequested:
                self._safety.stop("emergency stop requested")
                return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, tuple(results))
            except _OperationObservationFailed as exc:
                return self._stop_for_unobservable_operation(
                    exc.__cause__ or exc, tuple(results)
                )
            except _PressObservationFailed as exc:
                # 센서 단절 — 보정 재시도로 다시 누르지 않고 멈춘다.
                results.append(exc.result)
                self._safety.stop(f"L1 press sensor unavailable for {button}: {exc}")
                self._alerts.notify_failure(button, exc.result.attempts)
                return ExecutionResult(
                    ExecutionStatus.SAFETY_STOPPED,
                    tuple(results),
                    failed_layer=VerificationLayer.PRESS,
                )
            results.append(result)
            if result.status is ButtonStatus.SUCCEEDED:
                completed_steps += 1
            if result.status is ButtonStatus.FAILED:
                if result.failed_layer is VerificationLayer.ACCEPTANCE:
                    reason = (
                        f"L2 appliance did not accept {button} after "
                        f"{result.reinputs} re-input(s)"
                    )
                else:
                    reason = f"verification failed for {button} after {result.attempts} attempts"
                self._safety.stop(reason)
                self._alerts.notify_failure(button, result.attempts)
                return ExecutionResult(
                    ExecutionStatus.SAFETY_STOPPED,
                    tuple(results),
                    failed_layer=result.failed_layer,
                )
        return self._verify_operation(tuple(buttons), tuple(results))

    def _verify_operation(
        self, buttons: tuple[str, ...], results: tuple[ButtonResult, ...]
    ) -> ExecutionResult:
        """L3 — 시퀀스를 다 넣은 뒤 한 번만 판정한다. 실패해도 다시 누르지 않는다."""
        if self._operation is None:
            return ExecutionResult(ExecutionStatus.SUCCEEDED, results)
        try:
            self._check_stop()
        except _EmergencyStopRequested:
            self._safety.stop("emergency stop requested")
            return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, results)
        try:
            outcome = self._operation.verify_operation(buttons)
        except Exception as exc:  # noqa: BLE001 - 센서 고장은 종류와 무관하게 fail closed
            return self._stop_for_unobservable_operation(exc, results)
        if not outcome.passed and outcome.detail == OPERATION_STOPPED_DETAIL:
            # 정지 때문에 판정을 못 끝낸 것이라, 실패 알림을 울리지 않는다.
            # 정지 요청 여부(플래그)로 가르지 않는다 -- 판정이 이미 실패로
            # 끝난 뒤 들어온 정지가 '동작 확인 안 됨' 알림을 삼키게 된다.
            self._safety.stop("emergency stop requested")
            return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, results)
        if outcome.passed:
            return ExecutionResult(
                ExecutionStatus.SUCCEEDED, results, operation=outcome
            )
        self._safety.stop(f"L3 operation not confirmed: {outcome.detail}")
        self._alerts.notify_operation_unconfirmed(outcome.detail)
        return ExecutionResult(
            ExecutionStatus.SAFETY_STOPPED,
            results,
            failed_layer=VerificationLayer.OPERATION,
            operation=outcome,
        )

    def _stop_for_unobservable_operation(
        self, exc: BaseException, results: tuple[ButtonResult, ...]
    ) -> ExecutionResult:
        """L3를 확인할 수단(센서)이 없다 — 누른 것까지만 두고 멈춘 뒤 알린다."""
        self._safety.stop(f"L3 power sensor unavailable: {exc}")
        self._alerts.notify_operation_unconfirmed(f"전력 센서를 읽지 못함: {exc}")
        return ExecutionResult(
            ExecutionStatus.SAFETY_STOPPED,
            results,
            failed_layer=VerificationLayer.OPERATION,
        )

    def _execute_button(self, button: str, completed_steps: int) -> ButtonResult:
        """버튼 하나: L1(보정 재시도) → L2(불수용이면 같은 입력 재입력).

        누름 횟수 상한은 ``max_attempts × (1 + acceptance_reinputs)``다 --
        재입력 한 번은 L1 보정 루프를 한 번 더 도는 것이라, 재입력 중에
        미끄러진 누름도 보정된다. L2 검증기가 없으면 상한은 종전대로
        ``max_attempts``다.
        """
        errors: list[str] = []
        last_verification = None
        presses = 0
        reinputs = 0
        corrections: list = []
        while True:
            pressed = False
            for attempt in range(1, self._retry_policy.max_attempts + 1):
                if presses > 0:
                    self._check_stop()  # 재시도·재입력 경계에서도 정지 요청 반영
                    self._retry_waiter.wait(button, presses)
                correction = (
                    None
                    if attempt == 1
                    else self._retry_policy.correction_for(attempt - 1)
                )
                presses += 1
                if correction is not None:
                    corrections.append(correction)
                    self._observe("retry", button, completed_steps, presses,
                                  correction=_correction_fields(correction))
                command = self._press_command(button, correction)
                self._observe("move", button, completed_steps, presses,
                              target=_target_fields(command),
                              correction=_correction_fields(correction))
                def before_press() -> None:
                    nonlocal presses
                    self._check_stop()
                    if self._operation is not None:
                        # 모션 어댑터에서는 자동 원점·XY 뒤, Z 직전의 기준선·시각이다.
                        try:
                            if not self._operation_observing:
                                self._operation.begin_observation()
                                self._operation_observing = True
                            self._operation.note_press(button, presses)
                        except Exception as exc:  # noqa: BLE001 - 센서 고장은 fail closed
                            raise _OperationObservationFailed(str(exc)) from exc
                    # L1도 이동이 끝난 뒤 연다. verify가 누름 뒤 창을 닫는다.
                    begin = getattr(self._verifier, "begin_press", None)
                    if callable(begin):
                        try:
                            begin(button)
                        except SensorUnavailable as exc:
                            presses -= 1  # 아직 Z를 누르지 않았다.
                            raise self._press_sensor_failure(
                                button, presses, errors, last_verification, reinputs,
                                corrections, f"press sensor unavailable before pressing: {exc}",
                            ) from exc
                    self._check_stop()

                try:
                    observed_press = getattr(self._grbl, "press_with_observation", None)
                    if callable(observed_press):
                        observed_press(command, before_press)
                    else:
                        # 이동 경계를 제공하지 않는 기존 어댑터는 누름 호출 직전에 연다.
                        before_press()
                        self._grbl.press(command)
                except (_OperationObservationFailed, _PressObservationFailed, _EmergencyStopRequested):
                    self._cancel_press_observation()
                    raise
                except Exception as exc:  # adapter errors are recoverable within the hard limit
                    self._cancel_press_observation()
                    errors.append(str(exc))
                    self._observe("press", button, completed_steps, presses, ok=False,
                                  error=str(exc)[:200], position=self._adapter_position())
                    self._report_progress(button, presses, completed_steps, None)
                    continue
                self._observe("press", button, completed_steps, presses, ok=True,
                              position=self._adapter_position())

                try:
                    last_verification = self._verifier.verify(button)
                except SensorUnavailable as exc:
                    raise self._press_sensor_failure(
                        button, presses, errors, last_verification, reinputs,
                        corrections, f"press sensor unavailable: {exc}",
                    ) from exc
                self._observe("verify", button, completed_steps, presses,
                              pressed=bool(last_verification.pressed))
                self._report_progress(button, presses, completed_steps, last_verification)
                if last_verification.pressed:
                    pressed = True
                    break

            if not pressed:
                return ButtonResult(
                    button,
                    ButtonStatus.FAILED,
                    presses,
                    last_verification,
                    tuple(errors),
                    failed_layer=VerificationLayer.PRESS,
                    reinputs=reinputs,
                    corrections=tuple(corrections),
                )

            if self._acceptance is None:
                self._pace(button, completed_steps)
                return ButtonResult(
                    button,
                    ButtonStatus.SUCCEEDED,
                    presses,
                    last_verification,
                    tuple(errors),
                    reinputs=reinputs,
                    corrections=tuple(corrections),
                )

            accepted = self._acceptance.verify_acceptance(button)
            self._observe("accept", button, completed_steps, presses, passed=bool(accepted.passed))
            if accepted.passed:
                self._pace(button, completed_steps)
                return ButtonResult(
                    button,
                    ButtonStatus.SUCCEEDED,
                    presses,
                    last_verification,
                    tuple(errors),
                    reinputs=reinputs,
                    corrections=tuple(corrections),
                )
            errors.append(f"L2: {accepted.detail}" if accepted.detail else "L2: not accepted")
            if reinputs >= self._acceptance_reinputs:
                return ButtonResult(
                    button,
                    ButtonStatus.FAILED,
                    presses,
                    last_verification,
                    tuple(errors),
                    failed_layer=VerificationLayer.ACCEPTANCE,
                    reinputs=reinputs,
                    corrections=tuple(corrections),
                )
            reinputs += 1

    def _press_sensor_failure(
        self, button: str, presses: int, errors: list[str], last_verification,
        reinputs: int, corrections: list, message: str,
    ) -> _PressObservationFailed:
        self._cancel_press_observation()
        errors.append(message)
        return _PressObservationFailed(ButtonResult(
            button,
            ButtonStatus.FAILED,
            presses,
            last_verification,
            tuple(errors),
            failed_layer=VerificationLayer.PRESS,
            reinputs=reinputs,
            corrections=tuple(corrections),
        ))

    def _cancel_press_observation(self) -> None:
        cancel = getattr(self._verifier, "cancel_press", None)
        if not callable(cancel):
            return
        try:
            cancel()
        except Exception:  # noqa: BLE001 - 정리 실패가 정지 경로를 막지 않는다
            log.exception("press observation cancel failed")

    def _press_command(self, button: str, correction) -> PressCommand:
        target = self._targets.get(button)
        if target is None:
            return PressCommand(button, correction)
        return PressCommand(
            button,
            correction,
            x_mm=target.x_mm,
            y_mm=target.y_mm,
            press_ms=target.press_ms,
        )

    def _observe(self, phase: str, button: str, step_index: int, attempt: int, **fields: object) -> None:
        observer = self._press_observer
        if observer is None:
            return
        try:
            observer({"phase": phase, "button": button, "step_index": step_index,
                      "attempt": attempt, **fields})
        except Exception:  # noqa: BLE001 - 관찰 고장이 누름을 막지 않는다
            log.exception("press observer failed")

    def _adapter_position(self) -> dict | None:
        """모션 어댑터가 MCU 보고로 아는 위치(``last_position``). 없으면 None."""
        try:
            position = getattr(self._grbl, "last_position", None)
        except Exception:  # noqa: BLE001
            return None
        return dict(position) if isinstance(position, dict) else None

    def _check_stop(self) -> None:
        if self._stop_requested.is_set():
            raise _EmergencyStopRequested()

    def _report_progress(
        self,
        button: str,
        attempt: int,
        completed_steps: int,
        verification: VerificationResult | None,
    ) -> None:
        if self._on_progress is None:
            return
        self._on_progress(
            ExecutionProgress(button, attempt, completed_steps, verification)
        )

    def _pace(self, button: str, completed_steps: int) -> None:
        """데모 페이싱 훅 -- 기본 None이면 지연 0(실동작·테스트 불변).
        SIMPLELAY_DEMO_PACING이 켜지면 컨트롤러 팩토리가 sleep을 주입한다.
        진행 이벤트는 그대로 두고(on_progress 시퀀스 불변) 방금 보고한
        상태를 잠깐 유지시켜, 폐루프(누름->검증->다음)가 화면에 보이게 한다."""
        if self._step_pacer is not None:
            self._step_pacer(button, completed_steps)


def _correction_fields(correction) -> dict | None:
    if correction is None:
        return None
    return {
        "retry_number": correction.retry_number,
        "xy_adjustment_required": correction.xy_adjustment_required,
        "increase_press_depth": correction.increase_press_depth,
    }


def _target_fields(command: PressCommand) -> dict | None:
    if not command.has_coordinates:
        return None
    return {"x_mm": command.x_mm, "y_mm": command.y_mm}
