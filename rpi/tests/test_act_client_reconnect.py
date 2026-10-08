"""UART 링크 재연결(2026-10-06 교차 리뷰 HIGH).

실보드에서 본 것: RPi5가 ``socket://<RPi4>:7000``으로 붙어 있을 때 RPi4 실행기 컨테이너가 다시 뜨면
읽기 루프가 ``SerialException: read failed: socket disconnected``로 죽고, 백엔드를 다시 켤 때까지
다음 실행이 모두 실패했다. 고친 뒤 기대:
  - 끊기면 즉시 링크 끊김으로 표시하고, 기다리던 요청을 바로 실패시킨다(타임아웃까지 붙잡지 않는다).
  - 끊긴 동안·재연결 뒤 hello 답(``estop_state``)을 받기 전까지 걸림 상태는 '모름'이다 → 실행 거절(확인 중).
  - 정해진 간격(늘어나는 대기)으로 다시 잇고, 다시 이으면 hello를 보내 걸림 상태를 다시 받는다.
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
        self.closed = False

    def write(self, data: bytes) -> None:
        with self._lock:
            self._buf += data

    async def drain(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True

    def messages(self) -> list[dict]:
        with self._lock:
            buf = self._buf
        return [json.loads(line) for line in buf.split(b"\n") if line.strip()]


class SocketDisconnected(Exception):
    """serial.serialutil.SerialException 흉내(실보드 로그: 'read failed: socket disconnected')."""


def _line(doc: dict) -> bytes:
    # 실제 실행기는 hello에 구성(v2)과 래치 상태를 함께 광고한다.
    prefix = '{"type":"act_info","execute_protocol":2}\n' if doc.get("type") == "estop_state" else ""
    return (prefix + json.dumps(doc, ensure_ascii=False) + "\n").encode()


ANNOUNCE_CLEAR = {"type": "estop_state", "latched": False, "announce": True}


async def _until(pred, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while not pred():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.005)


def test_read_error_without_connector_fails_pending_and_forgets_latch_state():
    """옛 API만으로(재연결 없이): 읽기 오류면 기다리던 실행을 바로 실패시키고 걸림 상태를 '모름'으로 돌린다."""
    async def _t():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        client = ActClient(r1, w1, hello=True)
        await client.start()
        r1.feed_data(_line(ANNOUNCE_CLEAR))
        await _until(lambda: client.estop_latched is False)
        task = asyncio.create_task(client.execute(["시작"], sequence_id="s1", appliance_id="microwave"))
        await _until(lambda: any(m.get("type") == "execute" for m in w1.messages()))
        r1.set_exception(SocketDisconnected("read failed: socket disconnected"))
        with pytest.raises(ActLinkError):
            await asyncio.wait_for(task, 1.0)
        assert client.estop_latched is None
        await client.stop()

    asyncio.run(_t())


def test_disconnect_fails_pending_refuses_while_down_and_recovers_after_handshake():
    async def _t():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        r2, w2 = asyncio.StreamReader(), FakeWriter()
        attempts: list[int] = []

        async def connector():
            attempts.append(1)
            if len(attempts) == 1:
                raise OSError("connection refused — RPi4 still restarting")
            return r2, w2

        client = ActClient(r1, w1, hello=True, connector=connector, reconnect_backoff=(0.01, 0.05))
        await client.start()
        assert w1.messages() == [{"type": "hello"}]
        r1.feed_data(_line(ANNOUNCE_CLEAR))
        await _until(lambda: client.estop_latched is False)

        task = asyncio.create_task(client.execute(["즉석밥", "시작"], sequence_id="s1", appliance_id="microwave"))
        await _until(lambda: any(m.get("type") == "execute" for m in w1.messages()))
        r1.set_exception(SocketDisconnected("read failed: socket disconnected"))

        # 기다리던 실행은 타임아웃(30s+)이 아니라 바로 실패한다.
        with pytest.raises(ActLinkError):
            await asyncio.wait_for(task, 1.0)
        # 끊긴 동안: 걸림 상태 '모름' — 풀림으로 가정하지 않는다.
        assert client.estop_latched is None
        assert client.link_up is False
        with pytest.raises(ActLinkError):
            await asyncio.wait_for(client.execute(["시작"], sequence_id="s-down", appliance_id="microwave"), 1.0)
        assert not any(m.get("sequence_id") == "s-down" for m in w1.messages())

        # 다시 이으면 hello부터 보낸다(첫 시도 실패 → 늘린 간격으로 재시도).
        await _until(lambda: {"type": "hello"} in w2.messages())
        assert len(attempts) >= 2
        assert client.link_up is True
        assert w1.closed is True
        # hello 답 전에는 여전히 '모름'
        assert client.estop_latched is None
        r2.feed_data(_line(ANNOUNCE_CLEAR))
        await _until(lambda: client.estop_latched is False)

        task2 = asyncio.create_task(client.execute(["즉석밥", "시작"], sequence_id="s2", appliance_id="microwave"))
        await _until(lambda: any(m.get("sequence_id") == "s2" for m in w2.messages()))
        r2.feed_data(_line({"type": "result", "sequence_id": "s2", "success": True, "retry": 0}))
        result = await asyncio.wait_for(task2, 1.0)
        assert result.success is True
        await client.stop()

    asyncio.run(_t())


def test_eof_also_triggers_reconnect_and_latched_state_is_resynced():
    async def _t():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        r2, w2 = asyncio.StreamReader(), FakeWriter()

        async def connector():
            return r2, w2

        client = ActClient(r1, w1, hello=True, connector=connector, reconnect_backoff=(0.01, 0.05))
        await client.start()
        r1.feed_data(_line(ANNOUNCE_CLEAR))
        await _until(lambda: client.estop_latched is False)
        r1.feed_eof()
        await _until(lambda: {"type": "hello"} in w2.messages())
        # RPi4가 다시 뜨며 걸림을 알린다(예: 콘센트 재부팅) → 그대로 반영
        r2.feed_data(_line({"type": "estop_state", "latched": True, "announce": True,
                            "detail": "콘센트 모듈이 다시 켜져 걸려 있어요"}))
        await _until(lambda: client.estop_latched is True)
        await client.stop()

    asyncio.run(_t())


def test_backoff_is_bounded():
    async def _t():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        stamps: list[float] = []

        async def connector():
            stamps.append(time.monotonic())
            raise OSError("down")

        client = ActClient(r1, w1, connector=connector, reconnect_backoff=(0.01, 0.04))
        await client.start()
        r1.feed_eof()
        await _until(lambda: len(stamps) >= 6, timeout=3.0)
        await client.stop()
        gaps = [b - a for a, b in zip(stamps, stamps[1:])]
        assert max(gaps) < 0.04 + 0.1  # 상한을 넘겨 늘지 않는다(스케줄링 여유 포함)

    asyncio.run(_t())


def test_service_refuses_as_checking_while_link_down_then_allows_after_reconnect():
    """동기 브리지·서비스까지: 끊긴 동안 실행 전 거절 사유는 '확인하는 중', 다시 이은 뒤 실행 성공."""
    from rpi.api.service import ACT_LINK_DOWN_REASON, ESTOP_UNKNOWN_REASON, SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.act_client_controller import ActClientController, start_background_loop

    loop, thread = start_background_loop()
    r2_w2: dict = {}

    def _mk():
        r2_w2["r"] = asyncio.StreamReader()
        r2_w2["w"] = FakeWriter()

    async def _setup():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        _mk()

        async def connector():
            return r2_w2["r"], r2_w2["w"]

        client = ActClient(r1, w1, hello=True, connector=connector, reconnect_backoff=(0.1, 0.2))
        await client.start()
        return client, r1

    client, r1 = asyncio.run_coroutine_threadsafe(_setup(), loop).result(2.0)
    controller = ActClientController(loop, client, call_timeout_seconds=2.0)
    service = SimpleLayService(RuleBasedIntentResolver(), controller)
    try:
        loop.call_soon_threadsafe(r1.feed_data, _line(ANNOUNCE_CLEAR))
        deadline = time.monotonic() + 2.0
        while service.estop_block_reason() is not None and time.monotonic() < deadline:
            time.sleep(0.005)
        assert service.estop_block_reason() is None

        loop.call_soon_threadsafe(r1.set_exception, SocketDisconnected("read failed: socket disconnected"))
        deadline = time.monotonic() + 2.0
        while service.estop_block_reason() is None and time.monotonic() < deadline:
            time.sleep(0.005)
        # 끊긴 동안은 더 구체적인 사유(누름 장치 연결 안 됨, 2026-10-06 인계 §6) — 걸림 상태도 여전히 모름이다.
        assert service.estop_block_reason() == ACT_LINK_DOWN_REASON
        assert controller.estop_status()["known"] is False

        w2 = r2_w2["w"]
        deadline = time.monotonic() + 2.0
        while {"type": "hello"} not in w2.messages() and time.monotonic() < deadline:
            time.sleep(0.005)
        assert {"type": "hello"} in w2.messages()
        assert service.estop_block_reason() == ESTOP_UNKNOWN_REASON  # 답 전에는 여전히 확인 중
        loop.call_soon_threadsafe(r2_w2["r"].feed_data, _line(ANNOUNCE_CLEAR))
        deadline = time.monotonic() + 2.0
        while service.estop_block_reason() is not None and time.monotonic() < deadline:
            time.sleep(0.005)
        assert service.estop_block_reason() is None

        def _reply():
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                for m in w2.messages():
                    if m.get("type") == "execute":
                        loop.call_soon_threadsafe(r2_w2["r"].feed_data, _line(
                            {"type": "result", "sequence_id": m["sequence_id"], "success": True, "retry": 0}))
                        return
                time.sleep(0.005)

        threading.Thread(target=_reply, daemon=True).start()
        controller.arm_execute_target("microwave")  # 2026-10-07: 대상 필수(평가 H3)
        result = controller.execute(["즉석밥", "시작"])
        assert result.status.value == "succeeded"
    finally:
        controller.close()
        loop.call_soon_threadsafe(loop.stop)
        thread.join(timeout=2.0)


def test_uart_factory_wires_a_reconnecting_connector(monkeypatch):
    """실기기 공장(socket://·/dev/tty* 공통)이 같은 재연결 감시를 붙인다 — 끊기면 같은 포트를 다시 연다."""
    from rpi.services import act_client_controller as acc

    opened: list[tuple[str, int]] = []
    streams: list[tuple[asyncio.StreamReader, FakeWriter]] = []

    async def open_serial_connection(url, baudrate):
        opened.append((url, baudrate))
        pair = (asyncio.StreamReader(), FakeWriter())
        streams.append(pair)
        return pair

    fake = types.ModuleType("serial_asyncio")
    fake.open_serial_connection = open_serial_connection  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "serial_asyncio", fake)
    monkeypatch.setattr(acc.ActClient, "RECONNECT_BACKOFF", (0.01, 0.05), raising=False)

    controller = acc.open_uart_act_controller("socket://rpi4:7000", 115200)
    try:
        # 첫 연결은 배경에서 한다(2026-10-06 인계 §6) — 이어질 때까지 기다린다.
        deadline = time.monotonic() + 2.0
        while not streams and time.monotonic() < deadline:
            time.sleep(0.005)
        assert opened == [("socket://rpi4:7000", 115200)]
        reader, _ = streams[0]
        controller._loop.call_soon_threadsafe(reader.feed_eof)
        deadline = time.monotonic() + 2.0
        while len(opened) < 2 and time.monotonic() < deadline:
            time.sleep(0.005)
        assert opened[1] == ("socket://rpi4:7000", 115200)
        deadline = time.monotonic() + 2.0
        while {"type": "hello"} not in streams[1][1].messages() and time.monotonic() < deadline:
            time.sleep(0.005)
        assert {"type": "hello"} in streams[1][1].messages()
    finally:
        loop = controller._loop
        controller.close()
        loop.call_soon_threadsafe(loop.stop)


