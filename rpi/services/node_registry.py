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
from typing import Protocol

from rpi.controller import ButtonSequenceController

from .esp_node_controller import EspNodeController

ControllerFactory = Callable[[str], ButtonSequenceController]


class NodeStore(Protocol):
    """등록된 노드 주소의 영속 저장소 — SimpleLayDb(persistence.py)가 구현."""

    def save_node(self, appliance_id: str, base_url: str) -> None: ...

    def delete_node(self, appliance_id: str) -> None: ...

    def nodes(self) -> dict[str, str]: ...


class NodeRegistry:
    def __init__(
        self,
        controller_factory: ControllerFactory = EspNodeController,
        store: NodeStore | None = None,
    ) -> None:
        self._controller_factory = controller_factory
        # 메모리 잠금(``_lock``)은 DB를 기다리는 동안 잡지 않는다 — 정지 경로(``_stoppable_nodes``, 서비스 잠금 안)가
        # 읽는다(2026-10-14 HIGH 재확인). DB 쓰기는 ``_persist_lock``으로 순서를 지킨다(메모리 바꾼 순서 = DB 쓴 순서).
        self._lock = threading.Lock()
        self._persist_lock = threading.Lock()
        self._store = store
        # store가 있으면 서버 재시작 시 이전 등록을 복원한다 — 키오스크에서
        # 등록한 ESP32 IP가 재시작마다 증발하던 문제의 수리 지점.
        self._base_urls: dict[str, str] = (
            dict(store.nodes()) if store is not None else {}
        )
        self._controllers: dict[str, ButtonSequenceController] = {}

    def register(self, appliance_id: str, base_url: str) -> None:
        """Record (or replace) an appliance's node address. Replacing an
        address drops any cached controller for it, so the next lookup
        builds a fresh one against the new address."""
        with self._persist_lock:
            with self._lock:
                self._base_urls[appliance_id] = base_url
                self._controllers.pop(appliance_id, None)
            if self._store is not None:
                self._store.save_node(appliance_id, base_url)

    def unregister(self, appliance_id: str) -> None:
        with self._persist_lock:
            with self._lock:
                self._base_urls.pop(appliance_id, None)
                controller = self._controllers.pop(appliance_id, None)
            if self._store is not None:
                self._store.delete_node(appliance_id)
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
