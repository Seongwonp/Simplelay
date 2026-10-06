"""RPi5 → RPi4 execute에 대상 가전을 늘 싣는다(2026-10-07, 인계 노트북-3 §B, 평가 HIGH H3).

RPi4는 대상 없는 execute를 ``target_required``로 거절한다. 그래서 RPi5는 대상을 모르면 보내지 않고,
서비스는 실행마다 대상(``appliance_id``)을 실행 대상 컨트롤러에 건다. 모의(SimulatorController)로만 시험.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.services.act_client import ActClient, ActLinkError
from rpi.services.link_tap import LinkFrameTap


class _Writer:
    def __init__(self) -> None:
        self.buf = b""

    def write(self, data: bytes) -> None:
        self.buf += data

    async def drain(self) -> None:
        pass

    def messages(self) -> list[dict]:
        return [json.loads(line) for line in self.buf.split(b"\n") if line.strip()]


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


def test_client_execute_puts_the_target_on_the_wire():
    async def _t():
        reader, writer = asyncio.StreamReader(), _Writer()
        client = ActClient(reader=reader, writer=writer)
        await client.start()
        task = asyncio.create_task(client.execute(["시작"], sequence_id="s1", appliance_id="washer"))
        await asyncio.sleep(0)
        sent = writer.messages()
        _feed(reader, {"type": "result", "sequence_id": "s1", "success": True, "retry": 0,
                       "appliance_id": "washer"})
        await task
        await client.stop()
        return sent

    sent = asyncio.run(_t())
    assert sent == [{"type": "execute", "sequence_id": "s1", "buttons": ["시작"], "appliance_id": "washer"}]


def test_client_execute_without_target_sends_nothing():
    async def _t():
        reader, writer = asyncio.StreamReader(), _Writer()
        client = ActClient(reader=reader, writer=writer)
        await client.start()
        with pytest.raises(ActLinkError, match="target"):
            await client.execute(["시작"], sequence_id="s1")
        await client.stop()
        return writer.messages()

    assert asyncio.run(_t()) == []


def test_result_for_another_target_is_an_error():
    async def _t():
        reader, writer = asyncio.StreamReader(), _Writer()
        client = ActClient(reader=reader, writer=writer)
        await client.start()
        task = asyncio.create_task(client.execute(["시작"], sequence_id="s1", appliance_id="washer"))
        await asyncio.sleep(0)
        _feed(reader, {"type": "result", "sequence_id": "s1", "success": True, "retry": 0,
                       "appliance_id": "microwave", "operation_confirmed": True})
        with pytest.raises(ActLinkError, match="microwave"):
            await task
        await client.stop()

    asyncio.run(_t())


@pytest.fixture
def sim(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.simulator_controller import SimulatorController

    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    registry = deps.get_appliance_registry()
    controller = SimulatorController(step_seconds=0, tap=LinkFrameTap(None, transport="in_memory"))
    service = SimpleLayService(RuleBasedIntentResolver(), controller, appliance_registry=registry)
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        yield TestClient(app), controller
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        controller.close()
        for dep in (deps.get_appliance_registry, deps.get_service):
            dep.cache_clear()


def _run(c, body: dict) -> dict:
    job = c.post("/execute-buttons", json=body)
    assert job.status_code in (200, 202), job.text
    job_id = job.json()["job_id"]
    deadline = time.monotonic() + 6.0
    while True:
        status = c.get("/status").json()
        if status["last_job_id"] == job_id and not status["running"]:
            return status
        assert time.monotonic() < deadline, status
        time.sleep(0.02)


def test_service_sends_the_request_target(sim):
    c, controller = sim
    _run(c, {"buttons": ["시작"], "appliance_id": "induction"})
    frame = controller.snapshot()["last_execute_frame"]["message"]
    assert frame["appliance_id"] == "induction"


def test_service_without_appliance_sends_the_builtin_gantry_appliance(sim):
    """appliance_id 없는 옛 요청은 규칙 해석과 같은 내장 갠트리 가전(전자레인지)으로 명시해 보낸다."""
    c, controller = sim
    _run(c, {"buttons": ["시작"]})
    frame = controller.snapshot()["last_execute_frame"]["message"]
    assert frame["appliance_id"] == "microwave"


def test_controller_without_armed_target_refuses(sim):
    _c, controller = sim
    with pytest.raises(ActLinkError, match="target"):
        controller.execute(["시작"])
    assert controller.snapshot()["last_execute_frame"] is None


def test_old_rpi4_result_without_target_never_confirms_operation():
    """옛 RPi4(결과에 appliance_id 없음)의 L3 확인은 어느 가전 것인지 몰라 '모름'으로 낮춘다."""

    async def _t():
        reader, writer = asyncio.StreamReader(), _Writer()
        client = ActClient(reader=reader, writer=writer)
        await client.start()
        task = asyncio.create_task(client.execute(["시작"], sequence_id="s1", appliance_id="washer"))
        await asyncio.sleep(0)
        _feed(reader, {"type": "result", "sequence_id": "s1", "success": True, "retry": 0,
                       "operation_confirmed": True, "operation_source": "real"})
        result = await task
        await client.stop()
        return result

    result = asyncio.run(_t())
    assert result.success is True  # 나머지는 종전대로
    assert result.operation_confirmed is None
