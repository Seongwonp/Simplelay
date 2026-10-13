"""사건 신선도 기준점(3차 평가 M1, 2026-10-14) — 실제 ActClient(RPi5) ↔ ActExecutor(RPi4) 선 위에서.

RPi4는 ``act_info.clock_protocol``을 알리고, RPi5는 ``clock_probe``를 보내 ``clock_ref``(RPi4 단조 시각·시계 식별자)를 받는다.
RPi5는 그 기준점으로만 RPi4 프레임의 끝 시각을 자기 시계로 옮긴다(서로 다른 장치의 monotonic을 그대로 비교하지 않음).
이 시험은 한 프로세스 안이라 두 시계가 실제로는 같다 — 그래서 옮긴 값이 실제 끝 시각보다 **늦지 않음**(보수적)과
왕복 시간 안의 차이만 본다. 실제 두 보드 사이의 지연·드리프트를 잰 것이 아니다.
"""

from __future__ import annotations

import asyncio

import pytest

from rpi.services.event_clock import get_event_clock, reset_event_clock
from rpi4.tests.test_link_auth import KEY, _Link, _ready, _until, fast_auth  # noqa: F401

RPI4_CLOCK = "rpi4sideclock001"


@pytest.fixture(autouse=True)
def _fresh_event_clock():
    reset_event_clock()
    yield
    reset_event_clock()


@pytest.fixture
def rpi4_clock(monkeypatch):
    """RPi4 쪽 프로세스 시계 식별자를 RPi5와 다르게(실제로는 다른 보드)."""
    from rpi.verifier import done_fusion
    from rpi4.services import act_executor

    monkeypatch.setattr(done_fusion, "CLOCK_ID", RPI4_CLOCK)
    monkeypatch.setattr(act_executor, "CLOCK_ID", RPI4_CLOCK)


@pytest.mark.parametrize("key", [None, KEY])
def test_link_session_gets_a_clock_reference_and_maps_rpi4_frames_conservatively(rpi4_clock, fast_auth, key):
    async def _t():
        received: list[dict] = []
        link = _Link(key, key)
        link.client._on_appliance_done = received.append
        await link.start()
        try:
            await _ready(link)
            await _until(lambda: get_event_clock().link_clock_id() == RPI4_CLOCK)
            assert any(d["type"] == "clock_probe" for d in link.to_act.docs())
            ref = next(d for d in link.to_hub.docs() if d["type"] == "clock_ref")
            assert ref["clock_id"] == RPI4_CLOCK and isinstance(ref["t_monotonic_ns"], int)
            frame = link.executor.inject_appliance_done("microwave", ["power"])
            assert frame["clock_id"] == RPI4_CLOCK
            await _until(lambda: received)
            end = get_event_clock().end_local_s(received[0])
            assert end is not None
            # 같은 프로세스라 실제 끝(허브 시계) = at_s. 옮긴 값은 그보다 늦지 않고 왕복 시간 안에서만 이르다.
            assert end <= received[0]["at_s"] + 1e-6
            assert received[0]["at_s"] - end < 0.5
        finally:
            await link.close()

    asyncio.run(_t())


def test_old_rpi4_without_clock_protocol_gets_no_probe_and_no_reference(rpi4_clock, monkeypatch, fast_auth):
    from rpi4.services import act_executor

    monkeypatch.setattr(act_executor, "CLOCK_PROTOCOL", 0)

    async def _t():
        received: list[dict] = []
        link = _Link(None, None)
        link.client._on_appliance_done = received.append
        await link.start()
        try:
            await _ready(link)
            await asyncio.sleep(0.05)
            assert not any(d["type"] == "clock_probe" for d in link.to_act.docs())
            link.executor.inject_appliance_done("microwave", ["power"])
            await _until(lambda: received)
            assert get_event_clock().end_local_s(received[0]) is None  # 근거 없음 → 자동 실행 보류
        finally:
            await link.close()

    asyncio.run(_t())


def test_link_down_drops_the_reference(rpi4_clock, fast_auth):
    async def _t():
        link = _Link(None, None)
        await link.start()
        try:
            await _ready(link)
            await _until(lambda: get_event_clock().link_clock_id() == RPI4_CLOCK)
            link.client._mark_link_down("test: cable pulled")
            assert get_event_clock().link_clock_id() is None
            assert get_event_clock().end_local_s({"clock_id": RPI4_CLOCK, "at_s": 1.0}) is None
        finally:
            await link.close()

    asyncio.run(_t())


def test_clock_ref_for_a_probe_we_did_not_send_is_ignored():
    clock = get_event_clock()
    assert not clock.on_clock_ref({"probe": "never-sent", "clock_id": RPI4_CLOCK, "t_monotonic_ns": 5})
    assert clock.link_clock_id() is None


def test_a_long_lived_link_reprobes_the_clock_periodically(rpi4_clock, fast_auth, monkeypatch):
    """4차 평가 M-N1: 기준점은 유효 기간이 있어 오래 유지한 연결은 주기적으로 다시 탐침한다
    (``SIMPLELAY_EVENT_CLOCK_REFRESH_S``, 기본 60초 — 시험은 0.05초). 끊기면 다시 탐침하지 않는다."""
    monkeypatch.setenv("SIMPLELAY_EVENT_CLOCK_REFRESH_S", "0.05")

    async def _t():
        link = _Link(None, None)
        await link.start()
        try:
            await _ready(link)
            await _until(lambda: sum(d["type"] == "clock_ref" for d in link.to_hub.docs()) >= 3)
            assert get_event_clock().link_clock_id() == RPI4_CLOCK
            link.client._mark_link_down("test: cable pulled")
            sent = sum(d["type"] == "clock_probe" for d in link.to_act.docs())
            await asyncio.sleep(0.2)
            assert sum(d["type"] == "clock_probe" for d in link.to_act.docs()) == sent
        finally:
            await link.close()

    asyncio.run(_t())
