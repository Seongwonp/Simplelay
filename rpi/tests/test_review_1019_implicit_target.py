"""외부 검토 2026-10-19: 대상 없는 실행(``appliance_id`` 없음)도 내장 갠트리 가전의 좌표·정지 계획을 싣는다.

누름 장치 판정은 대상 없는 실행을 내장 갠트리 가전(전자레인지)으로 풀어 통과시키는데, 좌표 스냅숏(``_targets_snapshot``)·
보정 버전·정지 대기 계획은 ``appliance_id is None``이면 비웠다. 좌표가 필요한 실제 실행 대상은 좌표 없이 받아
누르기 전에 거절하거나(실제 모션), 정지 대기 계획 없이 돌았다. 대상을 확정하는 한 곳에서 같은 대상으로 푼다.
"""

from __future__ import annotations

from rpi.api import SimpleLayService
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver
from rpi.services import ApplianceRegistry

STOP_PARK = {"stop_button": "BT-06", "stop_presses": 2, "park_xy": (10.0, 190.0)}


class _CoordController:
    supports_button_targets = True
    requires_coordinates = True

    def __init__(self) -> None:
        self.calls: list[tuple[tuple[str, ...], object]] = []
        self.holds: list[object] = []
        self.targets_armed: list[str] = []

    def arm_execute_target(self, appliance_id: str) -> None:
        self.targets_armed.append(appliance_id)

    def arm_stop_hold(self, plan) -> None:
        self.holds.append(plan)

    def execute(self, buttons, targets=None):
        self.calls.append((tuple(buttons), targets))
        return ExecutionResult(
            status=ExecutionStatus.SUCCEEDED,
            buttons=tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 0, None) for b in buttons),
        )


def _service():
    registry = ApplianceRegistry()
    registry.apply_calibration(
        "microwave", version="v1",
        coords={"BT-05": (120.0, 80.0), "BT-06": (100.0, 80.0)}, stop_park=STOP_PARK,
    )
    controller = _CoordController()
    service = SimpleLayService(RuleBasedIntentResolver(), controller, appliance_registry=registry)
    return service, controller


def test_execute_buttons_without_target_gets_builtin_gantry_coordinates_and_hold_plan():
    service, controller = _service()
    service.execute_buttons(("시작",))
    explicit_service, explicit = _service()
    explicit_service.execute_buttons(("시작",), appliance_id="microwave")

    (buttons, targets), = controller.calls
    assert buttons == ("시작",)
    assert targets is not None and "시작" in targets
    assert (targets["시작"].x_mm, targets["시작"].y_mm) == (120.0, 80.0)
    assert controller.calls == explicit.calls
    assert controller.targets_armed == ["microwave"]
    assert controller.holds and controller.holds[0] is not None
    assert controller.holds == explicit.holds
