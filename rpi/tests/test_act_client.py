"""ActClient tests — no real serial port required.

Mirrors rpi4/tests/test_act_executor.py's FakeWriter/feed pattern, since
ActClient is the RPi5-side counterpart of that module's ActExecutor.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from rpi.services.act_client import (
    ActClient,
    ActClientConfig,
    ActLinkBusyError,
    ActLinkError,
    ActLinkTimeoutError,
    AlertEvent,
)


class FakeWriter:
    """Captures bytes written by ActClient without a real transport."""

    def __init__(self) -> None:
        self._buf = b""

    def write(self, data: bytes) -> None:
        self._buf += data

    async def drain(self) -> None:
        pass

    def messages(self) -> list[dict]:
        return [json.loads(line) for line in self._buf.split(b"\n") if line.strip()]


def feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


def run(coro):
    return asyncio.run(coro)


def _make_client(reader, writer, **kwargs) -> ActClient:
    return ActClient(reader=reader, writer=writer, **kwargs)


# ── execute() happy path ─────────────────────────────────────────────────────

def test_execute_sends_execute_message_with_given_sequence_id():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        task = asyncio.create_task(client.execute(["시작", "정지"], sequence_id="seq-1", appliance_id="microwave"))
        await asyncio.sleep(0)  # let execute() write before we inspect
        assert writer.messages() == [
            {"type": "execute", "sequence_id": "seq-1", "buttons": ["시작", "정지"], "appliance_id": "microwave"}
        ]

        feed(reader, {"type": "result", "sequence_id": "seq-1", "success": True, "retry": 0})
        result = await task
        assert result.sequence_id == "seq-1"
        assert result.success is True
        assert result.retry == 0

        await client.stop()
    run(_t())


def test_execute_without_sequence_id_generates_one():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        task = asyncio.create_task(client.execute(["시작"], appliance_id="microwave"))
        await asyncio.sleep(0)
        sent = writer.messages()[0]
        assert sent["type"] == "execute"
        assert isinstance(sent["sequence_id"], str) and sent["sequence_id"]

        feed(reader, {"type": "result", "sequence_id": sent["sequence_id"], "success": True, "retry": 0})
        result = await task
        assert result.sequence_id == sent["sequence_id"]

        await client.stop()
    run(_t())


def test_execute_reports_retry_count():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        task = asyncio.create_task(client.execute(["시작"], sequence_id="seq-2", appliance_id="microwave"))
        await asyncio.sleep(0)
        feed(reader, {"type": "result", "sequence_id": "seq-2", "success": True, "retry": 3})
        result = await task
        assert result.retry == 3

        await client.stop()
    run(_t())


# ── execute() error paths ────────────────────────────────────────────────────

def test_execute_raises_on_error_response():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        task = asyncio.create_task(client.execute(["시작"], sequence_id="seq-3", appliance_id="microwave"))
        await asyncio.sleep(0)
        feed(reader, {"type": "error", "sequence_id": "seq-3", "reason": "actuator_fail"})

        with pytest.raises(ActLinkError, match="actuator_fail"):
            await task

        await client.stop()
    run(_t())


def test_execute_raises_timeout_when_rpi4_never_responds():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(
            reader,
            writer,
            config=ActClientConfig(
                response_timeout_seconds=0.05, per_button_timeout_seconds=0.0
            ),
        )
        await client.start()

        with pytest.raises(ActLinkTimeoutError):
            await client.execute(["시작"], sequence_id="seq-4", appliance_id="microwave")

        # RPi5가 실패로 보고하는 순간 RPi4도 멈춰야 한다 — timeout 직후
        # abort가 전송됐는지 확인 (화면은 실패인데 실물은 계속 누르는
        # 불일치 방지)
        assert writer.messages()[-1] == {"type": "abort"}

        await client.stop()
    run(_t())


# ── 송신 실패 정리 (최종 교차 리뷰 중요) ────────────────────────────────────

class BrokenWriter(FakeWriter):
    """drain()에서 실패하는 writer — UART 단선/RPi4 재부팅 상황."""

    def __init__(self, fail: bool = True) -> None:
        super().__init__()
        self.fail = fail

    async def drain(self) -> None:
        if self.fail:
            raise ConnectionResetError("serial link down")


def test_send_failure_does_not_leave_the_client_permanently_busy():
    async def _t():
        reader = asyncio.StreamReader()
        writer = BrokenWriter()
        client = _make_client(reader, writer)
        await client.start()

        # 첫 실행: 송신 자체가 실패한다
        with pytest.raises(ConnectionResetError):
            await client.execute(["시작"], sequence_id="J1", appliance_id="microwave")

        # 케이블이 복구되면 다음 실행은 정상 동작해야 한다 — 이전에는
        # _pending이 남아 ActLinkBusyError로 영구히 막혔다
        writer.fail = False
        task = asyncio.create_task(client.execute(["시작"], sequence_id="J2", appliance_id="microwave"))
        await asyncio.sleep(0.01)
        feed(reader, {"type": "result", "sequence_id": "J2", "success": True, "retry": 0})
        result = await task
        assert result.sequence_id == "J2"

        await client.stop()
    run(_t())


def test_inject_failure_sends_arm_message():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        await client.inject_failure(button_index=1, attempts=2)
        await client.clear_failure()

        assert writer.messages() == [
            {"type": "inject_failure", "button_index": 1, "attempts": 2},
            {"type": "clear_failure"},
        ]
        await client.stop()
    run(_t())


def test_timeout_config_can_be_calibrated_from_env(monkeypatch):
    # 실기기에서 측정한 값을 코드 수정 없이 반영할 수 있어야 한다
    monkeypatch.setenv("SIMPLELAY_UART_BASE_TIMEOUT", "45")
    monkeypatch.setenv("SIMPLELAY_UART_PER_BUTTON_TIMEOUT", "9.5")

    cfg = ActClientConfig.from_env()

    assert cfg.timeout_for(2) == 45 + 19.0


@pytest.mark.parametrize("bad", ["", "abc", "-3"])
def test_invalid_timeout_env_falls_back_to_defaults(monkeypatch, bad):
    # 오타 하나로 타임아웃이 0이 되면 정상 실행이 전부 실패한다
    monkeypatch.setenv("SIMPLELAY_UART_PER_BUTTON_TIMEOUT", bad)

    assert ActClientConfig.from_env().per_button_timeout_seconds == 6.0


def test_response_timeout_scales_with_button_count():
    cfg = ActClientConfig(response_timeout_seconds=30.0, per_button_timeout_seconds=6.0)
    assert cfg.timeout_for(0) == 30.0
    assert cfg.timeout_for(1) == 36.0
    assert cfg.timeout_for(10) == 90.0  # 고정 30s였다면 여기서 오판 timeout
    assert cfg.timeout_for(-1) == 30.0  # 방어적 하한


def test_second_execute_while_first_pending_raises_busy():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        first = asyncio.create_task(client.execute(["시작"], sequence_id="first", appliance_id="microwave"))
        await asyncio.sleep(0)  # let the first execute() claim self._pending

        with pytest.raises(ActLinkBusyError):
            await client.execute(["정지"], sequence_id="second", appliance_id="microwave")

        feed(reader, {"type": "result", "sequence_id": "first", "success": True, "retry": 0})
        await first
        await client.stop()
    run(_t())


def test_execute_can_be_called_again_after_previous_call_resolved():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        first = asyncio.create_task(client.execute(["시작"], sequence_id="first", appliance_id="microwave"))
        await asyncio.sleep(0)
        feed(reader, {"type": "result", "sequence_id": "first", "success": True, "retry": 0})
        await first

        second = asyncio.create_task(client.execute(["정지"], sequence_id="second", appliance_id="microwave"))
        await asyncio.sleep(0)
        feed(reader, {"type": "result", "sequence_id": "second", "success": False, "retry": 5})
        result = await second
        assert result.sequence_id == "second"
        assert result.success is False

        await client.stop()
    run(_t())


# ── abort() ───────────────────────────────────────────────────────────────────

def test_abort_sends_abort_message_without_waiting_for_a_reply():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        await client.abort()

        assert writer.messages() == [{"type": "abort"}]
        await client.stop()
    run(_t())


# ── alert / alert_cleared ────────────────────────────────────────────────────

def test_alert_while_idle_is_forwarded_to_on_alert():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        received: list[AlertEvent] = []
        client = _make_client(reader, writer, on_alert=received.append)
        await client.start()

        feed(reader, {
            "type": "alert", "kind": "danger_sound",
            "band_energy_ratio": 0.77, "mean_period_seconds": 0.42,
        })
        await asyncio.sleep(0.02)  # let the read loop process the line

        assert len(received) == 1
        assert received[0] == AlertEvent(
            kind="danger_sound", raised=True,
            band_energy_ratio=0.77, mean_period_seconds=0.42,
        )
        await client.stop()
    run(_t())


def test_alert_cleared_is_forwarded_with_raised_false():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        received: list[AlertEvent] = []
        client = _make_client(reader, writer, on_alert=received.append)
        await client.start()

        feed(reader, {"type": "alert_cleared", "kind": "danger_sound"})
        await asyncio.sleep(0.02)

        assert received == [AlertEvent(kind="danger_sound", raised=False)]
        await client.stop()
    run(_t())


def test_alert_mid_execute_does_not_resolve_the_pending_execute():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        received: list[AlertEvent] = []
        client = _make_client(reader, writer, on_alert=received.append)
        await client.start()

        task = asyncio.create_task(client.execute(["시작"], sequence_id="seq-5", appliance_id="microwave"))
        await asyncio.sleep(0)

        feed(reader, {"type": "alert", "kind": "danger_sound"})
        await asyncio.sleep(0.02)
        assert len(received) == 1
        assert not task.done()  # alert must not resolve the execute() future

        feed(reader, {"type": "result", "sequence_id": "seq-5", "success": True, "retry": 0})
        result = await task
        assert result.success is True

        await client.stop()
    run(_t())


def test_no_on_alert_callback_configured_does_not_crash():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)  # on_alert omitted
        await client.start()

        feed(reader, {"type": "alert", "kind": "danger_sound"})
        await asyncio.sleep(0.02)  # would raise inside the read loop if broken

        await client.stop()
    run(_t())


# ── robustness ────────────────────────────────────────────────────────────────

def test_unsolicited_result_with_no_pending_execute_is_ignored():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        feed(reader, {"type": "result", "sequence_id": "orphan", "success": True, "retry": 0})
        await asyncio.sleep(0.02)  # would raise if the read loop crashed

        await client.stop()
    run(_t())


def test_malformed_json_line_does_not_crash_the_read_loop():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()

        reader.feed_data(b"this is not json\n")
        await asyncio.sleep(0.02)

        task = asyncio.create_task(client.execute(["시작"], sequence_id="seq-6", appliance_id="microwave"))
        await asyncio.sleep(0)
        feed(reader, {"type": "result", "sequence_id": "seq-6", "success": True, "retry": 0})
        result = await task
        assert result.success is True

        await client.stop()
    run(_t())


def test_stop_can_be_called_twice_without_error():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(reader, writer)
        await client.start()
        await client.stop()
        await client.stop()
    run(_t())


# ── sequence_id 상관관계 (리뷰 지적 #3 회귀) ─────────────────────────────────

def test_result_with_wrong_sequence_id_does_not_complete_pending():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(
            reader,
            writer,
            config=ActClientConfig(
                response_timeout_seconds=0.2, per_button_timeout_seconds=0.0
            ),
        )
        await client.start()

        task = asyncio.create_task(client.execute(["시작"], sequence_id="J2", appliance_id="microwave"))
        await asyncio.sleep(0.02)
        # 다른(이전) 시퀀스의 결과가 도착 — J2의 결과로 오인하면 안 된다
        feed(reader, {"type": "result", "sequence_id": "J1", "success": True, "retry": 0})
        await asyncio.sleep(0.02)
        assert not task.done()  # 무시되어 계속 대기

        # 올바른 결과가 오면 그때 완료
        feed(reader, {"type": "result", "sequence_id": "J2", "success": True, "retry": 1})
        result = await task
        assert result.sequence_id == "J2"
        assert result.retry == 1

        await client.stop()
    run(_t())


def test_late_result_after_timeout_is_discarded_not_matched_to_next_job():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        client = _make_client(
            reader,
            writer,
            config=ActClientConfig(
                response_timeout_seconds=0.05, per_button_timeout_seconds=0.0
            ),
        )
        await client.start()

        # J1: 응답이 없어 timeout으로 실패 처리
        with pytest.raises(ActLinkTimeoutError):
            await client.execute(["시작"], sequence_id="J1", appliance_id="microwave")

        # J2 시작 — 그 직후 J1의 '늦은' 결과가 도착한다
        task = asyncio.create_task(client.execute(["취소"], sequence_id="J2", appliance_id="microwave"))
        await asyncio.sleep(0.01)
        feed(reader, {"type": "result", "sequence_id": "J1", "success": True, "retry": 0})
        await asyncio.sleep(0.01)
        assert not task.done()  # J1의 결과는 폐기 — J2는 계속 자기 응답을 기다린다

        feed(reader, {"type": "result", "sequence_id": "J2", "success": False, "retry": 2})
        result = await task
        assert result.sequence_id == "J2"
        assert result.success is False

        await client.stop()
    run(_t())
