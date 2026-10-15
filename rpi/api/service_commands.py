"""명령 계약 실행 — ThinQ 경로·승인 고정 명령·다가전 시나리오 (U1-a·U1-b·U1-c 모의).

``SimpleLayService``가 이 믹스인을 상속한다. 물리 경로의 기존 흐름(목적 해석 →
``_submit`` → ``_run_buttons``)은 바꾸지 않고, 그 옆에 **명령 단위** 흐름을 둔다:

    Command / ApprovedCommand
      → 실행 직전 재검사(대상 존재 · 경로 일치 · 동작 지원·인자 범위 · 경로별 준비 상태)
      → 같은 실행 게이트(_begin_run: 한 번에 1건 · 제어권 중재 · 정지 토큰)
      → 단계별 실행(thinq: ThinqController.execute_command / physical: 기존 _run_buttons)
      → CommandResult(상태 · 수신 · 확인 근거) · 이력 · 보호자 알림 · 완료 이벤트

결정(§5, devlog 2026-09-29 표):

- #1 승인 고정: ``ApprovedCommand``의 명령을 그대로 실행한다. 목적 문자열을 다시
  해석하지 않는다. 재검사에서 대상·경로가 바뀌었으면 ``ApprovalMismatchError``.
- #6 실행 락: ThinQ 단계는 전송 + 확인 대기 상한까지만 게이트를 잡는다. 상한 안에
  못 보면 ``unconfirmed``로 끝내고 게이트를 놓는다(늦은 상태 변경은 job을 되살리지 않음).
- #5 정지: ThinQ 명령은 보내기 전이면 취소, 보냈으면 ``sent_uncancellable``. 남은
  시나리오 단계는 보내지 않는다. 가전 운전 정지 명령은 자동으로 보내지 않는다.
- 한 단계라도 성공(확인)으로 끝나지 않으면 **나머지 단계를 보내지 않는다** --
  미확인 위에 다음 가전을 얹지 않는다. 자동 재전송도 없다.
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass, replace
from datetime import datetime

from rpi.commands import (
    ApprovalExpiredError,
    ApprovalInvalidError,
    ApprovalMismatchError,
    ApprovedCommand,
    Command,
    CommandResult,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)
from rpi.commands.physical import confirmation_of, receipt_of
from rpi.controller import ExecutionResult, ExecutionStatus
from rpi.intent import UsageOutcome, UsageRecord
from rpi.intent.models import UsageSource
from rpi.intent.rules import UnknownIntentError
from rpi.services.history import ExecutionMode, JobHistoryEntry, Termination

log = logging.getLogger(__name__)


class WrongRouteError(UnknownIntentError, RuntimeError):
    """제어 경로가 맞지 않는 요청(예: ThinQ 가전에 버튼 시퀀스).

    해석 오류(422)이면서 실행 거절(409)이기도 하다 -- 어느 진입점의 예외 매핑을
    타도 **500이 되거나 로컬 갠트리로 흘러가지 않게** 두 부모를 모두 둔다.
    """


@dataclass(frozen=True)
class JobFinishedEvent:
    """실행 단계 하나가 끝났다 — 시나리오 트리거가 듣는다."""

    job_id: str
    appliance_id: str | None
    route: ControlRoute
    status: str
    receipt: Receipt
    confirmation: Confirmation
    execution_mode: ExecutionMode
    usage_source: UsageSource
    purpose: str | None = None
    #: 시나리오의 한 단계면 그 ID. 트리거는 이런 이벤트로 다시 시나리오를 만들지 않는다.
    scenario_id: str | None = None


@dataclass(frozen=True)
class RunRecord:
    """명령 실행 1건(단일 명령 또는 시나리오)의 단계별 결과."""

    job_id: str
    scenario_id: str | None
    purpose: str | None
    results: tuple[CommandResult, ...]
    summaries: tuple[str, ...] = ()
    finished_at: datetime | None = None

    @property
    def status(self) -> CommandStatus:
        """전체 상태 -- 끝까지 가지 못한 첫 단계의 상태, 다 성공이면 succeeded."""
        for result in self.results:
            if result.status is not CommandStatus.SUCCEEDED:
                return result.status
        return CommandStatus.SUCCEEDED

    def as_dict(self) -> dict:
        return {
            "job_id": self.job_id,
            "scenario_id": self.scenario_id,
            "purpose": self.purpose,
            "status": self.status.value,
            "finished_at": self.finished_at.isoformat() if self.finished_at else None,
            "steps": [
                {
                    "target_id": r.command.target_id,
                    "route": r.route.value,
                    "action": r.command.action,
                    "args": r.command.args_dict(),
                    "buttons": list(r.command.buttons),
                    "summary": self.summaries[i] if i < len(self.summaries) else "",
                    "status": r.status.value,
                    "receipt": r.receipt.value,
                    "confirmation": r.confirmation.value,
                    "execution_mode": r.execution_mode.value,
                    "detail": r.detail,
                }
                for i, r in enumerate(self.results)
            ],
        }


@dataclass
class _Step:
    command: Command
    summary: str
    controller: object
    calibration: str | None = None
    targets: dict | None = None


#: 비상정지가 걸려 있을 때 ThinQ 명령을 받지·보내지 않는 사유(2026-10-15 검토 H1).
THINQ_ESTOP_REASON = "비상 버튼이 눌려 있어 보내지 않았어요 — 빨간 비상 버튼을 풀고 해제한 뒤 다시 해 주세요"

_LEGACY_STATUS = {
    CommandStatus.SUCCEEDED: ExecutionStatus.SUCCEEDED,
    CommandStatus.STOPPED: ExecutionStatus.SAFETY_STOPPED,
    CommandStatus.FAILED: ExecutionStatus.FAILED,
    CommandStatus.UNCONFIRMED: ExecutionStatus.FAILED,
}

_OUTCOME = {
    CommandStatus.SUCCEEDED: "success",
    CommandStatus.STOPPED: "stopped",
    CommandStatus.FAILED: "failed",
    # 실패가 아니다(계약 §3). 옛 클라이언트가 모르는 값이면 기록만 보인다.
    CommandStatus.UNCONFIRMED: "unconfirmed",
}


class CommandExecutionMixin:
    """``SimpleLayService``의 명령 단위 실행. 속성은 서비스 ``__init__``이 채운다."""

    #: 제안 서비스가 물리 제안의 승인 시퀀스를 넘겨도 되는지(결정 #1).
    binds_approved_buttons = True

    def _init_commands(self, thinq_controller=None, system_controllers=None) -> None:
        self._thinq = thinq_controller
        self._system_controllers = dict(system_controllers or {})
        self._job_listeners: list = []
        self._last_run: RunRecord | None = None
        self._last_command_result: CommandResult | None = None
        self._current_route: ControlRoute | None = None
        self._last_route: ControlRoute | None = None
        self._last_receipt: Receipt | None = None
        self._last_confirmation: Confirmation | None = None
        self._last_detail: str | None = None
        self._last_command_status: CommandStatus | None = None
        #: 이번 실행 중 정지 요청이 있었나 -- 단계 사이에서도 남는다(시나리오용).
        self._stop_sticky = False
        self._step_suffix: str | None = None

    # ── 조회 ──────────────────────────────────────────────────────────────
    @property
    def thinq_controller(self):
        return self._thinq

    def add_job_listener(self, listener) -> None:
        self._job_listeners.append(listener)

    def last_run(self) -> RunRecord | None:
        return self._last_run

    def route_of(self, appliance_id: str | None) -> ControlRoute:
        if appliance_id is None or self._appliance_registry is None:
            return ControlRoute.PHYSICAL
        appliance = self._appliance_registry.get(appliance_id)
        if appliance is None:
            return ControlRoute.PHYSICAL
        return appliance.control_path

    def thinq_readiness(self, appliance_id: str):
        from rpi.services.thinq import ThinqReadiness  # noqa: PLC0415

        if self._thinq is None:
            return ThinqReadiness(appliance_id, "off", False, False, False,
                                  ("ThinQ 연동이 꺼져 있어요 (SIMPLELAY_THINQ_MODE)",))
        return self._thinq.readiness(appliance_id)

    def _binding(self, appliance_id: str):
        appliance = self._appliance_registry.get(appliance_id) if self._appliance_registry else None
        return appliance.thinq if appliance is not None else None

    def _appliance_name(self, appliance_id: str) -> str:
        appliance = self._appliance_registry.get(appliance_id) if self._appliance_registry else None
        return appliance.name if appliance is not None else appliance_id

    # ── ThinQ 목적 → 명령 ─────────────────────────────────────────────────
    def resolve_thinq_purpose(self, purpose: str, appliance_id: str) -> Command:
        from rpi.services.thinq import CapabilityError  # noqa: PLC0415

        binding = self._binding(appliance_id)
        if binding is None:
            raise UnknownIntentError(f"'{appliance_id}'는 ThinQ 등록 정보가 없어요")
        try:
            command = binding.command_for_purpose(appliance_id, purpose)
        except CapabilityError as exc:
            raise UnknownIntentError(str(exc)) from exc
        if command is None:
            raise UnknownIntentError(
                f"'{purpose.strip()}'은(는) 이 가전에 등록된 동작이 아니에요"
            )
        return command

    def summary_of(self, command: Command) -> str:
        name = self._appliance_name(command.target_id)
        if command.route is ControlRoute.THINQ:
            binding = self._binding(command.target_id)
            if binding is not None:
                try:
                    return binding.summary(name, command)
                except Exception:  # noqa: BLE001 -- 요약 실패가 실행을 막지 않는다
                    pass
            return f"{name} {command.action}"
        return f"{name} {' → '.join(command.buttons)}"

    # ── 실행 직전 재검사 ───────────────────────────────────────────────────
    def _prepare(self, command: Command, approved: ApprovedCommand | None) -> _Step:
        from rpi.services.thinq import CapabilityError  # noqa: PLC0415

        if approved is not None:
            if approved.is_expired(self._clock.now()):
                raise ApprovalExpiredError()
            if not approved.matches(command):
                raise ApprovalMismatchError("승인한 명령과 실행할 명령의 지문이 달라요")
        target = command.target_id
        self._require_known_appliance(target)
        current_route = self.route_of(target)
        if current_route is not command.route:
            error = (ApprovalMismatchError if approved is not None else UnknownIntentError)
            raise error(f"'{target}'의 제어 경로가 {current_route.value}로 바뀌었어요")
        summary = approved.shown_summary if approved is not None else self.summary_of(command)
        if command.route is ControlRoute.THINQ:
            binding = self._binding(target)
            try:
                if binding is None:
                    raise CapabilityError("ThinQ 등록 정보가 없어요")
                binding.validate_command(command)
            except CapabilityError as exc:
                if approved is not None:
                    raise ApprovalInvalidError(f"승인한 동작을 지금은 실행할 수 없어요: {exc}") from exc
                raise UnknownIntentError(str(exc)) from exc
            readiness = self.thinq_readiness(target)
            if not readiness.can_execute:
                from .service import ApplianceNotReadyError  # noqa: PLC0415

                raise ApplianceNotReadyError(target, readiness.reasons or ("ThinQ 가전이 준비되지 않았어요",))
            # 비상정지 걸림(2026-10-15 검토 H1): 자동 실행만이 아니라 직접·승인 ThinQ 명령도 새로 받지 않는다.
            # 전원 끄기도 예외로 두지 않는다 — 풀고 정지 해제를 확인한 뒤 보낸다. 보내기 직전에도 다시 본다.
            if self._thinq_estop_latched():
                from .service import ApplianceNotReadyError  # noqa: PLC0415

                raise ApplianceNotReadyError(target, (THINQ_ESTOP_REASON,))
            return _Step(command, summary, self._thinq)
        # physical -- 버튼이 지금 이 가전의 조작부에 있어야 한다.
        appliance = self._appliance_registry.get(target) if self._appliance_registry else None
        if appliance is not None:
            labels = {b.label for b in appliance.buttons}
            missing = [b for b in command.buttons if b not in labels]
            if missing:
                error = ApprovalMismatchError if approved is not None else UnknownIntentError
                raise error(f"조작부에 없는 버튼: {', '.join(missing)}")
        buttons = self._validate_resolved_sequence(tuple(command.buttons))
        controller = self._controller_for(target)
        return _Step(
            command, summary, controller,
            calibration=self._calibration_snapshot(target),
            targets=self._targets_snapshot(target, buttons, controller),
        )

    # ── 진입점 ────────────────────────────────────────────────────────────
    def submit_command(self, command: Command, *, purpose: str | None = None,
                       usage_source: UsageSource = UsageSource.DIRECT,
                       approval_guard=None) -> str:
        """직접 명령(사용자 발화·버튼 자체가 승인) 1건을 job으로 제출한다."""
        steps = [self._prepare(command, None)]
        return self._start_plan(steps, purpose, usage_source, approval_guard, None, background=True)

    def execute_command(self, command: Command, *, purpose: str | None = None,
                        usage_source: UsageSource = UsageSource.DIRECT,
                        approval_guard=None) -> RunRecord:
        steps = [self._prepare(command, None)]
        return self._start_plan(steps, purpose, usage_source, approval_guard, None, background=False)

    def submit_approved(self, approved: tuple[ApprovedCommand, ...], *, purpose: str | None = None,
                        usage_source: UsageSource = UsageSource.SUGGESTION,
                        approval_guard=None, scenario_id: str | None = None,
                        dispatch_guard=None) -> str:
        """승인한 명령(들)을 **그대로** 제출한다. 모든 단계를 먼저 재검사한다.

        ``dispatch_guard``(선택, 2026-10-14): ThinQ 단계를 실행기에 넘기기 전에 한 번, 그리고 실행기가 프로필·상태
        조회를 마친 뒤 클라우드로 **보내기 직전**에 대상 바인딩과 함께 다시 부른다(3차 평가 H1). 예외를 올리면 그 단계는
        보내지 않고(``not_dispatched``) 예외 문장을 결과에 남긴다 — 시작 게이트와 실제 전송 사이에 자동 실행 규칙이
        꺼지거나 바뀌거나 지워진 경우(자동 실행 허용 규칙). 인자 없이 부를 수도, 바인딩 하나로 부를 수도 있어야 한다."""
        steps = [self._prepare(a.command, a) for a in approved]
        return self._start_plan(steps, purpose, usage_source, approval_guard, scenario_id, background=True,
                                dispatch_guard=dispatch_guard)

    def execute_approved(self, approved: tuple[ApprovedCommand, ...], *, purpose: str | None = None,
                         usage_source: UsageSource = UsageSource.SUGGESTION,
                         approval_guard=None, scenario_id: str | None = None) -> RunRecord:
        steps = [self._prepare(a.command, a) for a in approved]
        return self._start_plan(steps, purpose, usage_source, approval_guard, scenario_id, background=False)

    def _submit_thinq_purpose(self, purpose, appliance_id, usage_source, approval_guard, background,
                              *, expected_buttons=None, approved_buttons=None,
                              approved_command: ApprovedCommand | None = None):
        """목적 → ThinQ 명령. 승인 결속(결정 #1)은 이 경로에도 그대로 적용한다.

        승인 인자를 말없이 버리면 ThinQ 경로만 '승인 뒤 재해석'이 되살아난다 --
        묶인 것이 있으면 여기서 대조하고, 다르면 실행하지 않고 재승인이다.
        """
        command = self.resolve_thinq_purpose(purpose, appliance_id)
        bound = approved_buttons if approved_buttons is not None else expected_buttons
        if bound is not None:
            # ThinQ 명령은 버튼을 들지 않는다(Command 불변 조건). 버튼 시퀀스로
            # 승인한 카드가 이 경로로 들어왔다는 것은 승인 당시와 대상·경로가
            # 달라졌다는 뜻이므로 실행하지 않는다.
            raise ApprovalMismatchError(
                f"승인 {' → '.join(bound)} / 지금 ThinQ {self.summary_of(command)}"
            )
        steps = [self._prepare(command, approved_command)]
        return self._start_plan(steps, purpose.strip(), usage_source, approval_guard, None,
                                background=background)

    # ── 실행 ──────────────────────────────────────────────────────────────
    def _start_plan(self, steps, purpose, usage_source, approval_guard, scenario_id, *, background,
                    dispatch_guard=None):
        if not steps:
            raise UnknownIntentError("실행할 명령이 없어요")
        first = steps[0]
        job_id = self._begin_run(len(steps), first.controller, first.command.target_id, approval_guard)
        with self._lock:
            self._current_route = first.command.route
        # 정지 토큰은 게이트가 모든 대상에 대해 리셋하지 않는다(로컬만) -- ThinQ도 리셋.
        for step in steps:
            reset = getattr(step.controller, "reset_stop", None)
            if reset is not None and step.controller is not first.controller:
                reset()
        args = (job_id, steps, purpose, usage_source, scenario_id, dispatch_guard)
        if not background:
            try:
                return self._run_plan(*args)
            finally:
                self._end_run()
        thread = threading.Thread(target=self._run_plan_job, args=args, daemon=True,
                                  name=f"simplelay-cmd-{job_id}")
        thread.start()
        return job_id

    def _run_plan_job(self, *args) -> None:
        try:
            self._run_plan(*args)
        except Exception:
            log.exception("command job failed")
        finally:
            self._end_run()

    def _run_plan(self, job_id, steps, purpose, usage_source, scenario_id, dispatch_guard=None) -> RunRecord:
        results: list[CommandResult] = []
        multi = len(steps) > 1
        for index, step in enumerate(steps):
            command = step.command
            with self._lock:
                stop = self._stop_sticky
                self._current_appliance_id = command.target_id
                self._current_route = command.route
                self._execution_mode = _mode(step.controller)
                self._step_suffix = f"{index + 1}" if multi else None
            halted = results and results[-1].status is not CommandStatus.SUCCEEDED
            if stop or halted:
                results.append(CommandResult(
                    command=command, status=CommandStatus.STOPPED if stop else CommandStatus.FAILED,
                    receipt=Receipt.NOT_DISPATCHED, confirmation=Confirmation.NONE,
                    execution_mode=_mode(step.controller),
                    detail=("정지 요청으로 보내지 않았어요" if stop
                            else "앞 단계가 확인되지 않아 보내지 않았어요"),
                    observed_at=self._clock.now(), stop_requested=stop,
                ))
                continue
            if command.route is ControlRoute.THINQ:
                result = self._run_thinq_step(job_id, step, purpose, usage_source, scenario_id,
                                              dispatch_guard)
            else:
                result = self._run_physical_step(step, usage_source, scenario_id)
            results.append(result)
        record = RunRecord(job_id, scenario_id, purpose, tuple(results),
                           tuple(s.summary for s in steps), self._clock.now())
        with self._lock:
            self._step_suffix = None
        self._last_run = record
        return record

    def _history_job_id(self) -> str:
        base = self._current_job_id or ""
        return f"{base}-{self._step_suffix}" if self._step_suffix else base

    def _thinq_estop_latched(self) -> bool:
        latched = getattr(self, "estop_latched", None)
        return bool(callable(latched) and latched())

    def _with_estop_guard(self, inner):
        """ThinQ 단계의 보내기 직전 확인에 비상정지 걸림을 더한다(2026-10-15 검토 H1).

        실행기에 넘기기 전과, 실행기가 프로필·상태 조회를 마친 뒤 **보내기 직전**에 불린다(``dispatch_guard``와 같은
        자리). 걸려 있으면 보내지 않고(``not_dispatched``) 사유를 남긴다. 인자 없이도, 바인딩 하나로도 불린다.
        안쪽 확인의 반환값(자동 실행 규칙의 전송권 등)은 그대로 돌려준다."""
        def guard(*args):
            if self._thinq_estop_latched():
                raise RuntimeError(THINQ_ESTOP_REASON)
            return inner(*args) if inner is not None else None
        return guard

    def _run_thinq_step(self, job_id, step: _Step, purpose, usage_source, scenario_id,
                        dispatch_guard=None) -> CommandResult:
        command = step.command
        blocked = None
        dispatch_guard = self._with_estop_guard(dispatch_guard)
        if dispatch_guard is not None:
            try:
                dispatch_guard()
            except Exception as exc:  # noqa: BLE001 -- 보내기 직전 재검사에 걸림: 보내지 않는다
                blocked = str(exc) or "보내기 직전 확인에 걸려 보내지 않았어요"
        try:
            if blocked is not None:
                result = CommandResult(
                    command=command, status=CommandStatus.FAILED, receipt=Receipt.NOT_DISPATCHED,
                    confirmation=Confirmation.NONE, execution_mode=_mode(self._thinq),
                    detail=blocked, observed_at=self._clock.now(),
                )
            elif dispatch_guard is not None and getattr(self._thinq, "supports_dispatch_guard", False):
                # 3차 평가 H1: 위 확인은 실행기의 프로필·상태 조회(네트워크)보다 앞이다 -- 같은 확인을 조회를 마친 뒤
                # 전송 직전에 실행기가 한 번 더 부른다(대상 바인딩과 함께).
                result = self._thinq.execute_command(command, dispatch_guard=dispatch_guard)
            else:
                result = self._thinq.execute_command(command)
        except Exception:  # noqa: BLE001 -- 실행기 예외는 '받았는지 모름'이다
            log.exception("thinq controller raised")
            result = CommandResult(
                command=command, status=CommandStatus.UNCONFIRMED, receipt=Receipt.UNKNOWN,
                confirmation=Confirmation.NONE, execution_mode=_mode(self._thinq),
                detail="실행기 오류로 보냈는지 알 수 없어요 — 자동으로 다시 보내지 않아요",
                observed_at=self._clock.now(),
            )
        with self._lock:
            stopped_by_user = self._stop_requested_this_run
            stop_requested_at = self._stop_requested_at
            self._stop_requested_this_run = False
            self._stop_requested_at = None
        if stopped_by_user and not result.stop_requested:
            result = replace(result, stop_requested=True)
        self._remember_command_result(result)
        self._last_result = ExecutionResult(_LEGACY_STATUS[result.status], ())
        self._record_command_history(result, purpose, step, stop_requested_at if stopped_by_user else None)
        self._record_command_care(result, step.summary, purpose)
        if purpose is not None and self._usage_log is not None and scenario_id is None:
            # 결정 #4: ThinQ 경로는 상태 확인(state_confirmed) 이상만 성공으로 센다. 보내기 전 조회에서 이미 목표값
            # (already_at_target, 2026-10-14)도 원하는 상태를 조회로 본 것이라 성공으로 센다(보내지는 않았다).
            ok = (result.status is CommandStatus.SUCCEEDED
                  and result.confirmation.reached_target and not stopped_by_user)
            try:
                self._usage_log.append(UsageRecord(
                    self._clock.now(), purpose, UsageOutcome.SUCCEEDED if ok else UsageOutcome.FAILED,
                    appliance_id=command.target_id, execution_mode=result.execution_mode,
                    source=usage_source,
                ))
            except Exception:
                log.exception("usage log append failed")
        self._emit_job_finished(JobFinishedEvent(
            job_id=self._history_job_id(), appliance_id=command.target_id, route=ControlRoute.THINQ,
            status=result.status.value, receipt=result.receipt, confirmation=result.confirmation,
            execution_mode=result.execution_mode, usage_source=usage_source, purpose=purpose,
            scenario_id=scenario_id,
        ))
        return result

    def _run_physical_step(self, step: _Step, usage_source, scenario_id) -> CommandResult:
        from rpi.commands import command_result_from_execution  # noqa: PLC0415

        command = step.command
        self._scenario_context = scenario_id
        try:
            execution = self._run_buttons(
                tuple(command.buttons), step.controller, None, command.target_id,
                step.calibration, usage_source, None, targets=step.targets,
            )
        except Exception:  # noqa: BLE001 -- 실행 대상 예외(링크 끊김 등)는 '눌렸는지 모름'이다(2026-10-15 G1)
            # 예전에는 여기서 예외가 올라가 _run_plan_job이 로그만 남겼다 — 결과·이력·보호자 알림·완료 이벤트가 없고
            # /status에는 이 job 번호에 직전 실행의 결과가 붙었다. 이제 이 job의 '확인 못 함'으로 남기고 다시 누르지 않는다.
            log.exception("physical step raised — recording it as unconfirmed")
            return self._unconfirmed_physical_step(step, usage_source, scenario_id)
        finally:
            self._scenario_context = None
        try:
            return command_result_from_execution(
                command, execution, execution_mode=_mode(step.controller, execution),
                observed_at=self._clock.now(), stopped_by_user=self._stop_sticky,
            )
        except Exception:  # noqa: BLE001
            log.exception("physical result mapping failed")
            return CommandResult(
                command=command, status=CommandStatus.UNCONFIRMED, receipt=Receipt.UNKNOWN,
                confirmation=Confirmation.NONE, execution_mode=_mode(step.controller),
                detail="결과를 해석하지 못했어요", observed_at=self._clock.now(),
            )

    def _unconfirmed_physical_step(self, step: _Step, usage_source, scenario_id) -> CommandResult:
        """물리 단계가 실행 대상 예외로 끝났다 — 수신 unknown·확인 없음·``unconfirmed``(2026-10-15 G1).

        이력·보호자 알림·/status는 서비스의 직접 경로와 같은 함수(`_record_unconfirmed_physical`)로 남기고, 시나리오
        트리거가 듣는 완료 이벤트도 보낸다. 남은 단계는 ``_run_plan``이 보내지 않는다(앞 단계 미확인)."""
        from .service import LINK_UNCONFIRMED_DETAIL  # noqa: PLC0415

        command = step.command
        stopped = self._record_unconfirmed_physical(
            tuple(command.buttons), step.controller, None, command.target_id, step.calibration)
        mode = _mode(step.controller)
        result = CommandResult(
            command=command, status=CommandStatus.UNCONFIRMED, receipt=Receipt.UNKNOWN,
            confirmation=Confirmation.NONE, execution_mode=mode, detail=LINK_UNCONFIRMED_DETAIL,
            observed_at=self._clock.now(), stop_requested=stopped or self._stop_sticky,
        )
        with self._lock:
            self._last_command_result = result
        self._emit_job_finished(JobFinishedEvent(
            job_id=self._history_job_id(), appliance_id=command.target_id, route=ControlRoute.PHYSICAL,
            status=result.status.value, receipt=result.receipt, confirmation=result.confirmation,
            execution_mode=mode, usage_source=usage_source, purpose=None, scenario_id=scenario_id,
        ))
        return result

    # ── 물리 결과의 계약 필드(기존 경로에서 부른다) ────────────────────────
    def _physical_contract_fields(self, result: ExecutionResult, expected: int | None) -> dict:
        try:
            return {
                "route": ControlRoute.PHYSICAL.value,
                "receipt": receipt_of(result).value,
                "confirmation": confirmation_of(result, expected).value,
            }
        except Exception:  # noqa: BLE001 -- 계측 실패가 이력을 막지 않는다
            return {"route": ControlRoute.PHYSICAL.value}

    def _after_physical_run(self, result: ExecutionResult, buttons, controller, appliance_id,
                            purpose, usage_source) -> None:
        """물리 실행이 끝난 뒤: 상태 표시용 계약 필드 기억 + 완료 이벤트."""
        try:
            receipt = receipt_of(result)
            confirmation = confirmation_of(result, len(buttons))
        except Exception:  # noqa: BLE001
            receipt, confirmation = Receipt.UNKNOWN, Confirmation.NONE
        with self._lock:
            self._last_receipt = receipt
            self._last_confirmation = confirmation
            self._last_detail = None
            self._last_command_status = None
            self._last_command_result = None
        self._emit_job_finished(JobFinishedEvent(
            job_id=self._history_job_id(), appliance_id=appliance_id, route=ControlRoute.PHYSICAL,
            status=result.status.value, receipt=receipt, confirmation=confirmation,
            execution_mode=_mode(controller, result), usage_source=usage_source, purpose=purpose,
            scenario_id=getattr(self, "_scenario_context", None),
        ))

    def _remember_command_result(self, result: CommandResult) -> None:
        with self._lock:
            self._last_command_result = result
            self._last_receipt = result.receipt
            self._last_confirmation = result.confirmation
            self._last_detail = result.detail
            self._last_command_status = result.status

    def _record_command_history(self, result: CommandResult, purpose, step: _Step,
                                stop_requested_at) -> None:
        if self._history_store is None:
            return
        if result.status is CommandStatus.SUCCEEDED:
            termination = Termination.COMPLETED
        elif result.stop_requested:
            termination = Termination.STOPPED_BY_USER
        else:
            termination = Termination.UNKNOWN
        try:
            entry = JobHistoryEntry(
                job_id=self._history_job_id(),
                finished_at=self._clock.now(),
                purpose=purpose,
                status=result.status.value,
                buttons=(),
                appliance_id=result.command.target_id,
                execution_mode=result.execution_mode,
                started_at=self._current_started_at,
                termination=termination,
                stop_requested_at=stop_requested_at,
            )
            extra = {"route": result.route.value, "receipt": result.receipt.value,
                     "confirmation": result.confirmation.value, "detail": result.detail}
            if "outcome" in JobHistoryEntry.__dataclass_fields__:
                extra["outcome"] = _OUTCOME[result.status]
            self._history_store.append(replace(entry, **extra))
        except Exception:
            log.exception("job history record failed")

    def _record_command_care(self, result: CommandResult, summary: str, purpose) -> None:
        """보호자 알림(§5 #8): 미확인은 실패와 다른 문장이다. 성공·정지는 알리지 않음."""
        if self._care_events is None:
            return
        try:
            if result.status is CommandStatus.UNCONFIRMED:
                self._care_events.append(
                    "execution_failed",
                    f"'{summary}' 명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요.",
                    purpose=purpose,
                )
            elif result.status is CommandStatus.FAILED:
                self._care_events.append(
                    "execution_failed",
                    f"'{summary}' 명령이 실행되지 않았어요. 가전을 확인해 주세요.",
                    purpose=purpose,
                )
        except Exception:
            log.exception("care event record failed")

    def _emit_job_finished(self, event: JobFinishedEvent) -> None:
        for listener in list(self._job_listeners):
            try:
                listener(event)
            except Exception:
                log.exception("job listener failed")

    # ── 정지 ──────────────────────────────────────────────────────────────
    def _stop_command_paths(self) -> tuple[tuple[str, ...], tuple[str, ...]]:
        """ThinQ 경로 정지(결정 #5). (보내기 전 취소한 가전, 이미 보내 취소 못 한 가전)."""
        if self._thinq is None:
            return (), ()
        from rpi.services.thinq import StopOutcome  # noqa: PLC0415

        try:
            outcome = self._thinq.request_stop()
        except Exception:  # noqa: BLE001
            log.exception("thinq stop failed")
            return (), ()
        target = self._current_appliance_id if self._current_route is ControlRoute.THINQ else None
        label = (target or "thinq",)
        if outcome is StopOutcome.CANCELLED_BEFORE_DISPATCH:
            return label, ()
        if outcome is StopOutcome.SENT_UNCANCELLABLE:
            return (), label
        return (), ()


def _mode(controller, result=None) -> ExecutionMode:
    """컨트롤러가 밝힌 모드. UNKNOWN이면 결과에 실린 원격 보고(있을 때만)를 쓴다."""
    declared = getattr(controller, "execution_mode", ExecutionMode.UNKNOWN)
    reported = getattr(result, "execution_mode", None)
    if declared is ExecutionMode.UNKNOWN and isinstance(reported, ExecutionMode):
        return reported
    return declared


__all__ = ["CommandExecutionMixin", "JobFinishedEvent", "RunRecord"]
