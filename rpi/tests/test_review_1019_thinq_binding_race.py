"""외부 검토 2026-10-19: ThinQ 실행이 승인·시작 때 본 기기가 아닌 기기로 보낼 수 있었다.

시작 게이트는 승인 때의 ThinQ 기기를 대조하지만, 실행 스레드(실행기)는 바인딩을 다시 찾았다. 그 사이 ``/thinq/added``로
연결을 지우거나 다른 기기로 바꾸면 (1) 바뀐 새 기기로 보내거나 (2) 실행기가 조회를 기다리는 동안 바뀌면 지워진·옛 기기로
보냈다. 이제 단계가 기기 ID를 들고 가고, 보내기 바로 앞에서 같은 바인딩인지 다시 본다 — 다르면 보내지 않는다.
모의 클라이언트로만 시험 — 실물 미검증.
"""

from __future__ import annotations

import copy
from dataclasses import replace
from datetime import datetime, timezone

from rpi.commands import ApprovedCommand, Command, CommandStatus, ControlRoute, Receipt
from rpi.services.thinq import (
    MOCK_PURIFIER_ID,
    MockThinqClient,
    ThinqController,
    ThinqMode,
    air_purifier_binding,
)

HIGH = Command.thinq("air_purifier", "set_wind_strength", {"wind_strength": "HIGH"})
OTHER_ID = "mock-other-purifier"


def _add_other_device(client: MockThinqClient) -> None:
    info = client._devices[MOCK_PURIFIER_ID]
    client._devices[OTHER_ID] = replace(info, device_id=OTHER_ID, alias="다른 공기청정기(모의)")
    client._device_online[OTHER_ID] = True
    client._state[OTHER_ID] = copy.deepcopy(client._state[MOCK_PURIFIER_ID])
    client._profiles[OTHER_ID] = copy.deepcopy(client._profiles[MOCK_PURIFIER_ID])


def _env():
    from rpi.api.service import SimpleLayService
    from rpi.controller import ClosedLoopController
    from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
    from rpi.intent.mock import FixedClock
    from rpi.intent.rules import RuleBasedIntentResolver
    from rpi.services.appliance_registry import ApplianceCategory, ApplianceDef, ApplianceRegistry
    from rpi.verifier import MockVerifier

    registry = ApplianceRegistry()

    def install(binding):
        registry.unregister_system("air_purifier")
        if binding is not None:
            registry.register_system(ApplianceDef(
                appliance_id="air_purifier", name="공기청정기(모의)", rows=0, cols=0, buttons=(),
                category=ApplianceCategory.AIR_PURIFIER, control_path=ControlRoute.THINQ, thinq=binding,
            ))

    install(air_purifier_binding(MOCK_PURIFIER_ID))
    client = MockThinqClient()
    _add_other_device(client)
    thinq = ThinqController(
        client, lambda aid: getattr(registry.get(aid), "thinq", None),
        mode=ThinqMode.MOCK, confirm_seconds=0.2, poll_interval=0.0, sleep=lambda s: None,
    )
    clock = FixedClock(datetime(2026, 10, 19, 20, tzinfo=timezone.utc))
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(MockGrblClient(), MockVerifier([True] * 4), MockAlertSink(), MockSafetyController()),
        clock=clock, appliance_registry=registry, thinq_controller=thinq,
    )
    approved = ApprovedCommand(HIGH, "card-1", clock.now(), "공기청정기 바람 세게")
    return service, client, install, approved


def test_binding_replaced_after_start_gate_is_not_sent_to_the_new_device():
    service, client, install, approved = _env()
    original_begin = service._begin_run

    def begin_then_replace(*args, **kwargs):
        job_id = original_begin(*args, **kwargs)
        install(air_purifier_binding(OTHER_ID))  # 시작 게이트 뒤·실행기가 바인딩을 찾기 전에 다른 기기로
        return job_id

    service._begin_run = begin_then_replace  # type: ignore[method-assign]
    record = service.execute_approved((approved,))

    assert client.controls == []
    (result,) = record.results
    assert result.status is CommandStatus.FAILED
    assert result.receipt is Receipt.NOT_DISPATCHED


def _controller_with_swap(swap_to):
    client = MockThinqClient()
    _add_other_device(client)
    holder = {"binding": air_purifier_binding(MOCK_PURIFIER_ID)}
    ctrl = ThinqController(
        client, lambda aid: holder["binding"] if aid == "air_purifier" else None,
        mode=ThinqMode.MOCK, confirm_seconds=0.05, poll_interval=0.0, sleep=lambda s: None,
    )
    original_status = client.get_status

    def get_status(device_id):
        state = original_status(device_id)
        holder["binding"] = swap_to  # 실행기가 조회를 기다리는 동안 연결이 바뀌거나 지워졌다
        return state

    client.get_status = get_status  # type: ignore[method-assign]
    return ctrl, client


def test_binding_removed_while_executor_reads_status_is_not_sent():
    ctrl, client = _controller_with_swap(None)
    result = ctrl.execute_command(HIGH)
    assert client.controls == []
    assert result.receipt is Receipt.NOT_DISPATCHED
    assert result.status is CommandStatus.FAILED


def test_binding_replaced_while_executor_reads_status_is_not_sent_to_the_old_device():
    ctrl, client = _controller_with_swap(air_purifier_binding(OTHER_ID))
    result = ctrl.execute_command(HIGH)
    assert client.controls == []
    assert result.receipt is Receipt.NOT_DISPATCHED
