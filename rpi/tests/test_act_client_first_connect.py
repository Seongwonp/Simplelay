"""UART 첫 연결 실패에도 백엔드가 뜬다(2026-10-06 인계 §6).

종전: ``open_uart_act_controller``가 첫 연결을 그 자리에서 기다려, RPi4 실행기가 꺼져 있으면(socket:// 거절,
/dev/tty* 없음) 예외가 나 백엔드 기동 자체가 실패했다. 고친 뒤 기대:
  - 공장은 바로 돌아오고, 첫 연결도 재연결과 같은 간격(늘어나는 대기, 상한)으로 배경에서 다시 시도한다.
  - 잇기 전에는 링크 끊김이다 — 걸림 상태는 '모름'(풀림으로 가정하지 않음), 실행은 기존 준비 안 됨(412)으로
    거절하고 사유는 "누름 장치 연결 안 됨". ``/status.actuator_link_up=false``·``/health.actuator_ready=false``·
    ``/connections`` 누름 장치 항목이 같은 사실을 보인다.
  - 이으면 hello부터 보내고, RPi4의 ``estop_state`` 답을 받은 뒤에만 실행이 열린다.
"""

from __future__ import annotations

import asyncio
import json
import sys
import threading
import time
import types

import pytest

from rpi.services.act_client import ActClient, ActLinkError


class FakeWriter:
    def __init__(self) -> None:
        self._buf = b""
        self._lock = threading.Lock()

    def write(self, data: bytes) -> None:
        with self._lock:
            self._buf += data

    async def drain(self) -> None:
        pass

    def close(self) -> None:
        pass

    def messages(self) -> list[dict]:
        with self._lock:
            buf = self._buf
        return [json.loads(line) for line in buf.split(b"\n") if line.strip()]


def _line(doc: dict) -> bytes:
    return (json.dumps(doc, ensure_ascii=False) + "\n").encode()


ANNOUNCE_CLEAR = {"type": "estop_state", "latched": False, "announce": True}


def _wait(pred, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while not pred():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        time.sleep(0.005)


def test_client_without_initial_stream_starts_down_and_connects_in_background():
    """ActClient를 스트림 없이(첫 연결 전) 만들면 링크 끊김으로 시작하고, connector로 배경에서 잇는다."""
    async def _t():
        reader, writer = asyncio.StreamReader(), FakeWriter()
        attempts: list[float] = []

        async def connector():
            attempts.append(time.monotonic())
            if len(attempts) < 3:
                raise OSError("connection refused — RPi4 실행기가 아직 꺼져 있음")
            return reader, writer

        client = ActClient(None, None, hello=True, connector=connector, reconnect_backoff=(0.01, 0.05))
        assert client.link_up is False
        await client.start()
        assert client.estop_latched is None
        with pytest.raises(ActLinkError):
            await asyncio.wait_for(client.execute(["시작"], sequence_id="s-down", appliance_id="microwave"), 1.0)

        deadline = time.monotonic() + 2.0
        while {"type": "hello"} not in writer.messages():
            assert time.monotonic() < deadline, "first connection never established"
            await asyncio.sleep(0.005)
        assert len(attempts) == 3
        assert client.link_up is True
        assert client.estop_latched is None  # hello 답 전에는 여전히 모름
        assert not any(m.get("sequence_id") == "s-down" for m in writer.messages())
        reader.feed_data(_line(ANNOUNCE_CLEAR))
        while client.estop_latched is not False:
            await asyncio.sleep(0.005)
        task = asyncio.create_task(client.execute(["시작"], sequence_id="s1", appliance_id="microwave"))
        while not any(m.get("sequence_id") == "s1" for m in writer.messages()):
            await asyncio.sleep(0.005)
        reader.feed_data(_line({"type": "result", "sequence_id": "s1", "success": True, "retry": 0}))
        assert (await asyncio.wait_for(task, 1.0)).success is True
        await client.stop()

    asyncio.run(_t())


@pytest.fixture()
def unreachable_rpi4(monkeypatch):
    """serial_asyncio 가짜 — ``allow``가 설정되기 전까지는 연결 거절(RPi4 실행기 꺼짐)."""
    allow = threading.Event()
    opened: list[tuple[str, int]] = []
    streams: list[tuple[asyncio.StreamReader, FakeWriter]] = []

    async def open_serial_connection(url, baudrate):
        opened.append((url, baudrate))
        if not allow.is_set():
            raise OSError("[Errno 111] Connection refused")
        pair = (asyncio.StreamReader(), FakeWriter())
        streams.append(pair)
        return pair

    fake = types.ModuleType("serial_asyncio")
    fake.open_serial_connection = open_serial_connection  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "serial_asyncio", fake)
    monkeypatch.setattr(ActClient, "RECONNECT_BACKOFF", (0.01, 0.05), raising=False)
    return allow, opened, streams


