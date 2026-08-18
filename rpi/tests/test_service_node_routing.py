"""SimpleLayService routes execute_buttons/execute_purpose/
execute_purpose_for_appliance to a per-appliance node when one is
registered, and falls back to the local default controller otherwise --
this is the whole point of NodeRegistry (see rpi/services/node_registry.py).
"""

from rpi.api import SimpleLayService
from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ClosedLoopController,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import MockLlmClient
from rpi.services import NodeRegistry
from rpi.verifier import MockVerifier


class _FakeNodeController:
    """Records the buttons it was asked to execute; always reports success."""

    def __init__(self, base_url: str) -> None:
        self.base_url = base_url
        self.calls: list[list[str]] = []

    def execute(self, buttons):
        self.calls.append(list(buttons))
        results = tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons)
        return ExecutionResult(ExecutionStatus.SUCCEEDED, results)


def _make_service(node_registry: NodeRegistry | None = None) -> tuple[SimpleLayService, MockGrblClient]:
    grbl = MockGrblClient()
    local_controller = ClosedLoopController(
        grbl, MockVerifier(outcomes=[True] * 20), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        local_controller,
        node_registry=node_registry,
        llm_client=MockLlmClient({"우유 데워줘": '{"sequence": ["시작"]}'}),
    )
    return service, grbl


def _make_registry() -> NodeRegistry:
    return NodeRegistry(controller_factory=_FakeNodeController)


def test_execute_buttons_without_appliance_id_uses_local_controller():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    service, grbl = _make_service(registry)

    service.execute_buttons(("시작",))

    assert [c.button for c in grbl.commands] == ["시작"]


def test_execute_buttons_with_registered_appliance_id_routes_to_node():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    service, grbl = _make_service(registry)

    service.execute_buttons(("시작",), appliance_id="microwave")

    assert grbl.commands == []  # local controller never touched
    node = registry.get("microwave")
    assert node.calls == [["시작"]]


def test_execute_buttons_with_unregistered_appliance_id_falls_back_to_local():
    registry = _make_registry()  # "microwave" never registered
    service, grbl = _make_service(registry)

    service.execute_buttons(("시작",), appliance_id="microwave")

    assert [c.button for c in grbl.commands] == ["시작"]


def test_execute_buttons_with_appliance_id_but_no_registry_falls_back_to_local():
    service, grbl = _make_service(node_registry=None)

    service.execute_buttons(("시작",), appliance_id="microwave")

    assert [c.button for c in grbl.commands] == ["시작"]


def test_execute_purpose_routes_to_node_when_registered():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    service, grbl = _make_service(registry)

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    assert grbl.commands == []
    node = registry.get("microwave")
    assert node.calls == [["해동", "시간 90초", "시작"]]


def test_execute_purpose_for_appliance_routes_to_node_when_registered():
    registry = _make_registry()
    registry.register("aircon", "http://node")
    service, grbl = _make_service(registry)

    service.execute_purpose_for_appliance(
        "우유 데워줘", frozenset({"시작"}), appliance_id="aircon"
    )

    assert grbl.commands == []
    node = registry.get("aircon")
    assert node.calls == [["시작"]]


def test_different_appliances_route_to_different_nodes():
    registry = _make_registry()
    registry.register("microwave", "http://node-a")
    registry.register("aircon", "http://node-b")
    service, _grbl = _make_service(registry)

    service.execute_buttons(("해동",), appliance_id="microwave")
    service.execute_buttons(("냉방",), appliance_id="aircon")

    assert registry.get("microwave").calls == [["해동"]]
    assert registry.get("aircon").calls == [["냉방"]]


def test_status_reflects_the_result_regardless_of_which_controller_ran():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    service, _grbl = _make_service(registry)

    result = service.execute_buttons(("시작",), appliance_id="microwave")

    assert service.status().last_result is result
    assert service.status().running is False
