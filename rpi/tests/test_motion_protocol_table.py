"""모션 MCU 규약 대조 — 호스트 어댑터 · 가짜 MCU · 펌웨어 명령 표가 같은 말을 하는지.

C 코드를 돌리지 않는다. 확인하는 것은 세 가지다.
1. `SerialMotionClient`가 실제로 쓰는 요청 줄의 명령·필드 = `firmware-motion/protocol_table.json`.
2. `rpi/tools/fake_mcu.py`(실행 가능한 기준)의 명령·응답 필드·이벤트·오류 코드 = 같은 표.
3. 표의 명령·필드·오류 코드·상태 이름이 펌웨어 소스(`firmware-motion/src`)에 문자열로 있다.
4. heartbeat(ping)·리밋 조회(limits) 규칙을 가짜 MCU로 돌려 본다 — heartbeat가 있으면 짧은
   워치독보다 긴 명령도 끝나고, 없으면 가짜 MCU가 host_timeout으로 멈춘다.

펌웨어가 실제로 그 문자열을 올바른 자리에서 쓰는지는 실물(또는 HIL)로만 확인된다 — 이 시험은
이름이 어긋나는 것만 잡는다. 수치는 리허설용 임의 값(REHEARSAL_CONFIG)이며 실물 값이 아니다.
"""

from __future__ import annotations

import dataclasses
import json
import time
from pathlib import Path

import pytest

from rpi.controller import PressCommand
from rpi.controller.serial_motion import InMemoryLinePipe, MotionAlarm, MotionConfig, SerialMotionClient
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu

ROOT = Path(__file__).resolve().parents[2]
TABLE = json.loads((ROOT / "firmware-motion" / "protocol_table.json").read_text(encoding="utf-8"))
FIRMWARE_SRC = "\n".join(
    p.read_text(encoding="utf-8") for p in sorted((ROOT / "firmware-motion" / "src").glob("*.cpp"))
)


def _request_fields(doc: dict) -> list[str]:
    spec = TABLE["commands"][doc["cmd"]]
    if "request_by_mode" in spec:
        return spec["request_by_mode"][doc["mode"]]
    return spec["request"]


def _wait_received(mcu: FakeMcu, count: int) -> None:
    deadline = time.monotonic() + 2.0
    while len(mcu.received) < count and time.monotonic() < deadline:
        time.sleep(0.01)


def _drive_client(config) -> list[dict]:
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    try:
        client = SerialMotionClient(pipe.host, config, poll_s=0.01)
        client.status()
        client.home()
        client.move_to(10.0, 5.0)
        client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0, press_ms=100))
        client.request_stop()
        _wait_received(mcu, 6)
        return list(mcu.received)
    finally:
        mcu.close()


@pytest.mark.parametrize("mode", ["depth", "duration"])
def test_client_request_lines_match_table(mode):
    config = REHEARSAL_CONFIG
    if mode == "duration":
        config = dataclasses.replace(REHEARSAL_CONFIG, press_mode="duration", press_drive_ms=120)
    received = _drive_client(config)

    # heartbeat(ping)는 응답이 늦을 때만 끼므로 순서 비교에서 빼고, 필드는 아래에서 같이 본다.
    assert [d["cmd"] for d in received if d["cmd"] != "ping"] == ["status", "home", "move", "move", "press", "stop"]
    for doc in received:
        assert doc["cmd"] in TABLE["commands"], doc
        assert sorted(doc) == sorted(_request_fields(doc)), doc
        assert isinstance(doc["id"], int) and not isinstance(doc["id"], bool)
    press = next(d for d in received if d["cmd"] == "press")
    assert press["mode"] == mode
    move = next(d for d in received if d["cmd"] == "move")
    assert isinstance(move["a"], int) and isinstance(move["b"], int)  # MCU는 카운트를 받는다


