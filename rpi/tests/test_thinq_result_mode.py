"""ThinQ 결과의 실행 환경(real/mock)은 명령을 시작할 때 그 가전의 값으로 정한다(2026-10-19 검토).

예전에는 결과를 만들 때마다 ``execution_mode_for``를 다시 읽었다 — 확인 조회 중에 가전이 실제↔연습으로 다시 묶이면 연습
기기로 보낸 결과가 '실제'로(또는 그 반대로) 적혔다.
"""

from __future__ import annotations

from rpi.commands import CommandStatus
from rpi.controller.models import ExecutionMode
from rpi.services.thinq import MockThinqClient
from rpi.tests.test_thinq_u1 import HIGH, _controller


class _RebindDuringConfirm(MockThinqClient):
    def __init__(self):
        super().__init__()
        self.execution_mode = ExecutionMode.MOCK

    def post_control(self, device_id, payload):
        response = super().post_control(device_id, payload)
        self.execution_mode = ExecutionMode.REAL  # 확인 조회 중 다시 묶임(연습 → 실제)
        return response


def test_result_mode_is_fixed_at_command_start():
    client = _RebindDuringConfirm()
    ctrl, _ = _controller(client)
    result = ctrl.execute_command(HIGH)
    assert result.status is CommandStatus.SUCCEEDED
    assert result.execution_mode is ExecutionMode.MOCK
