"""POST /stop — 이벤트 루프를 막지 않고, 노드별 전달 결과를 드러낸다.

이전에는 async 핸들러가 동기 정지 브로드캐스트를 직접 불렀다. 응답 없는
노드를 전체 상한(2.5초)까지 기다리는 동안 같은 루프의 /status·SSE·다른
API가 모두 멈췄다. 응답도 was_running만 담아 정지 요청이 닿지 않은 노드를
알 수 없었다.

응답은 **요청 접수·전달**까지만 말한다. 물리 정지 확인은 이 API의 계약이
아니다(docs/하드웨어-연결-설계.md).
"""

import asyncio
import time

import httpx
import pytest

import rpi.api.service as service_module
from rpi.api import SimpleLayService
from rpi.api.deps import get_service
from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
from rpi.main import app
from rpi.services import NodeRegistry
from rpi.verifier import MockVerifier


class _Node:
    """정지 요청의 결과만 흉내 내는 노드 대역."""

    def __init__(self, behavior: str, delay: float = 0.0) -> None:
        self._behavior = behavior
        self._delay = delay
        self.stop_requests = 0

    def execute(self, buttons):  # pragma: no cover - 쓰이지 않음
        raise AssertionError("not used")

    def request_stop(self):
        self.stop_requests += 1
        if self._delay:
            time.sleep(self._delay)
        if self._behavior == "ack":
            return True
        if self._behavior == "refused":
            return False
        if self._behavior == "raises":
            raise RuntimeError("link down")
        return None  # 수신 확인 수단 없음(fire-and-forget)


def _service_with(nodes: dict[str, _Node]) -> SimpleLayService:
    by_url = {f"http://{appliance_id}": node for appliance_id, node in nodes.items()}
    registry = NodeRegistry(controller_factory=lambda url: by_url[url])
    for appliance_id in nodes:
        registry.register(appliance_id, f"http://{appliance_id}")
    controller = ClosedLoopController(
        MockGrblClient(),
        MockVerifier(outcomes=[True] * 20),
        MockAlertSink(),
        MockSafetyController(),
    )
    return SimpleLayService(
        RuleBasedIntentResolver(), controller, node_registry=registry
    )


def test_report_separates_acknowledged_from_unconfirmed_nodes(monkeypatch):
    monkeypatch.setattr(service_module, "EMERGENCY_STOP_BROADCAST_SECONDS", 0.2)
    nodes = {
        "fan": _Node("ack"),
        "rice": _Node("refused"),
        "washer": _Node("raises"),
        "kettle": _Node("unknown"),
        "oven": _Node("ack", delay=0.6),  # 기한 안에 답하지 못함
    }
    service = _service_with(nodes)

    report = service.emergency_stop_report()

    assert report.was_running is False
    assert report.nodes_acknowledged == ("fan",)
    assert sorted(report.nodes_unconfirmed) == ["kettle", "oven", "rice", "washer"]
    # 미확인이어도 요청은 모든 노드에 나갔다 — "덜 멈추는 것"이 더 위험하다
    assert all(node.stop_requests == 1 for node in nodes.values())


def test_legacy_emergency_stop_still_returns_running_flag():
    service = _service_with({"fan": _Node("ack")})

    assert service.emergency_stop() is False


def test_stop_endpoint_returns_node_delivery_fields(monkeypatch):
    monkeypatch.setattr(service_module, "EMERGENCY_STOP_BROADCAST_SECONDS", 0.2)
    service = _service_with({"fan": _Node("ack"), "rice": _Node("refused")})
    app.dependency_overrides[get_service] = lambda: service
    try:
        body = asyncio.run(_post_stop())
    finally:
        app.dependency_overrides.pop(get_service, None)

    assert body["ok"] is True
    assert body["nodes_requested"] == 2
    assert body["nodes_acknowledged"] == ["fan"]
    assert body["nodes_unconfirmed"] == ["rice"]


async def _post_stop() -> dict:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        res = await client.post("/stop")
        assert res.status_code == 200
        return res.json()


SLOW_NODE_SECONDS = 0.6


def test_slow_node_stop_does_not_block_other_requests(monkeypatch):
    monkeypatch.setattr(service_module, "EMERGENCY_STOP_BROADCAST_SECONDS", 2.0)
    service = _service_with({"dead": _Node("ack", delay=SLOW_NODE_SECONDS)})
    app.dependency_overrides[get_service] = lambda: service
    try:
        status_elapsed, stop_elapsed = asyncio.run(_stop_while_polling_status())
    finally:
        app.dependency_overrides.pop(get_service, None)

    # 정지가 루프를 막으면 /status가 느린 노드 뒤에서 기다린다. 시각은
    # /stop을 보낸 시점부터 잰다 — 루프가 막히면 테스트 쪽 대기와 /status
    # 요청 시작도 함께 밀리므로, /status 요청 시점부터 재면 차단이 가려진다.
    assert status_elapsed < SLOW_NODE_SECONDS * 0.6, (
        f"/stop 후 {status_elapsed:.2f}s에야 /status 응답 — /stop이 이벤트 루프를 막음"
    )
    # 느린 노드도 기한 안이면 끝까지 기다려 결과에 반영한다
    assert stop_elapsed >= SLOW_NODE_SECONDS * 0.9


async def _stop_while_polling_status() -> tuple[float, float]:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        started = time.monotonic()
        stop_task = asyncio.create_task(client.post("/stop"))
        await asyncio.sleep(SLOW_NODE_SECONDS / 6)  # 브로드캐스트가 진행 중인 시점

        status = await client.get("/status")
        status_elapsed = time.monotonic() - started
        assert status.status_code == 200

        stop = await stop_task
        stop_elapsed = time.monotonic() - started
        assert stop.status_code == 200
        assert stop.json()["nodes_acknowledged"] == ["dead"]
        return status_elapsed, stop_elapsed


@pytest.fixture(autouse=True)
def _reset_service_singleton():
    get_service.cache_clear()
    yield
    get_service.cache_clear()