def test_fake_mcu_matches_table():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    try:
        assert sorted(mcu.handlers) == sorted(TABLE["commands"])
        requests = {
            "status": {"id": 1, "cmd": "status"},
            "home": {"id": 2, "cmd": "home"},
            "move": {"id": 3, "cmd": "move", "a": 1, "b": 2, "x_mm": 0.0, "y_mm": 0.0},
            "press": {"id": 4, "cmd": "press", "mode": "depth", "z_counts": 1, "dwell_ms": 1},
            "stop": {"id": 5, "cmd": "stop"},
            "ping": {"id": 6, "cmd": "ping"},
            "limits": {"id": 7, "cmd": "limits"},
        }
        for cmd, spec in TABLE["commands"].items():
            replies = mcu.handlers[cmd](requests[cmd])
            events = [r["event"] for r in replies if "event" in r]
            final = [r for r in replies if "event" not in r]
            assert events == spec["events"], cmd
            assert len(final) == 1 and sorted(final[0]) == sorted(spec["reply"]), cmd
            assert final[0]["id"] == requests[cmd]["id"]
        status = mcu.handlers["status"](requests["status"])[0]
        assert status["state"] in TABLE["states"]
        limits = mcu.handlers["limits"](requests["limits"])[0]
        for key in ("raw", "debounced"):
            assert sorted(limits[key]) == sorted(TABLE["limit_inputs"])
            assert all(isinstance(v, bool) for v in limits[key].values())
    finally:
        mcu.close()


def test_fake_mcu_unknown_command_error_is_in_table():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    try:
        pipe.host.write_line(json.dumps({"id": 9, "cmd": "dance"}))
        reply = json.loads(pipe.host.read_line(2.0) or "{}")
    finally:
        mcu.close()
    assert sorted(reply) == sorted(TABLE["error_reply"])
    assert reply["error"] in TABLE["errors"]


def _in_firmware(name: str) -> bool:
    return f'"{name}"' in FIRMWARE_SRC or f'\\"{name}\\"' in FIRMWARE_SRC


def test_firmware_source_mentions_every_table_name():
    names: set[str] = set(TABLE["commands"])
    for spec in TABLE["commands"].values():
        names.update(spec.get("reply", []))
        names.update(spec.get("events", []))
        names.update(spec.get("request", []))
        for fields in spec.get("request_by_mode", {}).values():
            names.update(fields)
        names.update(spec.get("request_by_mode", {}))
    names.update(TABLE["error_reply"])
    names.update(TABLE["errors"])
    names.update(TABLE["events"])
    names.update(TABLE["alarm_reasons"])
    names.update(TABLE["states"])
    names.update(TABLE["limit_inputs"])
    names.discard("cmd")  # 펌웨어는 cmd 키를 읽기만 한다(아래에서 따로 확인)
    missing = sorted(n for n in names if not _in_firmware(n))
    assert missing == []
    assert 'doc["cmd"]' in FIRMWARE_SRC


# ── heartbeat · limits ──────────────────────────────────────────────────────

WATCHDOG_S = 0.3  # 가짜 MCU 워치독(시험용 임의 값 — 펌웨어 HOST_WATCHDOG_MS의 축소판)
LONG_HOME_S = 1.0  # 워치독보다 세 배 넘게 긴 원점 복귀


def _long_home_link(heartbeat_ms):
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, watchdog_s=WATCHDOG_S)
    mcu.delays["home"] = LONG_HOME_S
    config = dataclasses.replace(REHEARSAL_CONFIG, home_timeout_s=5.0, heartbeat_ms=heartbeat_ms)
    return pipe, mcu, SerialMotionClient(pipe.host, config, poll_s=0.01)


def test_heartbeat_keeps_a_long_command_alive_past_the_watchdog():
    pipe, mcu, client = _long_home_link(heartbeat_ms=100)
    try:
        started = time.monotonic()
        client.home()
        elapsed = time.monotonic() - started
    finally:
        mcu.close()
    # ping 응답(다른 id)을 home 응답으로 받았다면 LONG_HOME_S 전에 끝났을 것이다.
    assert elapsed >= LONG_HOME_S * 0.9
    assert client.homed and mcu.alarm is None
    assert mcu.pings() >= 5 and client.heartbeats_sent == mcu.pings()
    pings = [d for d in mcu.received if d["cmd"] == "ping"]
    assert all(sorted(d) == sorted(TABLE["commands"]["ping"]["request"]) for d in pings)
    home_id = next(d["id"] for d in mcu.received if d["cmd"] == "home")
    assert len({d["id"] for d in pings} | {home_id}) == len(pings) + 1  # id가 모두 다르다


