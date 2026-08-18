"""RPi5-side outbound service adapters (currently: the RPi4 UART link)."""

from .act_client import (
    ActClient,
    ActClientConfig,
    ActLinkBusyError,
    ActLinkError,
    ActLinkTimeoutError,
    ActResult,
    AlertEvent,
)
from .act_client_controller import (
    ActClientController,
    open_uart_act_controller,
    start_background_loop,
)
from .alert_store import DangerAlertState, DangerAlertStore
from .controller_factory import build_controller
from .esp_node_controller import EspNodeController, EspNodeError
from .node_registry import NodeRegistry

__all__ = [
    "ActClient",
    "ActClientConfig",
    "ActClientController",
    "ActLinkBusyError",
    "ActLinkError",
    "ActLinkTimeoutError",
    "ActResult",
    "AlertEvent",
    "DangerAlertState",
    "DangerAlertStore",
    "EspNodeController",
    "EspNodeError",
    "NodeRegistry",
    "build_controller",
    "open_uart_act_controller",
    "start_background_loop",
]
