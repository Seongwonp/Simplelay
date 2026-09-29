"""모션 MCU 규약 대조 — 호스트 어댑터 · 가짜 MCU · 펌웨어 명령 표가 같은 말을 하는지.

C 코드를 돌리지 않는다. 확인하는 것은 세 가지다.
1. `SerialMotionClient`가 실제로 쓰는 요청 줄의 명령·필드 = `firmware-motion/protocol_table.json`.
2. `rpi/tools/fake_mcu.py`(실행 가능한 기준)의 명령·응답 필드·이벤트·오류 코드 = 같은 표.
3. 표의 명령·필드·오류 코드·상태 이름이 펌웨어 소스(`firmware-motion/src`)에 문자열로 있다.

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
from rpi.controller.serial_motion import InMemoryLinePipe, SerialMotionClient
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

    assert [d["cmd"] for d in received] == ["status", "home", "move", "move", "press", "stop"]
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
    names.discard("cmd")  # 펌웨어는 cmd 키를 읽기만 한다(아래에서 따로 확인)
    missing = sorted(n for n in names if not _in_firmware(n))
    assert missing == []
    assert 'doc["cmd"]' in FIRMWARE_SRC
