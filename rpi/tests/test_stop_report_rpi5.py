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


# ── 정지 보고의 실행 결속(평가 2026-10-13 H1) ─────────────────────────────────────


class _LateReportLink(_StubLink):
    """정지 보고가 늦게 오는 RPi4 링크 대역 — ``release``가 열릴 때까지 보고를 붙잡는다."""

    def __init__(self) -> None:
        super().__init__({"stop_level": "verified", "ack_ms": 9, "target": "run"})
        self.release = threading.Event()
        self.waiting = threading.Event()

    def wait_stop_report(self, timeout_s: float | None = None, handle=None) -> dict | None:
        self.waiting.set()
        self.release.wait(3.0)
        return dict(self.report)


def _wait_until(cond, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while not cond():
        assert time.monotonic() < deadline, "조건을 기다리다 기한이 지났다"
        time.sleep(0.005)


def test_a_late_stop_report_of_the_previous_run_does_not_land_on_the_next_run() -> None:
    """J1 정지 → J1 종료 → J2 시작 → J1의 정지 보고가 늦게 도착: J2의 /status에 J1 단계가 되살아나지 않는다."""
    link = _LateReportLink()
    service = SimpleLayService(RuleBasedIntentResolver(), link)
    j1 = service.submit_buttons(("시작",))
    _wait_until(lambda: service.status().running)
    stop_result: dict = {}
    stopper = threading.Thread(target=lambda: stop_result.setdefault("r", service.emergency_stop_report()))
    stopper.start()
    _wait_until(link.waiting.is_set)
    _wait_until(lambda: not service.status().running)  # J1은 정지로 끝났다
    j2 = service.submit_buttons(("시작",))
    _wait_until(lambda: service.status().running and service.status().job_id == j2)
    link.release.set()  # 이제야 J1의 정지 보고가 돌아온다
    stopper.join(3)
    try:
        assert service.last_motion_stop() is None
        status = _with_service(service, "/status")
        assert status["job_id"] == j2
        assert status["last_stop_level"] is None and status["last_stop_ack_ms"] is None
        # /stop 응답은 그 정지가 멈춘 실행(J1)을 밝힌다 — 폰이 같은 실행일 때만 반영하게.
        assert stop_result["r"].job_id == j1
    finally:
        link.request_stop()


def test_the_stop_report_of_the_same_run_is_kept_after_the_run_ends() -> None:
    """정지 보고가 실행 종료 뒤에 와도 새 실행이 없으면 그 실행(J1)의 단계로 /status에 남는다."""
    link = _LateReportLink()
    service = SimpleLayService(RuleBasedIntentResolver(), link)
    j1 = service.submit_buttons(("시작",))
    _wait_until(lambda: service.status().running)
    stopper = threading.Thread(target=service.emergency_stop_report)
    stopper.start()
    _wait_until(link.waiting.is_set)
    _wait_until(lambda: not service.status().running)
    link.release.set()
    stopper.join(3)
    status = _with_service(service, "/status")
    assert status["last_job_id"] == j1
    assert status["last_stop_level"] == "verified" and status["last_stop_ack_ms"] == 9
    assert status["last_stop_job_id"] == j1


def test_stop_endpoint_names_the_run_it_stopped() -> None:
    link = _StubLink({"stop_level": "mcu_ack", "ack_ms": 7, "target": "run"})
    service = SimpleLayService(RuleBasedIntentResolver(), link)
    job = service.submit_buttons(("시작",))
    _wait_until(lambda: service.status().running)
    body = _with_service(service, "/stop")
    assert body["stop_job_id"] == job
    idle = _with_service(service, "/stop")  # 실행 중이 아니면 결속할 실행이 없다
    assert idle["stop_job_id"] is None


class _TwoStopClient:
    """ActClient 대역 — abort_with_report 호출마다 따로 보고를 돌려준다(늦게 오는 첫 보고)."""

    def __init__(self, loop) -> None:
        self._loop = loop
        self.gates: list[asyncio.Event] = []
        self.calls = 0

    async def abort_with_report(self):
        index = self.calls
        self.calls += 1
        gate = asyncio.Event()
        self.gates.append(gate)
        await gate.wait()
        return {"stop_id": f"s{index}", "stop_level": "verified" if index == 0 else "mcu_ack",
                "ack_ms": 10 + index, "target": "run"}


def test_each_stop_waits_for_its_own_report_not_the_latest_one() -> None:
    """연속 정지: 첫 정지의 기다림이 두 번째 정지의 보고를 제 것으로 읽지 않는다(stop 결속)."""
    loop, thread = start_background_loop()
    client = _TwoStopClient(loop)
    act = ActClientController(loop, client)
    try:
        first = act.request_stop()
        _wait_until(lambda: client.calls == 1)
        second = act.request_stop()
        _wait_until(lambda: client.calls == 2)
        loop.call_soon_threadsafe(client.gates[1].set)  # 두 번째 보고가 먼저 온다
        got_second = act.wait_stop_report(1.0, handle=second)
        loop.call_soon_threadsafe(client.gates[0].set)
        got_first = act.wait_stop_report(1.0, handle=first)
    finally:
        loop.call_soon_threadsafe(loop.stop)
        thread.join(2)
    assert got_first["stop_id"] == "s0" and got_first["stop_level"] == "verified"
    assert got_second["stop_id"] == "s1" and got_second["stop_level"] == "mcu_ack"
