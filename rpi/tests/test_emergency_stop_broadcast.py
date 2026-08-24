"""긴급 정지 브로드캐스트 — 병렬 전송·락 비점유 (최종 교차 리뷰 중요).

이전에는 서비스 락을 잡은 채 노드마다 순차로 HTTP 정지를 보냈다. 죽은 노드가
앞에 몇 개 있으면 실제 실행 중인 노드까지 정지가 도달하는 데 노드 수 × 2초가
걸렸고, 그동안 /status와 신규 실행 판정도 같은 락에서 막혔다.
"""

import threading
import time

from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
from rpi.services import NodeRegistry
from rpi.verifier import MockVerifier

NODE_STOP_DELAY = 0.3  # 죽은 노드의 정지 요청 타임아웃을 흉내


class SlowNode:
    """request_stop이 느린 노드 — 응답 없는 ESP32(타임아웃)의 대역."""

    def __init__(self, base_url: str) -> None:
        self.base_url = base_url
        self.stopped_at: float | None = None

    def execute(self, buttons):
        raise AssertionError("not used")

    def request_stop(self) -> None:
        time.sleep(NODE_STOP_DELAY)
        self.stopped_at = time.monotonic()


def _make_service(registry: NodeRegistry) -> SimpleLayService:
    controller = ClosedLoopController(
        MockGrblClient(),
        MockVerifier(outcomes=[True] * 20),
        MockAlertSink(),
        MockSafetyController(),
    )
    return SimpleLayService(
        RuleBasedIntentResolver(), controller, node_registry=registry
    )


def _registry_with(count: int) -> NodeRegistry:
    registry = NodeRegistry(controller_factory=SlowNode)
    for i in range(count):
        registry.register(f"appliance-{i}", f"http://node-{i}:8080")
    return registry


def test_node_stops_are_sent_in_parallel_not_serially():
    registry = _registry_with(4)
    service = _make_service(registry)

    started = time.monotonic()
    service.emergency_stop()
    elapsed = time.monotonic() - started

    # 순차였다면 4 × 0.3 = 1.2초. 병렬이면 한 번의 지연에 수렴한다.
    assert elapsed < NODE_STOP_DELAY * 2.5, f"took {elapsed:.2f}s — 순차 전송 의심"
    nodes = [registry.get(f"appliance-{i}") for i in range(4)]
    assert all(n.stopped_at is not None for n in nodes)


def test_status_is_not_blocked_while_node_stops_are_in_flight():
    # 정지 브로드캐스트가 서비스 락을 잡고 있으면 /status가 그 뒤에서 굶는다
    registry = _registry_with(3)
    service = _make_service(registry)

    stop_thread = threading.Thread(target=service.emergency_stop)
    stop_thread.start()
    time.sleep(NODE_STOP_DELAY / 3)  # 브로드캐스트가 진행 중인 시점

    started = time.monotonic()
    service.status()
    status_elapsed = time.monotonic() - started

    assert status_elapsed < NODE_STOP_DELAY / 2, (
        f"/status가 {status_elapsed:.2f}s 대기 — 정지 경로가 락을 쥐고 있음"
    )
    stop_thread.join()


def test_local_controller_stop_still_happens_before_returning():
    # 로컬 컨트롤러 정지는 락 안에서 즉시 — 노드 지연에 영향받지 않는다
    registry = _registry_with(2)
    service = _make_service(registry)

    service.emergency_stop()

    assert service._controller._stop_requested.is_set()


def test_emergency_stop_without_nodes_returns_running_flag():
    service = _make_service(NodeRegistry(controller_factory=SlowNode))

    assert service.emergency_stop() is False
