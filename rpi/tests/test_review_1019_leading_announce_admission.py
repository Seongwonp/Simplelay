"""검토 2026-10-19 (C): 루틴 맨 앞 안내를 첫 구간 **접수 전**에 알림함에 남겼다 — 첫 구간이 거절되면(바쁨·준비 전·승인
바뀜) 안내만 남고, 다시 승인할 때마다 같은 안내가 또 쌓였다. 이제 실행 서비스의 시작 게이트를 통과한 뒤에만, 첫 장치
구간을 보내기 전에 남긴다.
"""

from __future__ import annotations

import pytest

from rpi.commands import ApprovalMismatchError
from rpi.routines.runner import KIND_ROUTINE_ANNOUNCE
from rpi.tests.test_safety_g3_routine_stop import ANNOUNCE, HEAT, _routine_setup


def _announcements(care) -> list[str]:
    return [message for kind, message in care.events if kind == KIND_ROUTINE_ANNOUNCE]


@pytest.mark.parametrize("path", ["execute", "submit"])
def test_rejected_admission_leaves_no_announcement_and_retries_do_not_duplicate(path):
    controller, service, runner, routine, approved, care = _routine_setup(ANNOUNCE, HEAT)
    run = runner.execute_approved if path == "execute" else runner.submit_approved
    with service._lock:
        service._running = True  # 다른 실행 중(바쁨)
    for _ in range(2):
        with pytest.raises(RuntimeError):
            run(approved, scenario_id=routine.scenario_key())
    assert _announcements(care) == []
    assert controller.calls == []
    assert runner.runs() == ()


def test_changed_approval_at_the_start_gate_leaves_no_announcement():
    controller, service, runner, routine, approved, care = _routine_setup(ANNOUNCE, HEAT)

    def changed():
        raise ApprovalMismatchError("가전 설정이 바뀌었어요")

    with pytest.raises(ApprovalMismatchError):
        runner.execute_approved(approved, scenario_id=routine.scenario_key(), approval_guard=changed)
    assert _announcements(care) == []


def test_admitted_run_announces_once_before_the_first_segment_is_pressed():
    controller, service, runner, routine, approved, care = _routine_setup(ANNOUNCE, HEAT)
    order: list[str] = []
    care.on_append = lambda: order.append("announce:" + str(len(controller.calls)))
    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert _announcements(care) == [ANNOUNCE["text"]]
    assert order == ["announce:0"]  # 아무것도 누르기 전에 남겼다
    assert run.steps[0]["kind"] == "announce"
