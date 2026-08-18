"""Maps appliance_id -> that appliance's Act node controller, so
SimpleLayService can route an execute() call to the right physical node
instead of assuming one single co-located controller (see long-term
multi-node plan: RPi5 is one central hub, a node is attached per
appliance).

Node controllers are constructed lazily and cached: register() only stores
the node's address, the first lookup after that builds the actual
controller via ``controller_factory`` (default: EspNodeController, i.e.
dev-mode HTTP -- swap the factory for the ESP-NOW controller once that
exists, without touching this class).
"""

from __future__ import annotations

import threading
from collections.abc import Callable

from rpi.controller import ButtonSequenceController

from .esp_node_controller import EspNodeController

ControllerFactory = Callable[[str], ButtonSequenceController]


class NodeRegistry:
    def __init__(self, controller_factory: ControllerFactory = EspNodeController) -> None:
        self._controller_factory = controller_factory
        self._lock = threading.Lock()
        self._base_urls: dict[str, str] = {}
        self._controllers: dict[str, ButtonSequenceController] = {}

    def register(self, appliance_id: str, base_url: str) -> None:
        """Record (or replace) an appliance's node address. Replacing an
        address drops any cached controller for it, so the next lookup
        builds a fresh one against the new address."""
        with self._lock:
            self._base_urls[appliance_id] = base_url
            self._controllers.pop(appliance_id, None)

    def unregister(self, appliance_id: str) -> None:
        with self._lock:
            self._base_urls.pop(appliance_id, None)
            controller = self._controllers.pop(appliance_id, None)
        if controller is not None:
            close = getattr(controller, "close", None)
            if close is not None:
                close()

    def get(self, appliance_id: str) -> ButtonSequenceController | None:
        """Returns the node's controller, building and caching it on first
        use. None if this appliance_id was never registered."""
        with self._lock:
            if appliance_id not in self._base_urls:
                return None
            controller = self._controllers.get(appliance_id)
            if controller is None:
                controller = self._controller_factory(self._base_urls[appliance_id])
                self._controllers[appliance_id] = controller
            return controller

    def base_url(self, appliance_id: str) -> str | None:
        with self._lock:
            return self._base_urls.get(appliance_id)

    def list_appliance_ids(self) -> list[str]:
        with self._lock:
            return list(self._base_urls)
