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
"""

from __future__ import annotations

from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus


def synthesize_execution_result(
    buttons: list[str], success: bool, retry: int
) -> ExecutionResult:
    if success:
        button_results = tuple(
            ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons
        )
        return ExecutionResult(ExecutionStatus.SUCCEEDED, button_results)

    *done, failed = buttons
    button_results = tuple(
        ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in done
    ) + (ButtonResult(failed, ButtonStatus.FAILED, retry + 1, None),)
    return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, button_results)
