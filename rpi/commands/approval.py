"""승인 재검사 실패 — 실행하지 않고 카드를 되돌리거나 새 승인을 받는다.

셋 다 ``RuntimeError``라 HTTP에서는 409다('지금 이 승인으로는 실행할 수 없음').
``reason``은 제안 피드백 기록(``approval_failed``·``withdrawn``)의 사유 코드다.
"""

from __future__ import annotations


class ApprovalError(RuntimeError):
    reason = "approval_invalid"


class ApprovalMismatchError(ApprovalError):
    """승인한 대상·경로·동작·인자와 지금 실행하려는 명령이 다르다 → 재승인."""

    reason = "approval_mismatch"

    def __init__(self, detail: str = "") -> None:
        super().__init__(
            "승인한 내용과 지금 실행할 내용이 달라졌어요 — 다시 확인하고 승인해 주세요"
            + (f" ({detail})" if detail else "")
        )


class ApprovalExpiredError(ApprovalError):
    reason = "validity_ended"

    def __init__(self) -> None:
        super().__init__("승인 유효 시간이 지났어요 — 새 제안을 확인해 주세요")


class ApprovalInvalidError(ApprovalError):
    """승인은 그대로인데 실행 직전 재검사(동작 지원·인자 범위)를 통과하지 못했다."""

    reason = "approval_invalid"
