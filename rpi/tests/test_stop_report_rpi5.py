"""일반 정지(/stop → RPi4 abort)의 확인 단계 — RPi5 쪽(2026-10-13, 정지 보고 규약 1).

docs/계획-정지-확인-2026-10-12.md 3단계. RPi5는 ``abort``에 ``stop_id``를 싣고, RPi4가 ``stop_report``로 알린
단계(``sent``·``mcu_ack``·``verified``)를 /stop 응답과 /status에 옮긴다. ``stop_confirmed``는 ``mcu_ack`` 이상일
때만 참이다. 정지 보고 규약을 모르는 옛 RPi4면 기다리지 않고 ``sent``(보냄)로만 말한다.
모션 MCU는 가짜(rpi/tools/fake_mcu.py) — **실물 미검증.**
"""

from __future__ import annotations

import asyncio
import json
import threading
import time

import httpx
import pytest

from rpi.api import SimpleLayService
from rpi.api.deps import get_service
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.controller.serial_motion import InMemoryLinePipe, SerialMotionClient
from rpi.intent import RuleBasedIntentResolver
from rpi.main import app
from rpi.services.act_client import ActClient
from rpi.services.act_client_controller import ActClientController, start_background_loop
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu


class _Writer:
    def __init__(self) -> None:
        self.docs: list[dict] = []

    def write(self, data: bytes) -> None:
        self.docs.extend(json.loads(x) for x in data.splitlines() if x.strip())

    async def drain(self) -> None:
        pass


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc) + "\n").encode())


async def _client(act_info: dict) -> tuple[ActClient, asyncio.StreamReader, _Writer]:
    reader, writer = asyncio.StreamReader(), _Writer()
    client = ActClient(reader, writer)
    await client.start()
    _feed(reader, {"type": "act_info", **act_info})
    for _ in range(50):
        if client.act_info:
            break
        await asyncio.sleep(0.01)
    return client, reader, writer


# ── ActClient ─────────────────────────────────────────────────────────────


def test_abort_with_report_returns_the_rpi4_stop_report() -> None:
    async def _t():
        client, reader, writer = await _client({"motion": "serial", "stop_report_protocol": 1})

        async def rpi4():
            while not any(d.get("type") == "abort" for d in writer.docs):
                await asyncio.sleep(0.005)
            abort = next(d for d in writer.docs if d.get("type") == "abort")
            _feed(reader, {"type": "stop_report", "stop_id": abort["stop_id"], "target": "run",
                           "stop_level": "mcu_ack", "ack_ms": 14})

        task = asyncio.create_task(rpi4())
        report = await client.abort_with_report(timeout_s=1.0)
        await task
        await client.stop()
        return report, writer.docs

    report, docs = asyncio.run(_t())
    assert report["stop_level"] == "mcu_ack" and report["ack_ms"] == 14 and report["target"] == "run"
    abort = next(d for d in docs if d.get("type") == "abort")
    assert isinstance(abort["stop_id"], str) and abort["stop_id"]


def test_old_rpi4_without_the_stop_report_protocol_is_not_waited_for() -> None:
    async def _t():
        client, _reader, writer = await _client({"motion": "serial"})  # 정지 보고 규약 없음
        started = time.monotonic()
        report = await client.abort_with_report(timeout_s=2.0)
        elapsed = time.monotonic() - started
        await client.stop()
        return report, elapsed, writer.docs

    report, elapsed, docs = asyncio.run(_t())
    assert elapsed < 0.2
    assert report["stop_level"] == "sent"
    assert any(d.get("type") == "abort" for d in docs)  # 정지는 그대로 나갔다


def test_missing_stop_report_falls_back_to_sent_after_the_deadline() -> None:
    async def _t():
        client, _reader, _writer = await _client({"motion": "serial", "stop_report_protocol": 1})
        report = await client.abort_with_report(timeout_s=0.1)
        await client.stop()
        return report

    report = asyncio.run(_t())
    assert report["stop_level"] == "sent" and report["ack_ms"] is None


def test_a_report_with_an_unknown_level_is_read_as_sent() -> None:
    async def _t():
        client, reader, writer = await _client({"motion": "serial", "stop_report_protocol": 1})

        async def rpi4():
            while not any(d.get("type") == "abort" for d in writer.docs):
                await asyncio.sleep(0.005)
            abort = next(d for d in writer.docs if d.get("type") == "abort")
            _feed(reader, {"type": "stop_report", "stop_id": abort["stop_id"], "target": "run",
                           "stop_level": "definitely_stopped", "ack_ms": 3})

        task = asyncio.create_task(rpi4())
        report = await client.abort_with_report(timeout_s=1.0)
        await task
        await client.stop()
        return report

    report = asyncio.run(_t())
    assert report["stop_level"] == "sent" and report["ack_ms"] is None


# ── 서비스·/stop·/status ────────────────────────────────────────────────────


class _StubLink:
    """RPi4 링크 대역 — 실행을 정지까지 붙잡고, 정지 보고를 정해 둔 값으로 돌려준다."""

    supports_button_targets = False

    def __init__(self, report: dict | None) -> None:
        self.report = report
        self.stops = 0
        self._stopped = threading.Event()

    def execute(self, buttons, targets=None):
        self._stopped.wait(3.0)
        return ExecutionResult(status=ExecutionStatus.SAFETY_STOPPED,
                               buttons=(ButtonResult(buttons[0], ButtonStatus.FAILED, 1, None),))

    def request_stop(self) -> None:
        self.stops += 1
        self._stopped.set()

    def reset_stop(self) -> None:
        self._stopped.clear()

    def wait_stop_report(self, timeout_s: float | None = None) -> dict | None:
        return self.report


