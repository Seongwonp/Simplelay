"""승인·루틴 실행의 진행바 단계 수(2026-10-25 키오스크 점검).

예전에는 승인한 **명령** 수를 전체 단계로 보냈다 — 버튼 두 번(30초 → 시작)인 명령 하나가 '1단계'로 보여, 키오스크가
따로 버튼 수로 고쳐 그렸다. 이제 누름 명령은 실제 누름 수, ThinQ 명령은 1로 센다. 여러 명령이면 완료 단계 수도 앞
명령의 누름을 더해 이어 센다(진행바가 명령마다 0으로 돌아가지 않게). 필드는 그대로라 옛 화면도 그대로 읽는다.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from rpi.api import SimpleLayService
from rpi.commands import ApprovedCommand
from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ExecutionProgress,
    ExecutionProgressTracker,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.routines import RoutineStore, build_routine, compile_commands
from rpi.services.appliance_registry import ApplianceRegistry

NOW = datetime(2026, 10, 25, 19, tzinfo=timezone(timedelta(hours=9)))
HEAT = {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["BT-08", "시작"]}
INDUCTION = {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]}


class _Peek:
    """누르는 동안 서비스 상태를 들여다본다. 첫 버튼 누름을 마친 것처럼 진행을 적는다."""

    def __init__(self, tracker: ExecutionProgressTracker) -> None:
        self.tracker = tracker
        self.service: SimpleLayService | None = None
        self.seen: list[tuple[int | None, int | None]] = []

    def execute(self, buttons, targets=None):
        self.tracker.update(ExecutionProgress(buttons[0], 1, 1, None))
        status = self.service.status()
        self.seen.append((status.total_steps, status.progress.completed_steps if status.progress else None))
        return ExecutionResult(ExecutionStatus.SUCCEEDED,
                               tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons))


def _setup(*steps):
    tracker = ExecutionProgressTracker()
    controller = _Peek(tracker)
    service = SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW),
                               progress_tracker=tracker)
    controller.service = service
    store = RoutineStore()
    routine = store.save(build_routine({"name": "데우기", "steps": list(steps), "trigger": {"kind": "manual"}},
                                       routine_id="rt-steps", now=NOW))
    approved = tuple(ApprovedCommand(c, "card-steps", NOW, "요약", NOW + timedelta(minutes=15))
                     for c in compile_commands(routine, ApplianceRegistry()))
    return controller, service, approved


def test_single_press_command_counts_its_button_presses():
    controller, service, approved = _setup(HEAT)
    service.execute_approved(approved)
    assert controller.seen == [(2, 1)]


def test_multi_command_plan_counts_all_presses_and_continues_the_completed_count():
    controller, service, approved = _setup(HEAT, INDUCTION)
    service.execute_approved(approved)
    # 두 명령 = 누름 3번. 두 번째 명령 첫 누름 뒤에는 앞 명령의 2번을 더해 3.
    assert controller.seen == [(3, 1), (3, 3)]
    assert service.status().total_steps is None  # 끝나면 비운다(종전 그대로)
