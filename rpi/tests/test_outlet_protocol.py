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
    config.setdefault("status_poll_s", None)  # 시험은 명령 순서를 본다 — 주기 status를 끈다
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
    link.handle_doc({"event": "power", "t_ms": 1000, "watts": 3.0, "n": 80})
    clock[0] = 100.5  # 시리얼 지연으로 늦게 받아도
    link.handle_doc({"event": "power", "t_ms": 1100, "watts": 3.0, "n": 80})
    a, b = link.samples_since(0.0)
    assert b.t_s - a.t_s == pytest.approx(0.1)  # 간격은 모듈 시계를 따른다
    # 모듈 재시작(ready 배너): t_ms가 되돌아가도 호스트 시각은 계속 늘어난다
    clock[0] = 100.6
    link.handle_doc({"event": "ready", "fw": "x", "reset": "sw"})
    link.handle_doc({"event": "power", "t_ms": 50, "watts": 4.0, "n": 80})
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
        link.handle_doc({"event": "power", "t_ms": i * 100, "watts": float(i), "n": 80})
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


# ── 2026-10-05 리뷰 수리: 중복 줄(L1)·창 품질(M1)·포트 재연결(M2) ─────────────────


def _good(t_ms: int, seq: int, watts: float = 850.0, **extra) -> dict:
    return {"event": "power", "t_ms": t_ms, "seq": seq, "watts": watts, "n": 80, "err": 0, **extra}


def test_repeated_identical_lines_do_not_refresh_freshness():
    """L1: 같은 줄이 반복돼도(에코·버퍼 재전송) '샘플이 오고 있음'이 되지 않는다 — stale로 드러난다."""
    clock = [0.0]
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None, status_poll_s=None, stale_s=1.0),
                      clock=lambda: clock[0])
    sensor = link.sensor()
    link.handle_doc(_good(1000, 7))
    assert sensor.read().watts == 850.0
    for _ in range(30):
        clock[0] += 0.5
        link.handle_doc(_good(1000, 7))
    assert link.is_stale()
    with pytest.raises(PowerSensorStale):
        sensor.read()
    assert len(link.samples_since(-1e9)) == 1


def test_out_of_order_line_is_dropped_without_reanchoring():
    clock = [10.0]
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None, status_poll_s=None),
                      clock=lambda: clock[0])
    link.handle_doc(_good(2000, 20))
    clock[0] = 10.1
    link.handle_doc(_good(2100, 21))
    clock[0] = 10.2
    link.handle_doc(_good(1900, 19))  # 늦게 온 옛 줄 — 재시작이 아니다
    times = [s.t_s for s in link.samples_since(-1e9)]
    assert len(times) == 2 and link.dropped_out_of_order == 1


def test_reanchor_on_ready_banner_or_small_seq():
    clock = [100.0]
    link = OutletLink(InMemoryLinePipe().host, OutletConfig(heartbeat_s=None, status_poll_s=None),
                      clock=lambda: clock[0])
    link.handle_doc(_good(9000, 90))
    clock[0] = 100.5
    link.handle_doc({"event": "ready", "fw": "x", "reset": "sw"})
    link.handle_doc(_good(100, 0))  # 재시작 뒤 첫 샘플 — ready가 있어 다시 맞춘다
    clock[0] = 100.6
    link.handle_doc(_good(200, 1))
    clock[0] = 101.0
    link.handle_doc(_good(50, 0))  # ready를 놓쳤어도 seq가 작은 값으로 되돌아가면 재시작
    clock[0] = 101.1
    link.handle_doc(_good(40, 70))  # 시계가 되돌아갔지만 seq는 재시작이 아니다 — 버린다
    samples = link.samples_since(-1e9)
    assert len(samples) == 4 and link.dropped_out_of_order == 1
    times = [s.t_s for s in samples]
    assert times == sorted(times) and len(set(times)) == 4
    assert times[1] == pytest.approx(100.5)  # ready 뒤 첫 샘플은 받은 시각에 맞춘다


