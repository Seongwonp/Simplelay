"""ActExecutor tests — no real serial port required.

Test doubles
────────────
FakeWriter    — captures bytes written by the executor (implements _WriterLike)
feed(reader)  — convenience to inject a JSON line into an asyncio.StreamReader
SlowController — controller stub that blocks briefly, for busy-state tests

All tests use asyncio.run() so no pytest-asyncio plugin is needed.
"""

from __future__ import annotations

import asyncio
import json
import time

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier import DangerSoundResult, MockVerifier

from rpi4.models.act_messages import parse_act_message
from rpi4.services.act_executor import ActExecutor


# ── test doubles ─────────────────────────────────────────────────────────────

class FakeWriter:
    """Captures bytes written by ActExecutor without a real transport."""

    def __init__(self) -> None:
        self._buf = b""

    def write(self, data: bytes) -> None:
        self._buf += data

    async def drain(self) -> None:
        pass

    def messages(self) -> list[dict]:
        return [json.loads(line) for line in self._buf.split(b"\n") if line.strip()]

    def clear(self) -> None:
        self._buf = b""


class SlowController:
    """Duck-typed ClosedLoopController stub that sleeps before returning,
    so tests can observe ActExecutor's busy state mid-execution."""

    def __init__(self, delay: float, result) -> None:
        self._delay = delay
        self._result = result

    def execute(self, buttons):
        time.sleep(self._delay)
        return self._result


def feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


def _make_executor(
    reader: asyncio.StreamReader,
    writer: FakeWriter,
    *,
    verifier_outcomes: list[bool] | None = None,
) -> ActExecutor:
    outcomes = verifier_outcomes if verifier_outcomes is not None else [True] * 50
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=MockVerifier(outcomes=outcomes),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    return ActExecutor(reader=reader, writer=writer, controller=controller)


def run(coro):
    return asyncio.run(coro)


# ── parse_act_message ────────────────────────────────────────────────────────

def test_parse_execute_with_valid_fields():
    msg = parse_act_message(
        json.dumps({"type": "execute", "sequence_id": "seq-1", "buttons": ["BT-01", "BT-05"]})
    )
    assert msg is not None
    assert msg.sequence_id == "seq-1"
    assert msg.buttons == ("BT-01", "BT-05")


def test_parse_execute_with_empty_buttons_is_invalid():
    msg = parse_act_message(
        json.dumps({"type": "execute", "sequence_id": "seq-1", "buttons": []})
    )
    assert msg is None


def test_parse_execute_with_missing_sequence_id_is_invalid():
    msg = parse_act_message(json.dumps({"type": "execute", "buttons": ["BT-01"]}))
    assert msg is None


def test_parse_abort():
    from rpi4.models.act_messages import AbortMsg
    assert parse_act_message(json.dumps({"type": "abort"})) == AbortMsg()


def test_parse_unknown_type_returns_none():
    assert parse_act_message(json.dumps({"type": "future_type"})) is None


def test_parse_malformed_json_returns_none():
    assert parse_act_message("not json") is None


# ── ActExecutor ──────────────────────────────────────────────────────────────

def test_execute_succeeds_on_first_attempt_reports_success_with_no_retry():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        feed(reader, {"type": "execute", "sequence_id": "seq-1", "buttons": ["시작"]})
        await executor.run_once()

        msgs = writer.messages()
        assert len(msgs) == 1
        assert msgs[0] == {"type": "result", "sequence_id": "seq-1", "success": True, "retry": 0}
    run(_t())


def test_execute_with_retries_reports_success_with_retry_count():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        # Fails twice, then succeeds — 3 attempts, 2 retries.
        executor = _make_executor(reader, writer, verifier_outcomes=[False, False, True])

        feed(reader, {"type": "execute", "sequence_id": "seq-2", "buttons": ["시작"]})
        await executor.run_once()

        msgs = writer.messages()
        assert msgs[0]["success"] is True
        assert msgs[0]["retry"] == 2
    run(_t())


def test_execute_exhausting_retries_reports_failure():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer, verifier_outcomes=[False] * 20)

        feed(reader, {"type": "execute", "sequence_id": "seq-3", "buttons": ["시작"]})
        await executor.run_once()

        msgs = writer.messages()
        assert msgs[0]["type"] == "result"
        assert msgs[0]["sequence_id"] == "seq-3"
        assert msgs[0]["success"] is False
    run(_t())


def test_controller_exception_reports_error_actuator_fail():
    async def _t():
        class ExplodingController:
            def execute(self, buttons):
                raise RuntimeError("boom")

        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = ActExecutor(reader=reader, writer=writer, controller=ExplodingController())

        feed(reader, {"type": "execute", "sequence_id": "seq-4", "buttons": ["시작"]})
        await executor.run_once()

        msgs = writer.messages()
        assert msgs == [{"type": "error", "sequence_id": "seq-4", "reason": "actuator_fail"}]
    run(_t())


def test_second_execute_while_busy_is_rejected():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus

        slow_result = ExecutionResult(
            status=ExecutionStatus.SUCCEEDED,
            buttons=(ButtonResult("시작", ButtonStatus.SUCCEEDED, 1, None),),
        )
        executor = ActExecutor(
            reader=reader, writer=writer, controller=SlowController(0.2, slow_result)
        )

        feed(reader, {"type": "execute", "sequence_id": "first", "buttons": ["시작"]})
        first = asyncio.create_task(executor.run_once())
        await asyncio.sleep(0.05)  # let the first execute claim the busy flag

        feed(reader, {"type": "execute", "sequence_id": "second", "buttons": ["시작"]})
        await executor.run_once()  # the second call — should see busy=True

        await first

        msgs = writer.messages()
        assert {"type": "error", "sequence_id": "second", "reason": "busy"} in msgs
        assert {"type": "result", "sequence_id": "first", "success": True, "retry": 0} in msgs
    run(_t())


