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

    def messages(self, include_progress: bool = False) -> list[dict]:
        # 2026-09-30부터 누름마다 progress 프레임이 섞인다(선택·결과 아님). 이 파일의
        # 기존 시험은 결과·오류·경보 줄만 본다. progress는 test_act_progress.py가 본다.
        docs = [json.loads(line) for line in self._buf.split(b"\n") if line.strip()]
        return [d for d in docs if include_progress or d.get("type") != "progress"]

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



#: 2026-09-30 확장 필드(버튼별 보고·L3·실행 환경). 종전 핵심 필드만 비교하는 테스트용.
_EXTENDED_RESULT_KEYS = ("button_results", "operation_confirmed", "operation_detail",
                         "operation_source", "execution_mode")


def _core(msgs):
    return [
        {k: v for k, v in m.items() if k not in _EXTENDED_RESULT_KEYS}
        if m.get("type") == "result" else m
        for m in msgs
    ]


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
        await executor.wait_idle()

        msgs = _core(writer.messages())
        assert len(msgs) == 1
        assert msgs[0] == {"type": "result", "sequence_id": "seq-1", "success": True, "retry": 0, "outcome": "success"}
    run(_t())


def test_execute_with_retries_reports_success_with_retry_count():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        # Fails twice, then succeeds — 3 attempts, 2 retries.
        executor = _make_executor(reader, writer, verifier_outcomes=[False, False, True])

        feed(reader, {"type": "execute", "sequence_id": "seq-2", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()

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
        await executor.wait_idle()

        msgs = writer.messages()
        assert msgs[0]["type"] == "result"
        assert msgs[0]["sequence_id"] == "seq-3"
        assert msgs[0]["success"] is False
        # 재시도 소진은 스스로 멈춘 안전 정지 — 정지 요청과 다른 값으로 보낸다
        assert msgs[0]["outcome"] == "safety_stop"
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
        await executor.wait_idle()

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
        await executor.wait_idle()  # 첫 실행 task 완료 대기

        msgs = _core(writer.messages())
        assert {"type": "error", "sequence_id": "second", "reason": "busy"} in msgs
        assert {"type": "result", "sequence_id": "first", "success": True, "retry": 0, "outcome": "success"} in msgs
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
        await executor.wait_idle()

        msgs = _core(writer.messages())
        assert msgs == [{"type": "result", "sequence_id": "seq-5", "success": True, "retry": 0, "outcome": "success"}]
    run(_t())


def test_abort_mid_execution_stops_closed_loop_and_reports_safety_stopped():
    """리뷰 지적 #1 회귀 테스트 — 실행이 별도 task로 분리되어, 읽기 루프가
    실행 도중 도착한 abort를 즉시 읽고 폐루프를 실제로 멈춰야 한다."""
    async def _t():
        import time as _time

        from rpi.controller import ClosedLoopController
        from rpi.controller.mock import MockAlertSink, MockSafetyController
        from rpi.verifier import MockVerifier

        class SlowGrbl:
            def __init__(self):
                self.pressed = []

            def press(self, command):
                _time.sleep(0.05)  # 버튼 하나당 50ms — abort가 낄 시간
                self.pressed.append(command.button)

        grbl = SlowGrbl()
        controller = ClosedLoopController(
            grbl, MockVerifier([True] * 10), MockAlertSink(), MockSafetyController()
        )
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = ActExecutor(reader=reader, writer=writer, controller=controller)

        feed(reader, {
            "type": "execute", "sequence_id": "seq-stop",
            "buttons": ["b1", "b2", "b3", "b4", "b5"],
        })
        await executor.run_once()          # 실행 task 생성 후 즉시 반환
        await asyncio.sleep(0.08)          # 1~2번째 버튼 진행 중

        feed(reader, {"type": "abort"})
        await executor.run_once()          # ← 실행 '도중'에 abort가 읽힌다
        await executor.wait_idle()

        (msg,) = writer.messages()
        assert msg["type"] == "result"
        assert msg["sequence_id"] == "seq-stop"
        assert msg["success"] is False     # 옛 RPi5 호환: success는 그대로 false
        assert msg["outcome"] == "stopped" # 정지 요청으로 멈춤 — 실패와 구별된다
        assert len(grbl.pressed) < 5       # 나머지 버튼은 눌리지 않았다
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
        await executor.wait_idle()  # 실행 task의 result 전송까지 대기

        msgs = _core(writer.messages())
        assert {"type": "alert", "kind": "danger_sound", "band_energy_ratio": 0.8,
                "mean_period_seconds": 0.4} in msgs
        assert {"type": "result", "sequence_id": "seq-danger", "success": True, "retry": 0, "outcome": "success"} in msgs
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


# ── 종료 시 실제 정지 대기 (최종 교차 리뷰 중요) ─────────────────────────────

def test_shutdown_waits_for_the_execution_thread_to_actually_stop():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus

        finished = []

        class CooperativeController:
            """request_stop 후 잠시 뒤에야 반환하는 동기 컨트롤러 —
            to_thread 안의 실행이 강제 취소되지 않는 실제 상황."""

            def __init__(self) -> None:
                self.stop_requested = False

            def request_stop(self):
                self.stop_requested = True

            def execute(self, buttons):
                for _ in range(50):  # 협조적 정지 경계를 흉내
                    if self.stop_requested:
                        break
                    time.sleep(0.005)
                finished.append(True)
                return ExecutionResult(
                    status=ExecutionStatus.SAFETY_STOPPED,
                    buttons=(ButtonResult("시작", ButtonStatus.FAILED, 1, None),),
                )

        controller = CooperativeController()
        executor = ActExecutor(reader=reader, writer=writer, controller=controller)

        feed(reader, {"type": "execute", "sequence_id": "seq-s1", "buttons": ["시작"]})
        await executor.run_once()
        await asyncio.sleep(0.02)  # 실행 스레드 진입

        stopped_cleanly = await executor.shutdown(grace_seconds=2.0)

        assert controller.stop_requested is True
        assert stopped_cleanly is True
        # 핵심: 종료가 반환되기 전에 실행 스레드가 실제로 끝나 있어야 한다
        assert finished == [True]
    run(_t())


def test_shutdown_reports_false_when_execution_ignores_the_stop():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()

        class StubbornController:
            """정지를 무시하는 컨트롤러 — 소프트웨어가 더 할 게 없는 경우."""

            def request_stop(self):
                pass

            def execute(self, buttons):
                time.sleep(0.5)
                raise AssertionError("should not be awaited by the test")

        executor = ActExecutor(
            reader=reader, writer=writer, controller=StubbornController()
        )
        feed(reader, {"type": "execute", "sequence_id": "seq-s2", "buttons": ["시작"]})
        await executor.run_once()
        await asyncio.sleep(0.02)

        # 유예 시간을 넘기면 False — 물리 E-STOP이 최종 권한임을 알린다
        assert await executor.shutdown(grace_seconds=0.05) is False
    run(_t())


def test_shutdown_is_a_noop_when_idle():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)

        assert await executor.shutdown(grace_seconds=0.01) is True
    run(_t())


# ── inject_failure (리허설 실패 주입 — UART 경유, 교차 리뷰 #13) ──────────────

def test_parse_inject_failure():
    msg = parse_act_message(
        json.dumps({"type": "inject_failure", "button_index": 1, "attempts": 2})
    )
    assert msg is not None
    assert msg.button_index == 1
    assert msg.attempts == 2


def test_parse_inject_failure_rejects_out_of_range():
    for doc in (
        {"type": "inject_failure", "button_index": -1, "attempts": 1},
        {"type": "inject_failure", "button_index": 0, "attempts": 0},
        {"type": "inject_failure", "button_index": 0, "attempts": 11},
        {"type": "inject_failure", "button_index": "0", "attempts": 1},
        {"type": "inject_failure"},
    ):
        assert parse_act_message(json.dumps(doc)) is None, doc


def test_parse_clear_failure():
    from rpi4.models.act_messages import ClearFailureMsg

    assert parse_act_message(json.dumps({"type": "clear_failure"})) == ClearFailureMsg()


def _make_injectable_executor(reader, writer) -> ActExecutor:
    # act_main._build_executor()와 동일한 배선 — verifier 래핑과 executor가
    # 같은 DemoFailureState를 공유해야 무장이 실제 검증 실패로 이어진다
    from rpi.services.demo_failure import DemoFailureState, FailureInjectionVerifier

    state = DemoFailureState()
    controller = ClosedLoopController(
        grbl=MockGrblClient(),
        verifier=FailureInjectionVerifier(MockVerifier(outcomes=[True] * 50), state),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )
    return ActExecutor(
        reader=reader, writer=writer, controller=controller, failure_state=state
    )


def test_inject_failure_forces_retry_on_next_uart_execution():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_injectable_executor(reader, writer)

        # POST /demo/inject-failure → UART inject_failure → 다음 실행에서 발동
        feed(reader, {"type": "inject_failure", "button_index": 0, "attempts": 1})
        await executor.run_once()

        feed(reader, {"type": "execute", "sequence_id": "seq-f1", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()

        msgs = writer.messages()
        assert msgs[0]["success"] is True
        assert msgs[0]["retry"] == 1  # 주입 실패 1회 → 폐루프 재시도 → 성공

        # 1회용 — 다음 실행은 정상
        writer.clear()
        feed(reader, {"type": "execute", "sequence_id": "seq-f2", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()
        assert writer.messages()[0]["retry"] == 0
    run(_t())


def test_inject_failure_with_exhausting_attempts_reports_failure():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_injectable_executor(reader, writer)

        feed(reader, {"type": "inject_failure", "button_index": 0, "attempts": 3})
        await executor.run_once()
        feed(reader, {"type": "execute", "sequence_id": "seq-f3", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()

        assert writer.messages()[0]["success"] is False  # 재시도 소진 → 안전 정지
        assert writer.messages()[0]["outcome"] == "safety_stop"
    run(_t())


def test_clear_failure_disarms_before_execution():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_injectable_executor(reader, writer)

        feed(reader, {"type": "inject_failure", "button_index": 0, "attempts": 3})
        await executor.run_once()
        feed(reader, {"type": "clear_failure"})
        await executor.run_once()

        feed(reader, {"type": "execute", "sequence_id": "seq-f4", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()

        msgs = writer.messages()
        assert msgs[0]["success"] is True
        assert msgs[0]["retry"] == 0
    run(_t())


def test_inject_failure_without_wired_state_is_ignored():
    async def _t():
        reader = asyncio.StreamReader()
        writer = FakeWriter()
        executor = _make_executor(reader, writer)  # failure_state 없음

        feed(reader, {"type": "inject_failure", "button_index": 0, "attempts": 3})
        await executor.run_once()
        feed(reader, {"type": "execute", "sequence_id": "seq-f5", "buttons": ["시작"]})
        await executor.run_once()
        await executor.wait_idle()

        assert writer.messages()[0]["success"] is True  # 무시 — 정상 실행
    run(_t())
