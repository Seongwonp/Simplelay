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
    "build_controller",
    "open_uart_act_controller",
    "start_background_loop",
]