def test_power_windows_with_too_few_samples_or_errors_are_dropped():
    """M1: 창 샘플이 몇 개뿐(n=1 → 0 W)이거나 판독 실패가 많은 줄은 신선한 샘플로 세지 않는다."""
    clock = [0.0]
    link = OutletLink(InMemoryLinePipe().host,
                      OutletConfig(heartbeat_s=None, status_poll_s=None, min_samples=20, max_err_ratio=0.1),
                      clock=lambda: clock[0])
    link.handle_doc({"event": "power", "t_ms": 100, "seq": 1, "watts": 0.0, "n": 1, "err": 79})
    link.handle_doc({"event": "power", "t_ms": 200, "seq": 2, "watts": 640.0, "n": 80, "err": 20})
    link.handle_doc({"event": "power", "t_ms": 300, "seq": 3, "watts": 640.0})  # n 없음
    assert link.latest() is None and link.dropped_quality == 3
    assert link._state(0).last_power_rx is None  # noqa: SLF001 - 버린 줄은 신선도를 갱신하지 않는다
    link.handle_doc({"event": "power", "t_ms": 400, "seq": 4, "watts": 640.0, "n": 80, "err": 2})
    assert link.latest().watts == 640.0
    cfg = OutletConfig.from_env({"SIMPLELAY_OUTLET_MIN_SAMPLES": "40", "SIMPLELAY_OUTLET_MAX_ERR_RATIO": "0.05"})
    assert cfg.min_samples == 40 and cfg.max_err_ratio == 0.05


class _FlakyTransport:
    """읽기에서 포트 오류를 내는 전송(USB 빠짐 흉내). ``unplugged``가 참이면 read_line이 OSError."""

    def __init__(self, inner) -> None:
        self.inner = inner
        self.unplugged = False
        self.closed = False

    def write_line(self, line: str) -> None:
        if self.unplugged:
            raise OSError("device disconnected")
        self.inner.write_line(line)

    def read_line(self, timeout_s: float):
        if self.unplugged:
            raise OSError("device reports readiness to read but returned no data")
        return self.inner.read_line(timeout_s)

    def close(self) -> None:
        self.closed = True


def test_link_reopens_port_after_usb_loss_and_reports_offline_meanwhile():
    """M2: USB가 빠지면 not_ready_reason이 이유를 내고, 꽂히면 backoff로 다시 열어 샘플이 다시 온다."""
    pipe, fake = open_fake_outlet(speed=50.0, relay_on=True)
    first = _FlakyTransport(pipe.host)
    plugged = {"ok": False}

    def reopen():
        if not plugged["ok"]:
            raise OSError("no such device")
        return pipe.host

    link = OutletLink(first, OutletConfig(heartbeat_s=None, status_poll_s=None, offline_s=0.5), mock=True,
                      reopen=reopen, reopen_backoff_s=(0.05,)).start()
    try:
        sensor = link.sensor()
        sensor.read()
        first.unplugged = True
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and link.not_ready_reason() is None:
            time.sleep(0.01)
        assert "다시 여는 중" in (link.not_ready_reason() or "")
        assert first.closed
        plugged["ok"] = True
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and link.reopens == 0:
            time.sleep(0.01)
        assert link.reopens == 1 and link.not_ready_reason() is None
        assert link.sensor().read().watts == pytest.approx(3.0)
        assert link.status()["ok"] is True
    finally:
        _close(link, fake)


def test_reset_estop_if_released_checks_the_button_first():
    link, fake = _link()
    try:
        fake.press_estop()
        assert link.reset_estop_if_released() == (False, "estop_button_pressed")
        assert not any(d.get("cmd") == "estop_reset" for d in fake.received)
        fake.release_estop_button()
        assert link.reset_estop_if_released() == (True, None)
        assert fake.estop_latched is False and link.module_estop is False
    finally:
        _close(link, fake)


def test_offline_and_poll_env():
    cfg = OutletConfig.from_env({"SIMPLELAY_OUTLET_OFFLINE_MS": "5000", "SIMPLELAY_OUTLET_STATUS_POLL_MS": "off"})
    assert cfg.offline_s == 5.0 and cfg.status_poll_s is None
    assert OutletConfig.from_env({}).status_poll_s == 2.0