async def _post(path: str) -> dict:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        res = await (client.post(path) if path == "/stop" else client.get(path))
        assert res.status_code == 200, res.text
        return res.json()


def _with_service(service: SimpleLayService, path: str) -> dict:
    app.dependency_overrides[get_service] = lambda: service
    try:
        return asyncio.run(_post(path))
    finally:
        app.dependency_overrides.pop(get_service, None)


@pytest.mark.parametrize(("report", "confirmed"), [
    ({"stop_level": "mcu_ack", "ack_ms": 7, "target": "run"}, True),
    ({"stop_level": "verified", "ack_ms": 7, "target": "run"}, True),
    ({"stop_level": "sent", "ack_ms": None, "target": "run"}, False),
])
def test_stop_endpoint_reports_the_motion_stop_level(report, confirmed) -> None:
    service = SimpleLayService(RuleBasedIntentResolver(), _StubLink(report))
    body = _with_service(service, "/stop")
    assert body["stop_level"] == report["stop_level"]
    assert body["stop_ack_ms"] == report["ack_ms"]
    assert body["stop_target"] == "run"
    assert body["stop_confirmed"] is confirmed


def test_stop_endpoint_without_a_motion_report_has_no_level() -> None:
    """로컬 모의(보고 수단 없음)·유휴 RPi4는 단계를 지어내지 않는다."""
    service = SimpleLayService(RuleBasedIntentResolver(), _StubLink({"stop_level": None, "target": "idle"}))
    body = _with_service(service, "/stop")
    assert body["stop_level"] is None and body["stop_confirmed"] is False


def test_status_carries_the_last_stop_level_until_the_next_run() -> None:
    link = _StubLink({"stop_level": "mcu_ack", "ack_ms": 21, "target": "run"})
    service = SimpleLayService(RuleBasedIntentResolver(), link)
    service.emergency_stop_report()
    status = _with_service(service, "/status")
    assert status["last_stop_level"] == "mcu_ack" and status["last_stop_ack_ms"] == 21
    # 새 실행이 시작되면 지난 정지의 단계는 지운다(다음 정지 화면에 섞이지 않게).
    service._begin_run(1)
    service._end_run()
    status = _with_service(service, "/status")
    assert status["last_stop_level"] is None and status["last_stop_ack_ms"] is None


# ── 끝-끝: ActClientController ⇄ ActExecutor ⇄ SerialMotionClient ⇄ 가짜 MCU ─────────


class _BlockingController:
    def __init__(self, motion: SerialMotionClient) -> None:
        self._motion = motion
        self._stopped = threading.Event()

    def execute(self, buttons, targets=None):
        self._stopped.wait(3.0)
        return ExecutionResult(status=ExecutionStatus.SAFETY_STOPPED,
                               buttons=(ButtonResult(buttons[0], ButtonStatus.FAILED, 1, None),))

    def request_stop(self) -> None:
        self._motion.request_stop()
        self._stopped.set()

    def reset_stop(self) -> None:
        self._stopped.clear()


class _PipeWriter:
    def __init__(self, peer: asyncio.StreamReader) -> None:
        self._peer = peer

    def write(self, data: bytes) -> None:
        self._peer.feed_data(data)

    async def drain(self) -> None:
        pass


def test_general_stop_reaches_the_mcu_and_comes_back_with_its_level() -> None:
    from rpi4.services.act_executor import ActExecutor

    loop, thread = start_background_loop()
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    motion = SerialMotionClient(pipe.host, REHEARSAL_CONFIG, poll_s=0.01)
    motion.connect()

    async def build():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        executor = ActExecutor(reader=rpi4_reader, writer=_PipeWriter(rpi5_reader),
                               controller=_BlockingController(motion), motion_stop=motion)
        task = asyncio.create_task(executor.run())
        client = ActClient(rpi5_reader, _PipeWriter(rpi4_reader), hello=True)
        await client.start()
        return task, client

    task, client = asyncio.run_coroutine_threadsafe(build(), loop).result(5)
    act = ActClientController(loop, client)
    try:
        deadline = time.monotonic() + 3
        while not act.rehearsal_status().get("stop_report_protocol") and time.monotonic() < deadline:
            time.sleep(0.01)
        act.arm_execute_target("microwave")
        runner = threading.Thread(target=lambda: act.execute(["시작"]), daemon=True)
        runner.start()
        time.sleep(0.1)
        act.request_stop()
        report = act.wait_stop_report(2.0)
        runner.join(3)
    finally:
        asyncio.run_coroutine_threadsafe(client.stop(), loop).result(5)
        loop.call_soon_threadsafe(task.cancel)
        time.sleep(0.05)
        loop.call_soon_threadsafe(loop.stop)
        thread.join(2)
        mcu.close()
    assert report is not None
    assert report["target"] == "run"
    assert report["stop_level"] in ("mcu_ack", "verified")
    assert isinstance(report["ack_ms"], int)
    assert "stop" in mcu.cmds()