def test_uart_factory_returns_even_if_first_connection_fails_then_connects(unreachable_rpi4):
    from rpi.services import act_client_controller as acc

    allow, opened, streams = unreachable_rpi4
    started = time.monotonic()
    controller = acc.open_uart_act_controller("socket://rpi4:7000", 115200)  # 종전: OSError로 기동 실패
    loop = controller._loop  # noqa: SLF001
    try:
        assert time.monotonic() - started < 2.0
        _wait(lambda: len(opened) >= 3)  # 배경에서 계속 다시 시도
        status = controller.estop_status()
        assert status["link_up"] is False and status["known"] is False and status["latched"] is None

        allow.set()
        _wait(lambda: streams and {"type": "hello"} in streams[0][1].messages())
        assert all(o == ("socket://rpi4:7000", 115200) for o in opened)
        assert controller.estop_status()["link_up"] is True
        assert controller.estop_status()["known"] is False  # 답 전에는 확인 중
        loop.call_soon_threadsafe(streams[0][0].feed_data, _line(ANNOUNCE_CLEAR))
        _wait(lambda: controller.estop_status()["latched"] is False)
    finally:
        controller.close()
        loop.call_soon_threadsafe(loop.stop)


def test_backend_refuses_with_link_down_reason_until_connected_then_executes(unreachable_rpi4, monkeypatch):
    """API까지: 잇기 전에는 412 '누름 장치 연결 안 됨'·상태에 링크 끊김, 이은 뒤(걸림 답 받은 뒤) 실행 성공."""
    from fastapi.testclient import TestClient

    from rpi.api import deps
    from rpi.api.service import ACT_LINK_DOWN_REASON, SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services import act_client_controller as acc

    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_THINQ_MODE"):
        monkeypatch.delenv(name, raising=False)
    # SIMPLELAY_ACT_MODE=uart는 /connections를 부를 때만 켠다 — 켜 둔 채면 get_service를 직접 부르는 다른
    # 의존성(제안 서비스 등)이 두 번째 UART 컨트롤러를 만들어 같은 가짜 포트를 잡는다.
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    allow, opened, streams = unreachable_rpi4
    assert "누름 장치 연결 안 됨" in ACT_LINK_DOWN_REASON

    controller = acc.open_uart_act_controller("socket://rpi4:7000", 115200)
    loop = controller._loop  # noqa: SLF001
    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    service = SimpleLayService(RuleBasedIntentResolver(), controller,
                               appliance_registry=deps.get_appliance_registry())
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        c = TestClient(app)
        _wait(lambda: len(opened) >= 2)
        res = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
        assert res.status_code == 412, res.text
        assert "누름 장치 연결 안 됨" in res.text
        assert c.get("/status").json()["actuator_link_up"] is False
        assert c.get("/health").json()["actuator_ready"] is False
        monkeypatch.setattr("rpi.api.router.builtin_appliances_visible", lambda: True)  # 내장 가전을 목록에 보이게
        mw = next(a for a in c.get("/appliances").json() if a["id"] == "microwave")
        assert mw["can_execute"] is False and mw["readiness_reasons"] == [ACT_LINK_DOWN_REASON]
        monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
        press = c.get("/connections").json()["items"][1]
        monkeypatch.delenv("SIMPLELAY_ACT_MODE")
        assert (press["state"], press["title"]) == ("error", "누름 장치 연결 안 됨")

        allow.set()
        _wait(lambda: streams and {"type": "hello"} in streams[0][1].messages())
        # 이었지만 걸림 답 전: 여전히 거절(확인 중) — 풀림으로 가정하지 않는다.
        res = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
        assert res.status_code == 412 and "확인하는 중" in res.text
        assert c.get("/status").json()["actuator_link_up"] is True
        reader, writer = streams[0]
        loop.call_soon_threadsafe(reader.feed_data, _line(ANNOUNCE_CLEAR))
        _wait(lambda: service.estop_block_reason() is None)
        assert c.get("/health").json()["actuator_ready"] is True

        def _reply():
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                for m in writer.messages():
                    if m.get("type") == "execute":
                        loop.call_soon_threadsafe(reader.feed_data, _line(
                            {"type": "result", "sequence_id": m["sequence_id"], "success": True, "retry": 0}))
                        return
                time.sleep(0.005)

        threading.Thread(target=_reply, daemon=True).start()
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        result = controller.execute(["즉석밥", "시작"])
        assert result.status.value == "succeeded"
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        for dep in (deps.get_appliance_registry, deps.get_service):
            dep.cache_clear()
        controller.close()
        loop.call_soon_threadsafe(loop.stop)
