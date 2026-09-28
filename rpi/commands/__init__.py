"""독립 명령·결과·승인 계약 (U1-a).

기존 실행 경로와 분리된 값 객체만 있다. 서비스·DB·화면 연결은 다음 단계.
"""

from .approval import (
    ApprovalError,
    ApprovalExpiredError,
    ApprovalInvalidError,
    ApprovalMismatchError,
)
from .args import (
    MAX_ARG_NAME_LEN,
    MAX_ARG_STRING_LEN,
    MAX_ARGS,
    MAX_ARGS_BYTES,
    ArgumentError,
    ArgValue,
    NormalizedArgs,
    canonical_json,
    fingerprint_of,
    normalize_args,
)
from .models import (
    PHYSICAL_PRESS_ACTION,
    ApprovedCommand,
    Command,
    CommandResult,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)
from .physical import (
    EvidenceMismatchError,
    command_result_from_execution,
    confirmation_of,
    is_aggregate_report,
    receipt_of,
    status_of,
)

__all__ = [
    "MAX_ARGS",
    "MAX_ARGS_BYTES",
    "MAX_ARG_NAME_LEN",
    "MAX_ARG_STRING_LEN",
    "PHYSICAL_PRESS_ACTION",
    "ApprovalError",
    "ApprovalExpiredError",
    "ApprovalInvalidError",
    "ApprovalMismatchError",
    "ApprovedCommand",
    "ArgValue",
    "ArgumentError",
    "Command",
    "CommandResult",
    "CommandStatus",
    "Confirmation",
    "ControlRoute",
    "EvidenceMismatchError",
    "NormalizedArgs",
    "Receipt",
    "canonical_json",
    "command_result_from_execution",
    "confirmation_of",
    "fingerprint_of",
    "is_aggregate_report",
    "normalize_args",
    "receipt_of",
    "status_of",
]
