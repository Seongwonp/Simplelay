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
"""

from __future__ import annotations

from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ExecutionOutcome,
    ExecutionResult,
    ExecutionStatus,
)


def synthesize_execution_result(
    buttons: list[str],
    success: bool,
    retry: int,
    outcome: ExecutionOutcome | None = None,
) -> ExecutionResult:
    if success:
        button_results = tuple(
            ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons
        )
        # 성공은 status만으로 분명하다 -- outcome_of가 success로 유도한다.
        return ExecutionResult(ExecutionStatus.SUCCEEDED, button_results)

    if outcome is None or outcome is ExecutionOutcome.SUCCESS:
        # 보고 없음(옛 펌웨어) 또는 success=false와 모순된 보고 -- 이유를 모른다.
        outcome = ExecutionOutcome.FAILED
    *done, failed = buttons
    button_results = tuple(
        ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in done
    ) + (ButtonResult(failed, ButtonStatus.FAILED, retry + 1, None),)
    return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, button_results, outcome=outcome)