@pytest.mark.parametrize("where", ["write", "drain"])
def test_write_only_failure_reconnects_without_eof(where):
    async def run():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        r2, w2 = asyncio.StreamReader(), FakeWriter()
        attempts = []
        async def connector():
            attempts.append(time.perf_counter())
            return r2, w2
        client = ActClient(r1, w1, connector=connector, reconnect_backoff=(0.1, 0.2))
        await client.start()
        client.estop_latched = False
        client.act_info = {"execute_protocol": 2}
        def fail_write(data):
            raise OSError("write only failure")
        async def fail_drain():
            raise OSError("drain only failure")
        if where == "write":
            w1.write = fail_write
        else:
            w1.drain = fail_drain
        started = time.perf_counter()
        try:
            with pytest.raises((OSError, ActLinkError)):
                await client.execute(["start"], appliance_id="home_mw")
            assert client.link_up is False
            assert client.estop_latched is None
            with pytest.raises(ActLinkError):
                await client.execute(["start"], appliance_id="home_mw")
            await _until(lambda: bool(w2.messages()))
            assert attempts[0] - started >= 0.08
            assert w2.messages() == [{"type": "hello"}]
            assert client.estop_latched is None
            r2.feed_data(_line(ANNOUNCE_CLEAR))
            await _until(lambda: client.estop_latched is False)
            assert not any(m["type"] == "execute" for m in w2.messages())
        finally:
            await client.stop()
    asyncio.run(run())


