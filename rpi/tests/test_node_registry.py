"""NodeRegistry tests — fake controller factory, no real HTTP/hardware."""

import pytest

from rpi.services.node_registry import NodeRegistry


class _FakeController:
    """Records its base_url and close() calls; execute() unused here since
    routing (not execution) is what this test file cares about."""

    def __init__(self, base_url: str) -> None:
        self.base_url = base_url
        self.closed = False

    def close(self) -> None:
        self.closed = True


def _make_registry() -> NodeRegistry:
    return NodeRegistry(controller_factory=_FakeController)


def test_unregistered_appliance_returns_none():
    registry = _make_registry()
    assert registry.get("microwave") is None


def test_registered_appliance_returns_a_controller_for_its_base_url():
    registry = _make_registry()
    registry.register("microwave", "http://192.168.1.10:8080")

    controller = registry.get("microwave")

    assert isinstance(controller, _FakeController)
    assert controller.base_url == "http://192.168.1.10:8080"


def test_controller_is_cached_across_lookups():
    registry = _make_registry()
    registry.register("microwave", "http://node")

    first = registry.get("microwave")
    second = registry.get("microwave")

    assert first is second


def test_reregistering_a_different_address_drops_the_cached_controller():
    registry = _make_registry()
    registry.register("microwave", "http://old-node")
    old_controller = registry.get("microwave")

    registry.register("microwave", "http://new-node")
    new_controller = registry.get("microwave")

    assert new_controller is not old_controller
    assert new_controller.base_url == "http://new-node"


def test_multiple_appliances_get_independent_controllers():
    registry = _make_registry()
    registry.register("microwave", "http://node-a")
    registry.register("aircon", "http://node-b")

    microwave = registry.get("microwave")
    aircon = registry.get("aircon")

    assert microwave.base_url == "http://node-a"
    assert aircon.base_url == "http://node-b"
    assert microwave is not aircon


def test_unregister_closes_the_cached_controller():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    controller = registry.get("microwave")

    registry.unregister("microwave")

    assert controller.closed is True
    assert registry.get("microwave") is None


def test_unregister_unknown_appliance_does_not_raise():
    registry = _make_registry()
    registry.unregister("no-such-appliance")  # should be a no-op


def test_unregister_before_any_lookup_does_not_raise():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    registry.unregister("microwave")  # never called get(), so no controller was built


def test_base_url_returns_registered_address():
    registry = _make_registry()
    registry.register("microwave", "http://node")
    assert registry.base_url("microwave") == "http://node"
    assert registry.base_url("unknown") is None


def test_list_appliance_ids_reflects_registrations():
    registry = _make_registry()
    assert registry.list_appliance_ids() == []

    registry.register("microwave", "http://a")
    registry.register("aircon", "http://b")
    assert set(registry.list_appliance_ids()) == {"microwave", "aircon"}

    registry.unregister("microwave")
    assert registry.list_appliance_ids() == ["aircon"]


def test_default_controller_factory_is_esp_node_controller():
    from rpi.services.esp_node_controller import EspNodeController

    registry = NodeRegistry()
    registry.register("microwave", "http://node")
    controller = registry.get("microwave")
    try:
        assert isinstance(controller, EspNodeController)
    finally:
        controller.close()
