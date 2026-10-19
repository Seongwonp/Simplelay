"""RPi4가 누르기 전에 분명히 거절한 실행은 '연결이 끊겨 눌렸는지 몰라요'가 아니다(2026-10-19 검토 LOW-MED).

RPi4는 ``busy``·``estop_latched``·``motion_not_ready``·``target_bind_failed``·``hold_busy``·``dev_busy`` 등으로 거절할 때
아무 버튼도 누르지 않았다는 것을 안다(실행을 시작하기 전에 ``error``로 답한다). 예전에는 RPi5가 이것을 모든 ``error``와
같은 ``ActLinkError``로 올려, 서비스가 '연결이 끊겨 눌렸는지 몰라요'(수신 unknown·unconfirmed)와 보호자 '확인 못 함' 알림으로
남겼다. 이제 보내지 않음(``not_dispatched``)·실패와 거절 이유를 쉬운 말로 남기고 '모름' 알림은 내지 않는다.
누른 뒤 생길 수 있는 ``actuator_fail``(실행 중 예외)은 그대로 '눌렸는지 모름'이다.
"""

from __future__ import annotations

import asyncio
import time

import pytest

from rpi.api.service import SimpleLayService
from rpi.commands import Receipt
from rpi.controller import ExecutionStatus
from rpi.intent.rules import RuleBasedIntentResolver
from rpi.services.act_client import ActClient
from rpi.services.act_client_controller import ActClientController, start_background_loop
from rpi.tests.test_act_client_controller import (
    FakeWriter,
    _make_controller,
    _respond_in_background,
    _teardown,
    feed,
)


@pytest.mark.parametrize("reason", ["busy", "estop_latched", "motion_not_ready", "target_bind_failed",
                                    "hold_busy", "dev_busy", "outlet_offline", "target_unbound"])
def test_known_pre_press_refusal_is_a_not_dispatched_failure(reason):
    controller, loop, thread, reader, writer = _make_controller()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "error", "sequence_id": sent["sequence_id"], "reason": reason,
                          "detail": "누름 장치가 멈춘 뒤라 위치를 믿을 수 없어요. 원점을 다시 잡아야 해요."},
        )
        controller.arm_execute_target("microwave")
        result = controller.execute(["시작"])
    finally:
        _teardown(controller, loop, thread)
    assert result.status is ExecutionStatus.FAILED
    assert result.buttons == ()
    assert result.not_dispatched is True


def test_unknown_error_reason_is_still_a_link_error():
    controller, loop, thread, reader, writer = _make_controller()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "error", "sequence_id": sent["sequence_id"], "reason": "actuator_fail"},
        )
        controller.arm_execute_target("microwave")
        with pytest.raises(RuntimeError, match="actuator_fail"):
            controller.execute(["시작"])
    finally:
        _teardown(controller, loop, thread)


class _Care:
    def __init__(self):
        self.events = []

    def append(self, kind, message, purpose=None):
        self.events.append((kind, message))


def _service_over_link():
    writer = FakeWriter()
    loop, thread = start_background_loop()

    async def _setup():
        reader = asyncio.StreamReader()
        client = ActClient(reader, writer)
        await client.start()
        return client, reader

    client, reader = asyncio.run_coroutine_threadsafe(_setup(), loop).result(timeout=2.0)
    feed(loop, reader, {"type": "estop_state", "latched": False})
    deadline = time.monotonic() + 2.0
    while client.estop_latched is None:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    controller = ActClientController(loop, client, call_timeout_seconds=2.0)
    care = _Care()
    service = SimpleLayService(RuleBasedIntentResolver(), controller, care_events=care)
    return service, controller, loop, thread, reader, writer, care


def test_service_records_refusal_as_not_pressed_without_unknown_alert():
    service, controller, loop, thread, reader, writer, care = _service_over_link()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "error", "sequence_id": sent["sequence_id"], "reason": "motion_not_ready",
                          "detail": "누름 장치가 멈춘 뒤라 위치를 믿을 수 없어요. 원점을 다시 잡아야 해요."},
        )
        service.submit_buttons(("시작",), "microwave")
        deadline = time.monotonic() + 5.0
        while service.status().running:
            assert time.monotonic() < deadline
            time.sleep(0.01)
        status = service.status()
    finally:
        _teardown(controller, loop, thread)
    assert status.last_receipt == Receipt.NOT_DISPATCHED.value, status
    assert status.last_command_status != "unconfirmed", status
    assert status.last_result.status is ExecutionStatus.FAILED
    assert "누르지 않았어요" in (status.last_detail or ""), status
    assert "끊겨" not in (status.last_detail or "")
    assert not any("끊겨" in message for _, message in care.events), care.events