@pytest.mark.parametrize("version", [0, 1, None, "2"])
def test_old_announced_protocol_refused_before_execute(version):
    async def run():
        reader, writer = asyncio.StreamReader(), FakeWriter()
        client = ActClient(reader, writer)
        client._handle_line(json.dumps({"type": "act_info", "execute_protocol": version}))
        with pytest.raises(ActLinkError, match="execute_protocol"):
            await asyncio.wait_for(client.execute(["start"], appliance_id="home_mw"), 0.02)
        assert writer.messages() == []
    asyncio.run(run())


@pytest.mark.parametrize("when", ["after_reconnect", "before_reconnect"])
def test_stale_drain_failure_does_not_tear_down_new_link_or_double_count(when):
    """2026-10-08 리뷰(LOW): 읽기 루프가 EOF로 링크를 내리고 옛 writer를 닫은 뒤, 진행 중이던 옛 ``drain()``이
    늦게 실패한다. 이미 내려간 링크를 다시 세지 않고(``link_drops`` 1), 재연결이 끝난 뒤라면 새 링크
    (걸림 상태·구성·writer·reader)를 건드리지 않는다."""
    async def run():
        r1, w1 = asyncio.StreamReader(), FakeWriter()
        r2, w2 = asyncio.StreamReader(), FakeWriter()

        async def connector():
            return r2, w2

        backoff = (0.01, 0.05) if when == "after_reconnect" else (0.5, 1.0)
        client = ActClient(r1, w1, hello=True, connector=connector, reconnect_backoff=backoff)
        await client.start()
        r1.feed_data(_line(ANNOUNCE_CLEAR))
        await _until(lambda: client.estop_latched is False)

        gate = asyncio.Event()

        async def slow_failing_drain():
            await gate.wait()
            raise OSError("late drain failure on old link")

        w1.drain = slow_failing_drain
        try:
            send = asyncio.create_task(client.clear_failure())
            await _until(lambda: {"type": "clear_failure"} in w1.messages())
            r1.feed_eof()
            await _until(lambda: client.link_up is False)
            assert client.link_drops == 1
            if when == "after_reconnect":
                await _until(lambda: {"type": "hello"} in w2.messages())
                r2.feed_data(_line(ANNOUNCE_CLEAR))
                await _until(lambda: client.estop_latched is False and bool(client.act_info))
            gate.set()
            with pytest.raises(OSError):
                await asyncio.wait_for(send, 1.0)
            assert client.link_drops == 1
            if when == "after_reconnect":
                assert client.link_up is True
                assert client.estop_latched is False
                assert client.act_info == {"execute_protocol": 2}
                assert w2.closed is False
                assert r2.exception() is None
                # 새 링크는 계속 읽는다.
                r2.feed_data(_line({"type": "estop_state", "latched": True, "announce": True}))
                await _until(lambda: client.estop_latched is True)
            else:
                assert client.link_up is False
                await _until(lambda: {"type": "hello"} in w2.messages())
                assert client.link_drops == 1
        finally:
            await client.stop()

    asyncio.run(run())
