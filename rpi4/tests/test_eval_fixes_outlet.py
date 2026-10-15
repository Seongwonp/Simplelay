"""2026-10-06 평가 수리 — 콘센트 채널 대응·릴레이 채널·모듈 재부팅(A1·A2·A4).

가짜 콘센트 모듈(합성 전력)로만 시험한다. 실물 CT·릴레이 미검증, 기준값 전부 측정 필요.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from rpi4 import act_main
from rpi4.services.act_executor import ActExecutor
from rpi4.tests.test_act_executor import FakeWriter
from rpi4.tests.test_appliance_done_watch import _controller


@pytest.fixture
def fake_env(monkeypatch):
    for name in ("SIMPLELAY_OUTLET_CHANNELS", "SIMPLELAY_DONE_WATCH", "SIMPLELAY_L3_MODE",
                 "SIMPLELAY_MOTION_MODE", "SIMPLELAY_OUTLET_RELAY_ON_START", "SIMPLELAY_RECORDER_PATH",
                 "SIMPLELAY_FAKE_OUTLET_RELAY_CH", "SIMPLELAY_FAKE_OUTLET_CHANNELS"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "fake")
    monkeypatch.setenv("SIMPLELAY_OUTLET_HEARTBEAT_MS", "off")
    monkeypatch.setenv("SIMPLELAY_OUTLET_STATUS_POLL_MS", "off")
    yield monkeypatch
    if act_main._fake_outlet is not None:  # noqa: SLF001
        act_main._fake_outlet.close()  # noqa: SLF001
        act_main._fake_outlet = None  # noqa: SLF001


# ── A1: 대응이 비었는데 두 가전이 콘센트 전력을 읽으면 기동 거절 ─────────────────────

def test_empty_mapping_with_two_done_watch_appliances_refuses_start(fake_env):
    """대응이 비면 모두 채널 0 — 전자레인지 끝이 세탁 끝(wash_complete)으로 잡힌다. 경고가 아니라 거절."""
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet;microwave:outlet")
    with pytest.raises(RuntimeError, match="SIMPLELAY_OUTLET_CHANNELS"):
        act_main._build_outlet()


def test_empty_mapping_with_l3_and_washer_watch_refuses_start(fake_env):
    fake_env.setenv("SIMPLELAY_L3_MODE", "real")
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet")
    with pytest.raises(RuntimeError, match="SIMPLELAY_OUTLET_CHANNELS"):
        act_main._build_outlet()


def test_empty_mapping_with_a_single_consumer_still_starts(fake_env):
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet")
    link = act_main._build_outlet()
    link.close()


# ── A2: 릴레이 채널 ≠ 전자레인지 채널, 모듈에 없는 채널이면 기동 거절 ─────────────

def test_fake_relay_channel_is_not_derived_from_the_mapping(fake_env):
    """가짜 모듈은 펌웨어 기본처럼 릴레이 채널 0이다 — 대응에서 베끼면 어긋남을 시험이 못 잡는다."""
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "washer:0,microwave:1")
    fake_env.setenv("SIMPLELAY_L3_MODE", "real")
    with pytest.raises(RuntimeError, match="릴레이"):
        act_main._build_outlet()


def test_relay_channel_matching_the_microwave_channel_starts(fake_env):
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "washer:0,microwave:1")
    fake_env.setenv("SIMPLELAY_FAKE_OUTLET_RELAY_CH", "1")
    fake_env.setenv("SIMPLELAY_L3_MODE", "real")
    link = act_main._build_outlet()
    try:
        assert act_main._fake_outlet.relay_channel == 1  # noqa: SLF001
    finally:
        link.close()


def test_mapped_channel_missing_on_the_module_refuses_start(fake_env):
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "microwave:0,washer:1")
    fake_env.setenv("SIMPLELAY_FAKE_OUTLET_CHANNELS", "1")
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet")
    with pytest.raises(RuntimeError, match="채널"):
        act_main._build_outlet()


# ── A4: 모듈 재부팅으로 릴레이가 꺼지면 조용히 넘어가지 않는다(자동으로 켜지 않는다) ─────

async def _wait_for(predicate, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.02)


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc) + "\n").encode())


def test_module_reboot_with_relay_expected_on_latches_until_human_ack(fake_env):
    fake_env.setenv("SIMPLELAY_OUTLET_RELAY_ON_START", "1")

    async def _t():
        link = act_main._build_outlet()
        fake = act_main._fake_outlet  # noqa: SLF001
        try:
            assert fake.relay_on is True
            reader, writer = asyncio.StreamReader(), FakeWriter()
            executor = ActExecutor(reader, writer, _controller())
            act_main._wire_outlet_estop(link, executor)
            fake.reboot()  # 전원 순간 끊김·USB 재열거 — 모듈 부팅 기본 = 릴레이 꺼짐
            await _wait_for(lambda: executor.estop_latched)
            assert fake.relay_on is False  # 자동으로 다시 켜지 않는다
            states = [m for m in writer.messages() if m.get("type") == "estop_state"]
            assert states and "다시 켜져" in states[-1]["detail"]
            # 실행 거절 — 이유가 화면에 그대로 보인다
            _feed(reader, {"type": "execute", "appliance_id": "microwave", "sequence_id": "s1", "buttons": ["시작"]})
            await executor.run_once()
            refused = [m for m in writer.messages() if m.get("type") == "error"]
            assert refused and refused[-1]["reason"] == "estop_latched"
            assert "다시 켜져" in refused[-1]["detail"]
            # 사람의 확인(POST /stop/ack → estop_ack) 뒤에만 켠다
            writer.clear()
            _feed(reader, {"type": "estop_ack"})
            await executor.run_once()
            await executor.wait_ack()
            assert executor.estop_latched is False
            assert fake.relay_on is True
        finally:
            link.close()

    asyncio.run(_t())


def test_module_reboot_without_relay_expected_on_is_not_a_latch(fake_env):
    """릴레이를 켠 적이 없으면(기본) 재부팅해도 바뀐 것이 없다 — 걸지 않는다."""

    async def _t():
        link = act_main._build_outlet()
        fake = act_main._fake_outlet  # noqa: SLF001
        try:
            executor = ActExecutor(asyncio.StreamReader(), FakeWriter(), _controller())
            act_main._wire_outlet_estop(link, executor)
            fake.reboot()
            await asyncio.sleep(0.3)
            assert executor.estop_latched is False
        finally:
            link.close()

    asyncio.run(_t())


# ── B11(10/15 계획 §5): 재부팅 걸림 뒤 비상 버튼이 이어져도 해제 확인이 릴레이를 켜지 않는다 ──────────

async def _ack(reader: asyncio.StreamReader, executor: ActExecutor) -> None:
    _feed(reader, {"type": "estop_ack"})
    await executor.run_once()
    await executor.wait_ack()


def test_button_estop_after_reboot_latch_keeps_relay_off_after_ack(fake_env):
    """재부팅 걸림(``power_lost``) 위에 비상 버튼(estop 이벤트)이 눌리면 비상 버튼 규칙이 이긴다 —
    풀고 해제해도 콘센트 전원은 꺼진 채다(비상 버튼으로 꺼진 전원은 다시 켜지 않는다)."""
    fake_env.setenv("SIMPLELAY_OUTLET_RELAY_ON_START", "1")

    async def _t():
        link = act_main._build_outlet()
        fake = act_main._fake_outlet  # noqa: SLF001
        try:
            reader, writer = asyncio.StreamReader(), FakeWriter()
            executor = ActExecutor(reader, writer, _controller())
            act_main._wire_outlet_estop(link, executor)
            fake.reboot()
            await _wait_for(lambda: executor.estop_latched)
            assert executor.estop_source == "outlet_reboot" and link.power_lost is True

            fake.press_estop()
            await _wait_for(lambda: executor.estop_source == "button")
            fake.release_estop_button()
            await _ack(reader, executor)
            assert executor.estop_latched is False
            await asyncio.sleep(0.2)
            assert fake.relay_on is False  # 비상 버튼으로 꺼진 전원 — 해제 확인이 켜지 않는다
            assert link.power_lost is False
        finally:
            link.close()

    asyncio.run(_t())


def test_status_reported_estop_after_reboot_latch_keeps_relay_off_after_ack(fake_env):
    """estop 이벤트 줄을 잃고 주기 status로만 걸림을 안 경우도 같다 — 화면 문장도 '다시 켜져'(재부팅)로
    남지 않고 비상 버튼 걸림으로 바뀐다."""
    fake_env.setenv("SIMPLELAY_OUTLET_RELAY_ON_START", "1")

    async def _t():
        link = act_main._build_outlet()
        fake = act_main._fake_outlet  # noqa: SLF001
        try:
            reader, writer = asyncio.StreamReader(), FakeWriter()
            executor = ActExecutor(reader, writer, _controller())
            act_main._wire_outlet_estop(link, executor)
            fake.reboot()
            await _wait_for(lambda: executor.estop_latched)
            assert link.power_lost is True

            fake.latch_silently()
            await asyncio.to_thread(link.status)  # 주기 조회 한 번(시험에서는 주기 조회를 껐다)
            await _wait_for(lambda: executor.estop_source == "status")
            states = [m for m in writer.messages() if m.get("type") == "estop_state"]
            assert states and "다시 켜져" not in states[-1]["detail"]

            await _ack(reader, executor)
            assert executor.estop_latched is False
            await asyncio.sleep(0.2)
            assert fake.relay_on is False
            assert link.power_lost is False
        finally:
            link.close()

    asyncio.run(_t())


def test_reboot_latch_alone_still_restores_power_after_ack(fake_env):
    """B11 수리가 재부팅 걸림만 있는 경우(A4)를 바꾸지 않는다 — 해제 확인 뒤 다시 켠다."""
    fake_env.setenv("SIMPLELAY_OUTLET_RELAY_ON_START", "1")

    async def _t():
        link = act_main._build_outlet()
        fake = act_main._fake_outlet  # noqa: SLF001
        try:
            reader, writer = asyncio.StreamReader(), FakeWriter()
            executor = ActExecutor(reader, writer, _controller())
            act_main._wire_outlet_estop(link, executor)
            fake.reboot()
            await _wait_for(lambda: executor.estop_latched)
            await asyncio.to_thread(link.status)  # 걸림 없는 status — 재부팅 걸림을 덮지 않는다
            await asyncio.sleep(0.1)
            assert executor.estop_source == "outlet_reboot"
            await _ack(reader, executor)
            assert executor.estop_latched is False
            assert fake.relay_on is True
        finally:
            link.close()

    asyncio.run(_t())


# ── C2: 해제 확인이 모듈 응답을 기다리는 동안에도 abort를 처리한다 ─────────────────

class _HoldStub:
    active = True

    def __init__(self) -> None:
        self.drive_stops = 0

    def drive_stop(self) -> None:
        self.drive_stops += 1

    def request_appliance_stop(self) -> str:
        return "stub"


def test_abort_is_processed_while_estop_ack_waits_for_the_outlet():
    import threading

    async def _t():
        reader, writer = asyncio.StreamReader(), FakeWriter()
        executor = ActExecutor(reader, writer, _controller())
        release = threading.Event()

        def slow_reset():
            release.wait(5.0)  # 모듈 응답 기한만큼 걸리는 status·estop_reset 흉내
            return True, None

        executor.set_estop_reset(slow_reset)
        executor.handle_outlet_estop("button")
        hold = _HoldStub()
        executor.hold_session = hold  # type: ignore[assignment]
        _feed(reader, {"type": "estop_ack"})
        await asyncio.wait_for(executor.run_once(), 0.5)  # 읽기 루프가 막히지 않는다
        _feed(reader, {"type": "abort", "scope": "drive"})
        await asyncio.wait_for(executor.run_once(), 0.5)
        assert hold.drive_stops == 1  # 해제 확인을 기다리는 사이에도 구동부 정지가 처리됐다
        release.set()
        await executor.wait_ack()
        assert executor.estop_latched is False

    asyncio.run(_t())


# ── Copilot#2: 루프가 닫힌 뒤 온 비상정지도 구동부를 멈춘다 ──────────────────────────

class _ListenerOutlet:
    module_estop = None

    def __init__(self) -> None:
        self.listeners = []

    def add_listener(self, fn) -> None:
        self.listeners.append(fn)

    def reset_estop_if_released(self):
        return True, None

    def not_ready_reason(self):
        return None


class _StopCounter:
    def __init__(self) -> None:
        self.stops = 0

    def request_stop(self) -> None:
        self.stops += 1


def test_estop_after_the_event_loop_closed_still_stops_the_drive_synchronously():
    outlet = _ListenerOutlet()
    controller = _StopCounter()
    holder = {}

    async def _wire():
        executor = ActExecutor(asyncio.StreamReader(), FakeWriter(), controller)  # type: ignore[arg-type]
        act_main._wire_outlet_estop(outlet, executor)
        holder["executor"] = executor

    asyncio.run(_wire())  # 여기서 루프가 닫힌다
    executor = holder["executor"]
    outlet.listeners[0]({"event": "estop", "source": "button"})  # 읽기 스레드가 늦게 받은 버튼
    assert controller.stops == 1
    assert executor.estop_latched is True


# ── C1·B3: 연결 알림 — RPi4가 켜질 때·hello를 받을 때 구성과 걸림 상태를 알린다 ──────────

def test_hello_is_answered_with_act_info_and_estop_state(fake_env):
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "microwave:0,washer:1")
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet,mic;microwave:outlet")

    async def _t():
        reader, writer = asyncio.StreamReader(), FakeWriter()
        executor = ActExecutor(reader, writer, _controller())
        act_main._describe_act(executor, outlet_kind="fake", motion_kind="mock")
        _feed(reader, {"type": "hello"})
        await executor.run_once()
        docs = writer.messages()
        info = next(d for d in docs if d["type"] == "act_info")
        assert info["done_watch"] == ["washer", "microwave"]
        assert info["outlet"] == "fake" and info["motion"] == "mock"
        assert info["rehearsal"] is True
        state = next(d for d in docs if d["type"] == "estop_state")
        assert state["latched"] is False

    asyncio.run(_t())


def test_rehearsal_is_refused_when_real_hardware_is_attached(fake_env):
    async def _t():
        reader, writer = asyncio.StreamReader(), FakeWriter()
        executor = ActExecutor(reader, writer, _controller())
        act_main._describe_act(executor, outlet_kind="real", motion_kind="mock")
        _feed(reader, {"type": "rehearsal", "action": "appliance_done", "request_id": "r1",
                       "appliance_id": "washer", "inputs": ["power", "beep"]})
        await executor.run_once()
        reply = next(d for d in writer.messages() if d["type"] == "rehearsal_result")
        assert reply["ok"] is False and reply["reason"] == "rehearsal_refused"
        assert not [d for d in writer.messages() if d["type"] == "appliance_done"]

    asyncio.run(_t())


def test_rehearsal_on_fake_outlet_injects_done_and_presses_the_fake_button(fake_env):
    async def _t():
        link = act_main._build_outlet()
        fake = act_main._fake_outlet  # noqa: SLF001
        try:
            reader, writer = asyncio.StreamReader(), FakeWriter()
            executor = ActExecutor(reader, writer, _controller())
            act_main._wire_outlet_estop(link, executor)
            act_main._describe_act(executor, outlet_kind="fake", motion_kind="mock")
            _feed(reader, {"type": "rehearsal", "action": "appliance_done", "request_id": "r1",
                           "appliance_id": "washer", "inputs": ["power"]})
            await executor.run_once()
            done = next(d for d in writer.messages() if d["type"] == "appliance_done")
            assert done["source"] == "injected" and done["state"] == "done_power_only"
            _feed(reader, {"type": "rehearsal", "action": "outlet_estop", "request_id": "r2",
                           "hold_button": True})
            await executor.run_once()
            await _wait_for(lambda: executor.estop_latched)  # 가짜 모듈 버튼 → 실물과 같은 estop 이벤트 경로
            assert fake.estop_latched is True and fake.button_active is True
            _feed(reader, {"type": "estop_ack"})
            await executor.run_once()
            await executor.wait_ack()
            assert executor.estop_latched is True  # 버튼이 눌린 채 — 풀지 않는다
            _feed(reader, {"type": "rehearsal", "action": "outlet_estop_release", "request_id": "r3"})
            await executor.run_once()
            _feed(reader, {"type": "estop_ack"})
            await executor.run_once()
            await executor.wait_ack()
            assert executor.estop_latched is False
        finally:
            link.close()

    asyncio.run(_t())
