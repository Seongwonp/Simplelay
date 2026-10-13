"""Shared synthesis logic for controllers that only get an aggregate
{success, retry} back from a remote Act node (UART ActClient today, HTTP/
ESP-NOW EspNodeController tomorrow) instead of a real per-button breakdown.

See docs/roadmap.md's precision note: on success every requested button is
marked SUCCEEDED (accurate -- the remote side only reports success when
every button in the sequence actually succeeded). On failure, every button
before the last is marked SUCCEEDED and the last is marked FAILED with
attempts = retry + 1 -- a best-effort guess, since the remote's own closed
loop stops at the true failing button but that button's identity doesn't
cross the wire today.

``outcome`` (2026-09-29): the remote may also report *how* it ended
(``stopped`` = honoured a stop request, ``safety_stop`` = stopped itself after a
verification failure, ``failed``). It is carried verbatim on the result so the
status/history/SSE can tell a stop from a failure. When the remote doesn't
send it (older RPi4 firmware, ESP nodes) a failure is recorded as ``failed`` --
"실패했다는 것만 안다" -- never guessed as a stop.

``button_results`` (2026-09-29, G1): the RPi4 now also sends what its closed loop
actually counted per button (attempts, failed layer, corrections). When present
and well-formed it replaces the guesses above -- retries survive on success too.
Without it (older RPi4, ESP nodes) a success still keeps the aggregate ``retry``,
attributed to the last button (the same convention as the failure branch -- which
button needed it is unknown; ``retry_count`` is then a lower bound, since ``retry``
is the per-button maximum).

``operation_confirmed`` (2026-09-29, G2): the RPi4's L3 verdict. ``None`` means no
L3 verifier / no verdict and leaves ``ExecutionResult.operation`` empty. A verdict
from synthetic input (``operation_source`` != ``real``) is marked ``mock`` so it never
counts as appliance-operation evidence.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import TYPE_CHECKING

from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ExecutionMode,
    ExecutionOutcome,
    ExecutionResult,
    ExecutionStatus,
    VerificationLayer,
)
from rpi.controller.models import Correction, LayerOutcome

if TYPE_CHECKING:
    from .act_client import ActResult, ButtonReport

_LAYER = {layer.value: layer for layer in VerificationLayer}


def _corrections(raw: Sequence[dict]) -> tuple[Correction, ...]:
    out = []
    for c in raw:
        try:
            out.append(Correction(
                int(c["retry_number"]),
                bool(c["xy_adjustment_required"]),
                bool(c["increase_press_depth"]),
            ))
        except (KeyError, TypeError, ValueError):
            continue  # 보정 표시는 부가 정보다 -- 잘못된 칸 하나로 결과를 버리지 않는다
    return tuple(out)


def _from_reports(reports: "Sequence[ButtonReport]") -> tuple[ButtonResult, ...]:
    return tuple(
        ButtonResult(
            r.button,
            ButtonStatus.SUCCEEDED if r.ok else ButtonStatus.FAILED,
            r.attempts,
            None,  # 이쪽 센서 판정이 아니다 -- 집계 보고와 같은 근거 수준
            failed_layer=None if r.ok else _LAYER.get(r.layer or "L1"),
            corrections=_corrections(r.corrections),
        )
        for r in reports
    )


def synthesize_execution_result(
    buttons: list[str],
    success: bool,
    retry: int,
    outcome: ExecutionOutcome | None = None,
    *,
    button_results: "Sequence[ButtonReport] | None" = None,
    operation_confirmed: bool | None = None,
    operation_detail: str | None = None,
    operation_source: str | None = None,
    execution_mode: str | None = None,
    abort_reason: str | None = None,
) -> ExecutionResult:
    operation = None
    if operation_confirmed is not None:
        operation = LayerOutcome(
            VerificationLayer.OPERATION,
            operation_confirmed,
            operation_detail or "",
            mock=operation_source != "real",
        )
    mode = None
    if execution_mode is not None:
        try:
            mode = ExecutionMode(execution_mode)
        except ValueError:
            mode = None

    if success:
        if button_results is not None:
            button_results_ = _from_reports(button_results)
        else:
            # 보고에 버튼별 값이 없다 -- 재시도 수만은 잃지 않게 마지막 버튼에 싣는다.
            *done, last = buttons
            button_results_ = tuple(
                ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in done
            ) + (ButtonResult(last, ButtonStatus.SUCCEEDED, max(0, retry) + 1, None),)
        # 성공은 status만으로 분명하다 -- outcome_of가 success로 유도한다.
        return ExecutionResult(
            ExecutionStatus.SUCCEEDED, button_results_, operation=operation, execution_mode=mode
        )

    if outcome is None or outcome is ExecutionOutcome.SUCCESS:
        # 보고 없음(옛 펌웨어) 또는 success=false와 모순된 보고 -- 이유를 모른다.
        outcome = ExecutionOutcome.FAILED
    failed_layer = None
    if button_results is not None:
        button_results_ = _from_reports(button_results)
        failed = next((b for b in button_results_ if b.status is ButtonStatus.FAILED), None)
        failed_layer = failed.failed_layer if failed is not None else None
    else:
        *done, failed_name = buttons
        button_results_ = tuple(
            ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in done
        ) + (ButtonResult(failed_name, ButtonStatus.FAILED, retry + 1, None),)
    if operation is not None and not operation.passed:
        failed_layer = VerificationLayer.OPERATION
    return ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED,
        button_results_,
        failed_layer=failed_layer,
        operation=operation,
        outcome=outcome,
        execution_mode=mode,
        abort_reason=abort_reason,
    )


def synthesize_from_act_result(buttons: list[str], result: "ActResult") -> ExecutionResult:
    """ActClient 결과 전체를 ExecutionResult로 -- UART 경로의 한 곳."""
    outcome = ExecutionOutcome(result.outcome) if result.outcome else None
    return synthesize_execution_result(
        buttons,
        result.success,
        result.retry,
        outcome=outcome,
        button_results=result.button_results,
        operation_confirmed=result.operation_confirmed,
        operation_detail=result.operation_detail,
        operation_source=result.operation_source,
        execution_mode=result.execution_mode,
        abort_reason=getattr(result, "abort_reason", None),
    )
