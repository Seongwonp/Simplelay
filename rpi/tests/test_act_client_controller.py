"""ActClientController tests — a real background event loop thread + fake
reader/writer, no real serial port required.

Since execute() blocks the calling (main) thread until the background loop
resolves the coroutine, replies are fed in from a second helper thread that
polls the fake writer for the outbound request before responding — avoids
guessing timing or the auto-generated sequence_id.
"""

from __future__ import annotations

import asyncio
import json
import threading
import time

import pytest

from rpi.controller import ButtonStatus, ExecutionStatus
from rpi.services.act_client import ActClient, ActClientConfig
from rpi.services.act_client_controller import ActClientController, start_background_loop


class FakeWriter:
    def __init__(self) -> None:
        self._buf = b""
        self._lock = threading.Lock()

    def write(self, data: bytes) -> None:
        with self._lock:
            self._buf += data

    async def drain(self) -> None:
        pass

    def messages(self) -> list[dict]:
        with self._lock:
            buf = self._buf
        return [json.loads(line) for line in buf.split(b"\n") if line.strip()]


def feed(loop: asyncio.AbstractEventLoop, reader: asyncio.StreamReader, doc: dict) -> None:
    payload = (json.dumps(doc, ensure_ascii=False) + "\n").encode()
    loop.call_soon_threadsafe(reader.feed_data, payload)


def _await_last_message(writer: FakeWriter, timeout: float = 2.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        msgs = writer.messages()
        if msgs:
            return msgs[-1]
        time.sleep(0.005)
    raise TimeoutError("no message written in time")


def _make_controller(
    config: ActClientConfig | None = None, call_timeout_seconds: float = 2.0
):
    # StreamReader() must be constructed on a thread with a running loop
    # (it looks one up at __init__ time) -- so build it inside _setup(),
    # which runs on the background loop, not on the calling test thread.
    writer = FakeWriter()
    loop, thread = start_background_loop()

    async def _setup() -> tuple[ActClient, asyncio.StreamReader]:
        reader = asyncio.StreamReader()
        client = ActClient(reader, writer, config=config)
        await client.start()
        return client, reader

    client, reader = asyncio.run_coroutine_threadsafe(_setup(), loop).result(timeout=2.0)
    controller = ActClientController(loop, client, call_timeout_seconds=call_timeout_seconds)
    return controller, loop, thread, reader, writer


def _teardown(controller: ActClientController, loop: asyncio.AbstractEventLoop, thread: threading.Thread) -> None:
    controller.close()
    loop.call_soon_threadsafe(loop.stop)
    thread.join(timeout=2.0)


def _respond_in_background(
    loop: asyncio.AbstractEventLoop, reader: asyncio.StreamReader, writer: FakeWriter, build_reply
) -> None:
    def _run():
        sent = _await_last_message(writer)
        feed(loop, reader, build_reply(sent))
    threading.Thread(target=_run, daemon=True).start()


def test_execute_success_marks_all_buttons_succeeded():
    controller, loop, thread, reader, writer = _make_controller()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "result", "sequence_id": sent["sequence_id"], "success": True, "retry": 0},
        )
        result = controller.execute(["시작", "정지"])

        assert result.status is ExecutionStatus.SUCCEEDED
        assert [b.button for b in result.buttons] == ["시작", "정지"]
        assert all(b.status is ButtonStatus.SUCCEEDED for b in result.buttons)
        assert all(b.attempts == 1 for b in result.buttons)
    finally:
        _teardown(controller, loop, thread)


def test_execute_failure_marks_last_button_failed_with_retry_count():
    controller, loop, thread, reader, writer = _make_controller()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "result", "sequence_id": sent["sequence_id"], "success": False, "retry": 3},
        )
        result = controller.execute(["시작", "정지", "취소"])

        assert result.status is ExecutionStatus.SAFETY_STOPPED
        assert [b.button for b in result.buttons] == ["시작", "정지", "취소"]
        assert result.buttons[0].status is ButtonStatus.SUCCEEDED
        assert result.buttons[1].status is ButtonStatus.SUCCEEDED
        assert result.buttons[2].status is ButtonStatus.FAILED
        assert result.buttons[2].attempts == 4  # retry + 1
    finally:
        _teardown(controller, loop, thread)


def test_execute_single_button_failure_has_no_preceding_succeeded_entries():
    controller, loop, thread, reader, writer = _make_controller()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "result", "sequence_id": sent["sequence_id"], "success": False, "retry": 1},
        )
        result = controller.execute(["시작"])

        assert len(result.buttons) == 1
        assert result.buttons[0].status is ButtonStatus.FAILED
        assert result.buttons[0].attempts == 2
    finally:
        _teardown(controller, loop, thread)


def test_execute_propagates_actuator_error_as_runtime_error():
    controller, loop, thread, reader, writer = _make_controller()
    try:
        _respond_in_background(
            loop, reader, writer,
            lambda sent: {"type": "error", "sequence_id": sent["sequence_id"], "reason": "actuator_fail"},
        )
        with pytest.raises(RuntimeError, match="actuator_fail"):
            controller.execute(["시작"])
    finally:
        _teardown(controller, loop, thread)


def test_execute_times_out_when_rpi4_never_responds():
    controller, loop, thread, reader, writer = _make_controller(
        config=ActClientConfig(response_timeout_seconds=0.05), call_timeout_seconds=1.0
    )
    try:
        with pytest.raises(RuntimeError, match="no response"):
            controller.execute(["시작"])
    finally:
        _teardown(controller, loop, thread)


def test_execute_outer_call_timeout_fires_when_the_loop_bridge_itself_stalls():
    # response_timeout_seconds is generous here -- call_timeout_seconds (the
    # ActClientController-level bound) is what should fire first.
    controller, loop, thread, reader, writer = _make_controller(
        config=ActClientConfig(response_timeout_seconds=10.0), call_timeout_seconds=0.05
    )
    try:
        with pytest.raises(RuntimeError, match=r"ActClientController\.execute\(\) timed out"):
            controller.execute(["시작"])
    finally:
        _teardown(controller, loop, thread)