def test_without_heartbeat_the_fake_mcu_stops_on_host_timeout():
    pipe = InMemoryLinePipe()
    events = []
    mcu = FakeMcu(pipe, watchdog_s=WATCHDOG_S)
    mcu.delays["home"] = LONG_HOME_S
    config = dataclasses.replace(REHEARSAL_CONFIG, home_timeout_s=5.0, heartbeat_ms=None)
    client = SerialMotionClient(
        pipe.host, config, poll_s=0.01, on_event=lambda name, doc: events.append((name, doc.get("reason")))
    )
    try:
        started = time.monotonic()
        with pytest.raises(MotionAlarm, match="host_timeout"):
            client.home()
        elapsed = time.monotonic() - started
    finally:
        mcu.close()
    assert elapsed < LONG_HOME_S  # 워치독이 명령보다 먼저 끊었다
    assert mcu.pings() == 0
    assert mcu.alarm == "host_timeout" and not mcu.homed
    assert events == [("alarm", "host_timeout")]
    assert "host_timeout" in TABLE["alarm_reasons"] and "host_timeout" in TABLE["errors"]


def test_heartbeat_is_not_sent_for_quick_queries():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    mcu.delays["status"] = 0.3
    try:
        config = dataclasses.replace(REHEARSAL_CONFIG, heartbeat_ms=50)
        SerialMotionClient(pipe.host, config, poll_s=0.01).status()
    finally:
        mcu.close()
    assert mcu.pings() == 0  # 워치독은 동작 중에만 돈다 — 조회에는 ping을 섞지 않는다


def test_limits_query_returns_raw_and_debounced():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    mcu.limits_raw.update(x=True, z=True)
    mcu.limits_debounced.update(x=True)
    try:
        client = SerialMotionClient(pipe.host, REHEARSAL_CONFIG, poll_s=0.01)
        limits = client.limits()
        state = client.state
    finally:
        mcu.close()
    assert limits.raw == {"x": True, "y": False, "z": True}
    assert limits.debounced == {"x": True, "y": False, "z": False}
    assert mcu.cmds() == ["limits"]
    assert sorted(mcu.received[0]) == sorted(TABLE["commands"]["limits"]["request"])
    assert state.value == "unknown"  # 조회는 어댑터 상태를 바꾸지 않는다


def test_heartbeat_env_can_be_turned_off():
    assert MotionConfig().heartbeat_ms == 500
    assert MotionConfig.from_env({"SIMPLELAY_MOTION_HEARTBEAT_MS": "250"}).heartbeat_ms == 250
    assert MotionConfig.from_env({"SIMPLELAY_MOTION_HEARTBEAT_MS": "off"}).heartbeat_ms is None
    with pytest.raises(ValueError):
        MotionConfig(heartbeat_ms=0)


def test_firmware_watchdog_is_short_and_checked_against_heartbeat():
    config_h = (ROOT / "firmware-motion" / "include" / "config.h").read_text(encoding="utf-8")

    def define(name: str) -> int:
        for line in config_h.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "#define" and parts[1] == name:
                return int(parts[2])
        raise AssertionError(name)

    watchdog, heartbeat = define("HOST_WATCHDOG_MS"), define("HOST_HEARTBEAT_MS")
    assert heartbeat == REHEARSAL_CONFIG.heartbeat_ms == 500  # 호스트 기본값과 같은 박자
    assert 3 * heartbeat <= watchdog <= 5000  # 초 단위로 줄였다(이전 25 s)
    assert "HOST_WATCHDOG_MS < 3 * HOST_HEARTBEAT_MS" in config_h  # 빌드 검사
