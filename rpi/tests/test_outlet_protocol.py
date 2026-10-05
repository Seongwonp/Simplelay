"""콘센트 모듈 링크 — 규약 대조·해석·끊김·릴레이/비상정지 명령. **가짜 출력 수준**(실물 미검증).

C 코드를 돌리지 않는다. 확인하는 것:
1. `firmware-outlet/protocol_table.json`의 명령·응답 필드·이벤트 = 가짜 출력(`rpi/tools/fake_outlet.py`)의 실제 줄.
2. 표의 명령·오류·이벤트·필드 이름이 펌웨어 소스(`firmware-outlet/src`)에 문자열로 있다.
3. 호스트 `OutletLink`/`SerialPowerSensor`: 해석, 시각 맞춤, 끊김(0 W를 지어내지 않음), 밀림 건너뛰기.
4. 릴레이·비상정지 규칙(부팅 기본 꺼짐, 걸린 동안 relay_on 거절, 버튼이 돌아와야 해제).
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from rpi.controller.serial_motion import InMemoryLinePipe
from rpi.tools.fake_outlet import FakeOutlet, open_fake_outlet
from rpi.verifier.outlet import (
    OutletConfig,
    OutletLink,
    OutletRefused,
    PowerSensorStale,
    parse_outlet_line,
    power_fields,
)

ROOT = Path(__file__).resolve().parents[2]
TABLE = json.loads((ROOT / "firmware-outlet" / "protocol_table.json").read_text(encoding="utf-8"))
FIRMWARE_SRC = "\n".join(
    p.read_text(encoding="utf-8")
    for p in sorted((ROOT / "firmware-outlet" / "src").glob("*.cpp"))
)
CONFIG_H = (ROOT / "firmware-outlet" / "include" / "config.h").read_text(encoding="utf-8")


def _link(fake_kwargs=None, **config) -> tuple[OutletLink, FakeOutlet]:
    pipe, fake = open_fake_outlet(**(fake_kwargs or {"speed": 50.0}))
    link = OutletLink(pipe.host, OutletConfig(heartbeat_s=None, **config), mock=True).start()
    return link, fake


def _close(link: OutletLink, fake: FakeOutlet) -> None:
    link.close()
    fake.close()


# ── 표 ↔ 가짜 출력 ↔ 펌웨어 소스 ─────────────────────────────────────────────


def test_fake_outlet_replies_match_table():
    link, fake = _link()
    try:
        for cmd, spec in TABLE["commands"].items():
            extra = {"hz": 10} if cmd == "rate" else {}
            reply = link.request(cmd, **extra)
            assert sorted(reply) == sorted(spec["reply"]), cmd
            sent = fake.received[-1]
            assert sorted(sent) == sorted(spec["request"]), cmd
        link.relay_off()
    finally:
        _close(link, fake)


def test_fake_outlet_events_match_table():
    pipe, fake = open_fake_outlet(speed=50.0, relay_on=True)
    try:
        seen: dict[str, dict] = {}
        fake.press_estop()
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and not {"ready", "power", "estop"} <= set(seen):
            line = pipe.host.read_line(0.1)
            doc = parse_outlet_line(line or "")
            if doc and "event" in doc:
                seen.setdefault(doc["event"], doc)
        for name in ("ready", "power", "estop"):
            assert sorted(seen[name]) == sorted(TABLE["events"][name]), name
        assert seen["ready"]["relay"] == "on"  # 이 시험은 켜진 채로 만들었다
    finally:
        fake.close()
    # ct 실패면 fault만 오고 power는 오지 않는다(0 W를 지어내지 않는다)
    pipe, fake = open_fake_outlet(speed=50.0, ct_ok=False)
    try:
        events = []
        deadline = time.monotonic() + 0.4
        while time.monotonic() < deadline:
            doc = parse_outlet_line(pipe.host.read_line(0.05) or "")
            if doc and "event" in doc:
                events.append(doc)
        assert {"event": "fault", "reason": "ct_init"} in events
        assert sorted(next(e for e in events if e["event"] == "fault")) == sorted(TABLE["events"]["fault"])
        assert not any(e["event"] == "power" for e in events)
    finally:
        fake.close()


def test_firmware_source_mentions_every_table_name():
    names = set(TABLE["commands"]) | set(TABLE["errors"]) | set(TABLE["events"]) | set(TABLE["fault_reasons"])
    for spec in TABLE["commands"].values():
        names |= set(spec["reply"]) | set(spec["request"])
    for fields in TABLE["events"].values():
        names |= set(fields)
    missing = sorted(n for n in names if f'"{n}' not in FIRMWARE_SRC and f'\\"{n}\\"' not in FIRMWARE_SRC)
    assert missing == []
    assert TABLE["protocol"] in CONFIG_H
    assert f"HOST_SERIAL_BAUD       {TABLE['baud']}" in CONFIG_H


def test_firmware_relay_defaults_off_and_estop_does_not_wait_for_host():
    """fail-safe 규칙이 소스에 남아 있는지(실물 확인 전 최소한의 고정)."""
    assert "g_relay_on = false;  // fail-safe" in FIRMWARE_SRC
    assert "outlet_init();  // 릴레이를 가장 먼저" in FIRMWARE_SRC
    # 샘플링 태스크가 매 틱 버튼을 보고 그 자리에서 릴레이를 연다
    assert "outlet_poll_estop(now);" in FIRMWARE_SRC
    assert "#define OUTLET_CONFIG_PLACEHOLDER 1" in CONFIG_H  # 아직 보정 전


# ── 해석 ─────────────────────────────────────────────────────────────────────


def test_parse_ignores_boot_noise_and_bad_power():
    assert parse_outlet_line("ets Jun  8 2016 00:22:57") is None
    assert parse_outlet_line("{broken") is None
    assert parse_outlet_line("[1,2]") is None
    assert power_fields({"event": "power", "t_ms": 100, "watts": 3.2}) == (100, 3.2)
    for bad in ({"t_ms": -1, "watts": 1.0}, {"t_ms": 1, "watts": -0.1}, {"t_ms": 1, "watts": float("nan")},
                {"t_ms": True, "watts": 1.0}, {"t_ms": 1, "watts": "3"}, {"t_ms": 1.5, "watts": 1.0}):
        assert power_fields(bad) is None


def test_bad_power_lines_are_dropped_not_zeroed():
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None))
    link.handle_doc({"event": "power", "t_ms": 100, "watts": -5})
    link.handle_doc({"event": "power", "t_ms": 200, "watts": "lots"})
    assert link.latest() is None and link.dropped_power == 2


def test_time_follows_module_clock_and_reanchors_on_reset():
    clock = [100.0]
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None), clock=lambda: clock[0])
    link.handle_doc({"event": "power", "t_ms": 1000, "watts": 3.0})
    clock[0] = 100.5  # 시리얼 지연으로 늦게 받아도
    link.handle_doc({"event": "power", "t_ms": 1100, "watts": 3.0})
    a, b = link.samples_since(0.0)
    assert b.t_s - a.t_s == pytest.approx(0.1)  # 간격은 모듈 시계를 따른다
    # 모듈 재시작: t_ms가 되돌아가도 호스트 시각은 계속 늘어난다
    clock[0] = 100.6
    link.handle_doc({"event": "power", "t_ms": 50, "watts": 4.0})
    c = link.samples_since(0.0)[-1]
    assert c.t_s > b.t_s


# ── 센서 뷰: 끊김·밀림 ────────────────────────────────────────────────────────


def test_sensor_reads_each_sample_in_order():
    link, fake = _link()
    try:
        fake.relay_on = True
        sensor = link.sensor()
        samples = [sensor.read() for _ in range(15)]
        times = [s.t_s for s in samples]
        assert times == sorted(times) and len(set(times)) == 15
        gaps = [b - a for a, b in zip(times, times[1:])]
        assert max(gaps) == pytest.approx(0.1, abs=1e-6)  # 빠짐 없이 10 Hz 간격
        assert all(s.watts == pytest.approx(3.0) for s in samples)
    finally:
        _close(link, fake)


def test_stale_stream_raises_instead_of_returning_zero():
    link, fake = _link(stale_s=0.15)
    try:
        sensor = link.sensor()
        sensor.read()
        fake.emit_power = False
        t0 = time.monotonic()
        with pytest.raises(PowerSensorStale, match="끊김"):
            for _ in range(1000):
                sensor.read()
        assert time.monotonic() - t0 < 2.0
        assert link.is_stale()
    finally:
        _close(link, fake)


def test_never_received_is_stale_with_clear_reason():
    link, fake = _link({"speed": 50.0, "ct_ok": False}, stale_s=0.1)
    try:
        with pytest.raises(PowerSensorStale, match="한 번도"):
            link.sensor().read()
        assert link.last_fault == {"event": "fault", "reason": "ct_init"}
    finally:
        _close(link, fake)


def test_new_sensor_view_does_not_replay_old_samples():
    link, fake = _link()
    try:
        first = link.sensor()
        first.read()
        time.sleep(0.05)
        latest = link.latest()
        fresh = link.sensor().read()
        assert fresh.t_s > latest.t_s  # 만든 뒤에 온 샘플부터
    finally:
        _close(link, fake)


def test_slow_reader_skips_to_recent_samples():
    clock = [0.0]
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None, max_lag_s=1.0),
                      clock=lambda: clock[0])
    sensor = link.sensor()
    for i in range(50):  # 5초 분량이 한꺼번에 쌓였다
        link.handle_doc({"event": "power", "t_ms": i * 100, "watts": float(i)})
    first = sensor.read()
    assert first.watts == 49.0  # 1초 넘게 밀려 최신으로 건너뜀


# ── 릴레이·비상정지 ──────────────────────────────────────────────────────────


def test_relay_boots_off_and_estop_latches():
    link, fake = _link()
    try:
        assert link.wait_ready(1.0)["relay"] == "off"
        assert link.status()["relay"] == "off"
        link.relay_on()
        assert link.status()["relay"] == "on"
        events: list[dict] = []
        link.add_listener(events.append)
        fake.press_estop()
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline and not link.estop_events:
            time.sleep(0.01)
        assert link.estop_events[0]["source"] == "button"
        assert events and events[0]["event"] == "estop"
        status = link.status()
        assert status["relay"] == "off" and status["estop"] is True
        with pytest.raises(OutletRefused) as exc:
            link.relay_on()
        assert exc.value.code == "estop_latched"
        with pytest.raises(OutletRefused) as exc:
            link.estop_reset()  # 버튼이 아직 눌려 있다
        assert exc.value.code == "estop_active"
        fake.release_estop_button()
        link.estop_reset()
        assert link.status()["relay"] == "off"  # 해제해도 꺼진 채
        link.relay_on()
        assert link.status()["relay"] == "on"
        with pytest.raises(OutletRefused):
            link.set_rate(0)
    finally:
        _close(link, fake)


def test_relay_off_means_no_appliance_power():
    link, fake = _link({"speed": 50.0, "relay_on": True})
    try:
        sensor = link.sensor()
        fake.start_run(run_s=5.0, run_w=900.0)
        assert max(sensor.read().watts for _ in range(5)) == pytest.approx(900.0)
        link.relay_off()
        time.sleep(0.02)
        sensor = link.sensor()
        assert sensor.read().watts == 0.0
    finally:
        _close(link, fake)


def test_config_from_env():
    cfg = OutletConfig.from_env({"SIMPLELAY_OUTLET_STALE_MS": "2500", "SIMPLELAY_OUTLET_HEARTBEAT_MS": "off"})
    assert cfg.stale_s == 2.5 and cfg.heartbeat_s is None
    assert OutletConfig.from_env({}).heartbeat_s == 1.0
    with pytest.raises(RuntimeError):
        OutletConfig.from_env({"SIMPLELAY_OUTLET_STALE_MS": "soon"})
