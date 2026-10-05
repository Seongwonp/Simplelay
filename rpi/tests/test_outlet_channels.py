"""콘센트 모듈 CT 두 채널(2026-10-06 사용자 결정: 전자레인지·세탁기를 동시에 잰다) — **가짜 출력 수준**.

확인하는 것:
1. power 줄의 ``ch``로 채널을 나눈다. ``ch``가 없으면 채널 0(옛 펌웨어와 호환).
2. 두 채널이 섞여 와도 채널마다 시각·seq·신선도를 따로 센다(한 채널의 줄이 다른 채널을 '순서 뒤바뀜'으로 버리지 않는다).
3. 끊김은 채널마다 — 세탁기 채널이 조용해도 전자레인지 채널은 읽힌다(반대도).
4. 채널 → 가전 대응 ``SIMPLELAY_OUTLET_CHANNELS`` 해석과 잘못된 값 거절.
5. 가짜 모듈의 릴레이는 릴레이 채널(전자레인지)만 끊는다 — 세탁기 채널은 그대로 보인다.
"""

from __future__ import annotations

import time

import pytest

from rpi.controller.serial_motion import InMemoryLinePipe
from rpi.tools.fake_outlet import open_fake_outlet
from rpi.verifier.outlet import (
    OutletChannelMap,
    OutletConfig,
    OutletLink,
    PowerSensorStale,
    parse_outlet_channels,
)


def _link(**fake_kwargs) -> tuple[OutletLink, object]:
    fake_kwargs.setdefault("speed", 50.0)
    pipe, fake = open_fake_outlet(**fake_kwargs)
    link = OutletLink(pipe.host, OutletConfig(heartbeat_s=None, status_poll_s=None), mock=True).start()
    return link, fake


def _power(ch, t_ms, seq, watts):
    doc = {"event": "power", "t_ms": t_ms, "seq": seq, "watts": watts, "n": 40, "err": 0}
    if ch is not None:
        doc["ch"] = ch
    return doc


def test_interleaved_channels_keep_their_own_time_and_seq():
    clock = [10.0]
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None), clock=lambda: clock[0])
    for k in range(5):
        clock[0] += 0.1
        link.handle_doc(_power(0, 1000 + 100 * k, 10 + k, 1200.0))
        link.handle_doc(_power(1, 1000 + 100 * k, 3 + k, 450.0))  # 같은 t_ms, 다른 seq
    assert link.dropped_out_of_order == 0
    mw, washer = link.channel(0), link.channel(1)
    assert [s.watts for s in mw.samples_since(0.0)] == [1200.0] * 5
    assert [s.watts for s in washer.samples_since(0.0)] == [450.0] * 5
    assert mw.latest().watts == 1200.0 and washer.latest().watts == 450.0
    # 채널 안에서는 여전히 중복·순서 뒤바뀜을 버린다
    link.handle_doc(_power(1, 1400, 7, 999.0))
    assert link.dropped_out_of_order == 1 and washer.latest().watts == 450.0


def test_line_without_ch_is_channel_zero_and_bad_ch_is_dropped():
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None))
    link.handle_doc(_power(None, 100, 0, 3.0))
    assert link.latest().watts == 3.0 and link.channel(0).latest().watts == 3.0
    assert link.channel(1).latest() is None
    for bad in (-1, 4, True, "1", 1.0, None):
        doc = _power(0, 200, 1, 5.0)
        doc["ch"] = bad
        link.handle_doc(doc)
    assert link.dropped_power == 6
    assert link.latest().watts == 3.0


def test_sensors_read_each_channel_from_the_fake_module():
    link, fake = _link(channels=2, relay_on=True)
    try:
        fake.set_channel_watts(1, 480.0)
        mw, washer = link.channel(0).sensor(), link.channel(1).sensor()
        a = [mw.read() for _ in range(5)]
        b = [washer.read() for _ in range(5)]
        assert all(s.watts == pytest.approx(3.0) for s in a)
        assert all(s.watts == pytest.approx(480.0) for s in b)
        assert link.channel(1).mock is True and link.channel(1).channel == 1
    finally:
        link.close()
        fake.close()


def test_stale_is_per_channel():
    link, fake = _link(channels=2, relay_on=True)
    try:
        washer = link.channel(1).sensor()
        washer.read()
        fake.muted_channels.add(1)  # 세탁기 CT만 끊김
        time.sleep(0.05)
        mw = link.channel(0).sensor()
        assert mw.read().watts == pytest.approx(3.0)
        with pytest.raises(PowerSensorStale):
            for _ in range(200):  # 묵은 줄을 다 읽은 뒤 끊김이 드러난다
                washer.read()
        assert link.channel(1).is_stale() and not link.channel(0).is_stale()
        assert mw.read().watts == pytest.approx(3.0)  # 전자레인지 채널은 계속 읽힌다
    finally:
        link.close()
        fake.close()


def test_fake_relay_cuts_only_the_relay_channel():
    link, fake = _link(channels=2, relay_on=False)
    try:
        fake.set_channel_watts(1, 300.0)
        mw, washer = link.channel(0).sensor(), link.channel(1).sensor()
        assert mw.read().watts == 0.0  # 릴레이가 열려 전자레인지 전원 없음
        assert washer.read().watts == pytest.approx(300.0)  # 세탁기는 릴레이를 거치지 않는다
        ready = link.wait_ready(1.0)
        assert ready["channels"] == 2 and ready["relay_ch"] == 0
    finally:
        link.close()
        fake.close()


# ── 채널 → 가전 대응 ─────────────────────────────────────────────────────────


def test_parse_outlet_channels():
    assert parse_outlet_channels(None) == OutletChannelMap({})
    assert parse_outlet_channels("  ") == OutletChannelMap({})
    mapping = parse_outlet_channels("microwave:0, washer:1")
    assert mapping.channel_for("microwave") == 0 and mapping.channel_for("washer") == 1
    assert mapping.channels == (0, 1)
    # 대응이 없으면 모든 가전이 채널 0(CT 하나 시절과 같다)
    assert OutletChannelMap({}).channel_for("washer") == 0


@pytest.mark.parametrize("raw", [
    "microwave:0,washer:0",      # 한 CT에 두 가전
    "microwave:0,microwave:1",   # 한 가전에 두 CT
    "microwave:4",               # ADS1115 채널 범위 밖
    "microwave:-1",
    "microwave",                 # 형식
    "micro wave:0",
    "washer:x",
    "washer:1;microwave:0",
])
def test_parse_outlet_channels_rejects_bad_values(raw):
    with pytest.raises(RuntimeError):
        parse_outlet_channels(raw)


def test_channel_for_unmapped_appliance_is_an_error_when_a_map_is_given():
    mapping = parse_outlet_channels("microwave:0")
    with pytest.raises(RuntimeError, match="washer"):
        mapping.channel_for("washer")
