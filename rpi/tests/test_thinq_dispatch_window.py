"""ThinQ 실행기의 '보냄' 표시는 POST를 클라이언트에 넘기기 바로 앞에만 선다(2026-10-19 검토).

예전에는 표시를 세운 뒤 잠금을 놓고 표시용 상태 기억을 지우는 호출(observe)을 거쳐 POST했다 — 그 틈의 정지는 '이미 보내 취소
못 함'이라고 답했는데 실제로는 아직 안 보냈고 곧 보냈다. 이제 그 기억 지우기를 마지막 정지 확인 앞으로 옮겨, 그 틈의 정지는
'보내기 전 취소'이고 아무것도 보내지 않는다.
"""

from __future__ import annotations

from rpi.commands import CommandStatus, Receipt
from rpi.services.thinq import StopOutcome
from rpi.tests.test_thinq_u1 import HIGH, _controller


def test_stop_in_the_window_before_post_cancels_and_sends_nothing():
    seen = {"outcome": None}
    holder = {}

    def observe(appliance_id, binding, state):
        # 보내기 직전 상태 기억을 지우는 호출(None) — 그 순간 /stop
        if state is None and seen["outcome"] is None:
            seen["outcome"] = holder["ctrl"].request_stop()

    ctrl, client = _controller(observe_state=observe)
    holder["ctrl"] = ctrl
    result = ctrl.execute_command(HIGH)
    assert seen["outcome"] is StopOutcome.CANCELLED_BEFORE_DISPATCH
    assert result.status is CommandStatus.STOPPED
    assert result.receipt is Receipt.NOT_DISPATCHED
    assert client.controls == []


def test_already_at_target_keeps_the_observed_state():
    """이미 목표값이면 보내지 않으므로 방금 본 상태 기억을 지우지 않는다(옮긴 기억 지우기가 이 경우를 건드리지 않게)."""
    states = []
    ctrl, client = _controller(observe_state=lambda aid, b, state: states.append(state))
    first = ctrl.execute_command(HIGH)
    assert first.status is CommandStatus.SUCCEEDED
    states.clear()
    again = ctrl.execute_command(HIGH)
    assert again.receipt is Receipt.NOT_DISPATCHED  # 이미 목표값
    assert None not in states, states