def test_abort_while_idle_produces_no_response_and_no_crash():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        feed(reader, {"type": "abort"})
        await executor.run_once()

        assert writer.messages() == []
    run(_t())


def test_abort_while_busy_does_not_interrupt_execution():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus

        slow_result = ExecutionResult(
            status=ExecutionStatus.SUCCEEDED,
            buttons=(ButtonResult("시작", ButtonStatus.SUCCEEDED, 1, None),),
        )
        executor = ActExecutor(
            reader=reader, writer=writer, controller=SlowController(0.2, slow_result)
        )

        feed(reader, {"type": "execute", "sequence_id": "seq-5", "buttons": ["시작"]})
        first = asyncio.create_task(executor.run_once())
        await asyncio.sleep(0.05)

        feed(reader, {"type": "abort"})
        await executor.run_once()  # abort — should just log, no message

        await first

        msgs = writer.messages()
        assert msgs == [{"type": "result", "sequence_id": "seq-5", "success": True, "retry": 0}]
    run(_t())


def test_malformed_json_produces_no_response_and_no_crash():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)
        reader.feed_data(b"this is not json\n")
        await executor.run_once()
        assert writer.messages() == []
    run(_t())


# ── report_danger_sound (self-initiated alert) ──────────────────────────────

def _not_detected(ratio: float = 0.1) -> DangerSoundResult:
    return DangerSoundResult(detected=False, band_energy_ratio=ratio, cycle_count=1)


def _detected(ratio: float = 0.8, period: float = 0.4, cycles: int = 6) -> DangerSoundResult:
    return DangerSoundResult(
        detected=True, band_energy_ratio=ratio, cycle_count=cycles, mean_period_seconds=period
    )


def test_danger_sound_alert_raised_on_detection_edge():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        await executor.report_danger_sound(_detected(ratio=0.77, period=0.42))

        msgs = writer.messages()
        assert msgs == [{
            "type": "alert",
            "kind": "danger_sound",
            "band_energy_ratio": 0.77,
            "mean_period_seconds": 0.42,
        }]
    run(_t())


def test_danger_sound_not_detected_produces_no_message():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        await executor.report_danger_sound(_not_detected())

        assert writer.messages() == []
    run(_t())


def test_danger_sound_alert_not_resent_while_still_detected():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        await executor.report_danger_sound(_detected())
        await executor.report_danger_sound(_detected())
        await executor.report_danger_sound(_detected())

        msgs = writer.messages()
        assert len(msgs) == 1  # only the first transition sends anything
    run(_t())


def test_danger_sound_alert_cleared_when_detection_stops():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        await executor.report_danger_sound(_detected())
        await executor.report_danger_sound(_not_detected())

        msgs = writer.messages()
        assert msgs[-1] == {"type": "alert_cleared", "kind": "danger_sound"}
        assert len(msgs) == 2
    run(_t())


def test_danger_sound_clear_not_resent_while_still_not_detected():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        await executor.report_danger_sound(_not_detected())
        await executor.report_danger_sound(_not_detected())

        assert writer.messages() == []  # never alerted, so nothing to clear either
    run(_t())


def test_danger_sound_alert_can_raise_again_after_clearing():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        await executor.report_danger_sound(_detected())
        await executor.report_danger_sound(_not_detected())
        await executor.report_danger_sound(_detected())

        msgs = writer.messages()
        assert [m["type"] for m in msgs] == ["alert", "alert_cleared", "alert"]
    run(_t())


def test_danger_sound_alert_interleaves_safely_with_execute_result():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        feed(reader, {"type": "execute", "sequence_id": "seq-danger", "buttons": ["시작"]})
        exec_task = asyncio.create_task(executor.run_once())
        alert_task = asyncio.create_task(executor.report_danger_sound(_detected()))
        await asyncio.gather(exec_task, alert_task)

        msgs = writer.messages()
        assert {"type": "alert", "kind": "danger_sound", "band_energy_ratio": 0.8,
                "mean_period_seconds": 0.4} in msgs
        assert {"type": "result", "sequence_id": "seq-danger", "success": True, "retry": 0} in msgs
        assert len(msgs) == 2  # both lines arrived intact, no interleaved/corrupted JSON
    run(_t())


def test_abort_while_busy_requests_cooperative_stop():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus

        slow_result = ExecutionResult(
            status=ExecutionStatus.SUCCEEDED,
            buttons=(ButtonResult("시작", ButtonStatus.SUCCEEDED, 1, None),),
        )

        class StoppableSlowController(SlowController):
            def __init__(self, delay, result):
                super().__init__(delay, result)
                self.stop_requested = False

            def request_stop(self):
                self.stop_requested = True

        controller = StoppableSlowController(0.2, slow_result)
        executor = ActExecutor(reader=reader, writer=writer, controller=controller)

        feed(reader, {"type": "execute", "sequence_id": "seq-9", "buttons": ["시작"]})
        first = asyncio.create_task(executor.run_once())
        await asyncio.sleep(0.05)

        feed(reader, {"type": "abort"})
        await executor.run_once()

        # 실행 도중 abort → 컨트롤러에 협조적 정지가 전달된다
        assert controller.stop_requested is True

        await first
    run(_t())
