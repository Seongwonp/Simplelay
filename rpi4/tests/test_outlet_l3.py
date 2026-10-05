"""콘센트 모듈 → RPi4: L3 real 배선·비상정지 정지 경로·잔여 전류 꼬리. **가짜 출력 수준**(실물 미검증).

가짜 출력(`rpi/tools/fake_outlet.py`)은 합성 전력이다. 그래서 ``OutletLink(mock=True)``인 시험은 판정이
모의로 표시되는지까지 본다. ``mock=False`` 링크에 가짜 출력을 물린 시험은 "실기기 포트였다면 이렇게
배선된다"는 호스트 쪽 경로 확인일 뿐, 실물 근거가 아니다.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from rpi.controller import ClosedLoopController, ExecutionStatus, VerificationLayer
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.power_operation import (
    REAL_L3_NOT_WIRED,
    OutletOperationVerifier,
    operation_verifier_from_env,
)
from rpi.tools.fake_outlet import FakeOutlet, open_fake_outlet
from rpi.verifier import MockVerifier
from rpi.verifier.outlet import OutletConfig, OutletLink
from rpi.verifier.power import PowerConfig
from rpi.verifier.power_tail import TailConfig
from rpi4 import act_main
from rpi4.services.act_executor import ActExecutor
from rpi4.services.outlet_watch import OutletRunProbe, OutletTailHook

FAST = dict(sleep=lambda _s: None, max_polls=2000)
BUTTONS = ["즉석밥", "시작"]


def _link(*, mock: bool = True, relay_on: bool = True, **cfg) -> tuple[OutletLink, FakeOutlet]:
    pipe, fake = open_fake_outlet(speed=50.0, relay_on=relay_on)
    link = OutletLink(pipe.host, OutletConfig(heartbeat_s=None, **cfg), mock=mock).start()
    return link, fake


def _controller(operation, grbl=None) -> ClosedLoopController:
    return ClosedLoopController(grbl or MockGrblClient(), MockVerifier([True] * 20), MockAlertSink(),
                                MockSafetyController(), operation=operation)


class FakeWriter:
    def __init__(self) -> None:
        self.buf = b""

    def write(self, data: bytes) -> None:
        self.buf += data

    async def drain(self) -> None:
        pass

    def docs(self) -> list[dict]:
        return [json.loads(line) for line in self.buf.split(b"\n") if line.strip()]


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


# ── SIMPLELAY_L3_MODE=real 배선 ──────────────────────────────────────────────


def test_real_l3_still_refuses_without_outlet_port():
    with pytest.raises(RuntimeError, match="SIMPLELAY_OUTLET_PORT"):
        operation_verifier_from_env({"SIMPLELAY_L3_MODE": "real"})
    with pytest.raises(RuntimeError, match="아직 없습니다"):
        operation_verifier_from_env({"SIMPLELAY_L3_MODE": "real", "SIMPLELAY_OUTLET_PORT": "  "})


def test_real_l3_with_port_but_no_link_is_refused():
    with pytest.raises(RuntimeError) as exc:
        operation_verifier_from_env({"SIMPLELAY_L3_MODE": "real", "SIMPLELAY_OUTLET_PORT": "/dev/ttyUSB1"})
    assert str(exc.value) == REAL_L3_NOT_WIRED


def test_real_l3_with_outlet_builds_outlet_verifier():
    link, fake = _link()
    try:
        verifier = operation_verifier_from_env(
            {"SIMPLELAY_L3_MODE": "real", "SIMPLELAY_OUTLET_PORT": "fake"}, outlet=link)
        assert isinstance(verifier, OutletOperationVerifier) and verifier.mock
    finally:
        link.close()
        fake.close()


def test_l3_real_with_fake_outlet_confirms_and_is_marked_mock():
    link, fake = _link()
    try:
        verifier = OutletOperationVerifier(link, on_sequence_done=lambda: fake.start_run(run_s=5.0), **FAST)
        result = _controller(verifier).execute(BUTTONS)
        assert result.status is ExecutionStatus.SUCCEEDED
        assert result.operation.passed is True
        assert result.operation.mock is True  # 가짜 출력 — 실제 동작 근거로 올리지 않는다
        assert result.operation.detail.startswith("모의 콘센트")
        assert verifier.last_verdict is not None
        assert verifier.last_verdict.baseline_w == pytest.approx(3.0)  # 가짜 대기 전력
    finally:
        link.close()
        fake.close()


def test_l3_real_link_without_rise_is_unconfirmed_safety_stop():
    """실기기처럼 배선된 링크(mock=False) — 전력이 오르지 않으면 안전 정지."""
    link, fake = _link(mock=False)
    try:
        verifier = OutletOperationVerifier(link, **FAST)  # 가전이 돌지 않는다
        result = _controller(verifier).execute(BUTTONS)
        assert result.status is not ExecutionStatus.SUCCEEDED
        assert result.failed_layer is VerificationLayer.OPERATION
        assert result.operation.passed is False and result.operation.mock is False
        assert "시작 전력 상승이 확인되지 않음" in result.operation.detail
    finally:
        link.close()
        fake.close()


def test_l3_real_link_rise_is_real_source():
    link, fake = _link(mock=False)
    try:
        verifier = OutletOperationVerifier(link, on_sequence_done=lambda: fake.start_run(run_s=5.0), **FAST)
        result = _controller(verifier).execute(BUTTONS)
        assert result.operation.passed is True and result.operation.mock is False
    finally:
        link.close()
        fake.close()


def test_l3_relay_off_is_unconfirmed_not_faked():
    """릴레이가 꺼져 있으면(부팅 기본) 가전이 돌 수 없다 — 확인 못 함으로 끝난다."""
    link, fake = _link(relay_on=False)
    try:
        verifier = OutletOperationVerifier(link, on_sequence_done=lambda: fake.start_run(run_s=5.0), **FAST)
        result = _controller(verifier).execute(BUTTONS)
        assert result.operation.passed is False
    finally:
        link.close()
        fake.close()


def test_l3_stale_stream_stops_as_unreadable_sensor():
    link, fake = _link(stale_s=0.2)
    try:
        verifier = OutletOperationVerifier(link, **FAST)
        deadline = time.monotonic() + 1.0
        while link.latest() is None:  # 한 번은 받은 뒤 끊긴다(처음부터 없는 경우는 프로토콜 시험이 본다)
            assert time.monotonic() < deadline
            time.sleep(0.005)
        fake.emit_power = False
        safety = MockSafetyController()
        controller = ClosedLoopController(MockGrblClient(), MockVerifier([True] * 20), MockAlertSink(),
                                          safety, operation=verifier)
        result = controller.execute(BUTTONS)
        assert result.failed_layer is VerificationLayer.OPERATION
        assert result.operation is None  # 판정 불가 — 0 W로 '확인 못 함'을 지어내지 않는다
        assert any("power sensor unavailable" in r and "끊김" in r for r in safety.reasons), safety.reasons
    finally:
        link.close()
        fake.close()


# ── 물리 비상정지 → 실행기 정지 경로 ──────────────────────────────────────────


def test_outlet_estop_event_stops_the_running_sequence_and_alerts():
    async def _t():
        class SlowGrbl:
            def __init__(self):
                self.pressed = []
                self.stops = 0

            def press(self, command):
                time.sleep(0.05)
                self.pressed.append(command.button)

            def request_stop(self):
                self.stops += 1

        link, fake = _link()
        try:
            grbl = SlowGrbl()
            controller = ClosedLoopController(grbl, MockVerifier([True] * 10), MockAlertSink(),
                                              MockSafetyController())
            reader = asyncio.StreamReader()
            writer = FakeWriter()
            executor = ActExecutor(reader=reader, writer=writer, controller=controller, progress=False)
            act_main._wire_outlet_estop(link, executor)
            _feed(reader, {"type": "execute", "sequence_id": "seq-estop",
                           "buttons": ["b1", "b2", "b3", "b4", "b5"]})
            await executor.run_once()
            await asyncio.sleep(0.08)
            fake.press_estop()  # 모듈이 스스로 릴레이를 열고 이벤트를 보낸다
            await executor.wait_idle()
            docs = writer.docs()
            alert = next(d for d in docs if d.get("type") == "alert")
            assert alert["kind"] == "outlet_estop" and alert["source"] == "button"
            result = next(d for d in docs if d.get("type") == "result")
            assert result["outcome"] == "stopped"
            assert len(grbl.pressed) < 5 and grbl.stops >= 1  # 모션 정지 명령도 즉시 나갔다
            assert executor.outlet_estops == 1
            assert fake.relay_on is False
        finally:
            link.close()
            fake.close()

    asyncio.run(_t())


def test_outlet_estop_while_idle_only_alerts():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = ActExecutor(reader=reader, writer=writer, controller=_controller(None), progress=False)
        executor.handle_outlet_estop("button")
        await asyncio.sleep(0)
        (doc,) = writer.docs()
        assert doc["type"] == "alert" and doc["kind"] == "outlet_estop"

    asyncio.run(_t())


# ── 잔여 전류 꼬리 ───────────────────────────────────────────────────────────


def test_tail_progress_frame_after_confirmed_result():
    async def _t():
        link, fake = _link()
        try:
            verifier = OutletOperationVerifier(
                link, on_sequence_done=lambda: fake.start_run(run_s=3.0, run_w=1200.0, tail_s=5.0, tail_w=12.0),
                **FAST)
            rows: list[tuple[dict, str]] = []

            class Rec:
                def record_power_tail(self, metrics, note=""):
                    rows.append((metrics, note))

            hook = OutletTailHook(link, verifier, recorder=Rec(),
                                  config=TailConfig(settle_s=1.0, max_wait_s=10.0))
            reader = asyncio.StreamReader()
            writer = FakeWriter()
            executor = ActExecutor(reader=reader, writer=writer, controller=_controller(verifier),
                                   progress=False, after_result=hook)
            _feed(reader, {"type": "execute", "sequence_id": "seq-tail", "buttons": BUTTONS})
            await executor.run_once()
            await executor.wait_idle()
            assert await asyncio.to_thread(hook.watch.join, 5.0)
            await asyncio.sleep(0.05)  # call_soon_threadsafe로 넘긴 프레임 쓰기
            frames = [d for d in writer.docs() if d.get("phase") == "power_tail"]
            assert len(frames) == 1
            tail = frames[0]["power_tail"]
            assert frames[0]["sequence_id"] == "seq-tail" and frames[0]["operation_source"] == "mock"
            assert tail["status"] == "returned" and tail["source"] == "mock"
            assert tail["pre_baseline_w"] == pytest.approx(3.0)
            assert tail["post_baseline_w"] == pytest.approx(3.0)
            assert tail["tail_mean_w"] == pytest.approx(12.0) and tail["tail_max_w"] == pytest.approx(12.0)
            # 12W 잔여 5초: 앞 2초는 완료 판정(30W 이하 2초 유지)에 들고, 나머지 3초가 꼬리다
            assert tail["tail_s"] == pytest.approx(3.0, abs=0.15)
            assert rows and rows[0][1] == "sequence_id=seq-tail"
        finally:
            link.close()
            fake.close()

    asyncio.run(_t())


def test_no_tail_watch_when_l3_not_confirmed():
    link, fake = _link()
    try:
        verifier = OutletOperationVerifier(link, **FAST)
        hook = OutletTailHook(link, verifier)

        class R:
            operation = None

        hook("s", R(), lambda doc: None)
        assert hook.watch is None
    finally:
        link.close()
        fake.close()


def test_run_probe_needs_sustained_off():
    link, fake = _link()
    try:
        probe = OutletRunProbe(link, TailConfig(off_confirm_s=1.0))
        fake.start_run(run_s=1.0, run_w=800.0, tail_s=0.0)
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline and not (link.latest() and link.latest().watts > 100):
            time.sleep(0.005)
        assert probe.running() is True
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and probe.running() is not False:
            time.sleep(0.005)
        assert probe.running() is False
        assert probe.source == "mock"
        fake.emit_power = False
        time.sleep(link.config.stale_s + 0.1)
        assert probe.running() is None  # 끊기면 모름
    finally:
        link.close()
        fake.close()


# ── act_main ────────────────────────────────────────────────────────────────


def test_act_main_outlet_env(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_OUTLET_PORT", raising=False)
    assert act_main._build_outlet() is None
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "/dev/ttyUSB9")
    monkeypatch.delenv("SIMPLELAY_OUTLET_BAUD", raising=False)
    with pytest.raises(RuntimeError, match="SIMPLELAY_OUTLET_BAUD"):
        act_main._build_outlet()
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "fake")
    monkeypatch.setenv("SIMPLELAY_OUTLET_RELAY_ON_START", "1")
    link = act_main._build_outlet()
    try:
        assert link.mock is True
        assert link.status()["relay"] == "on"
    finally:
        link.close()
        act_main._fake_outlet.close()


def test_act_main_real_l3_refuses_without_port_and_wires_with_fake(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_L3_MODE", "real")
    monkeypatch.delenv("SIMPLELAY_OUTLET_PORT", raising=False)
    monkeypatch.delenv("SIMPLELAY_MOTION_MODE", raising=False)
    with pytest.raises(RuntimeError, match="SIMPLELAY_OUTLET_PORT"):
        act_main._build_executor(object(), object())  # type: ignore[arg-type]
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "fake")
    link = act_main._build_outlet()
    try:
        executor = act_main._build_executor(object(), object(), outlet=link)  # type: ignore[arg-type]
        assert isinstance(executor._controller._operation, OutletOperationVerifier)  # noqa: SLF001
        assert isinstance(executor._after_result, OutletTailHook)  # noqa: SLF001
    finally:
        link.close()
        act_main._fake_outlet.close()


# ── RPi5 ActClient까지(메모리 링크) ──────────────────────────────────────────


class _PipeWriter:
    def __init__(self, peer):
        self._peer = peer

    def write(self, data):
        self._peer.feed_data(data)

    async def drain(self):
        pass


def test_rpi5_client_keeps_last_power_tail_and_gets_estop_alert():
    from rpi.services.act_client import ActClient

    async def _t():
        link, fake = _link()
        try:
            verifier = OutletOperationVerifier(
                link, on_sequence_done=lambda: fake.start_run(run_s=2.0, tail_s=4.0, tail_w=12.0), **FAST)
            hook = OutletTailHook(link, verifier, config=TailConfig(settle_s=1.0, max_wait_s=10.0))
            a_reader, h_reader = asyncio.StreamReader(), asyncio.StreamReader()
            executor = ActExecutor(a_reader, _PipeWriter(h_reader), _controller(verifier), progress=False,
                                   after_result=hook)
            alerts = []
            client = ActClient(h_reader, _PipeWriter(a_reader), on_alert=alerts.append)
            await client.start()
            task = asyncio.create_task(executor.run())
            act_main._wire_outlet_estop(link, executor)
            result = await client.execute(BUTTONS)
            assert result.success and result.operation_confirmed is True
            assert result.operation_source == "mock"  # 가짜 출력 — 실물 근거 아님
            loop = asyncio.get_running_loop()
            end = loop.time() + 5.0
            while client.last_power_tail is None:
                assert loop.time() < end
                await asyncio.sleep(0.01)
            assert client.last_power_tail["power_tail"]["status"] == "returned"
            fake.press_estop()
            end = loop.time() + 2.0
            while not alerts:
                assert loop.time() < end
                await asyncio.sleep(0.01)
            assert alerts[0].kind == "outlet_estop" and alerts[0].raised
            await executor.shutdown()
            task.cancel()
            await client.stop()
        finally:
            link.close()
            fake.close()

    asyncio.run(_t())
