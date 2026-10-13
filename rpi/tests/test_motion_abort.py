"""모션 걸림·재시작·기한 초과·준비 안 됨은 '눌림 확인 실패'가 아니다(2026-10-14, 보드 날 발견 2).

10/13 실물: 첫 이동에서 MCU ``stall`` 알람 → 폐루프가 어댑터 오류를 재시도할 오류로 보고 두 번 더 시도(움직이지 않고
바로 실패) → 결과 ``safety_stop``·attempts 3·원인 없음 → 화면은 "다시 눌러도 확인하지 못해 안전 정지". 원인이 바뀌어 보였다.

여기서는 가짜 MCU(메모리 파이프)·가짜 어댑터로만 본다. 실물 걸림 재현은 다음 보드 날.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from rpi.controller import ButtonTarget, ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockRetryWaiter, MockSafetyController
from rpi.controller.models import ExecutionMode, ExecutionOutcome, outcome_of
from rpi.controller.serial_motion import (
    InMemoryLinePipe,
    MotionAlarm,
    MotionNotReady,
    MotionReset,
    MotionSafetyController,
    MotionTimeout,
    SerialMotionClient,
)
from rpi.tests.test_serial_motion import TEST_CONFIG
from rpi.tools.fake_mcu import FakeMcu
from rpi.verifier import MockVerifier


class _RaisingGrbl:
    """누를 때마다 정해진 예외를 올리는 어댑터(실제 모션 어댑터 흉내)."""

    execution_mode = ExecutionMode.REAL

    def __init__(self, exc: Exception) -> None:
        self.exc = exc
        self.presses = 0

    def press(self, command) -> None:
        self.presses += 1
        raise self.exc


def _controller(grbl, safety=None):
    return ClosedLoopController(grbl, MockVerifier([True] * 10), MockAlertSink(), safety or MockSafetyController(),
                                retry_waiter=MockRetryWaiter())


@pytest.mark.parametrize(("exc", "reason"), [
    (MotionAlarm("MCU 알람: stall", reason="stall"), "motion_alarm: stall"),
    (MotionReset("'press' 도중 MCU가 재시작했습니다"), "motion_reset"),
    (MotionTimeout("'move' 응답이 1s 안에 오지 않았습니다"), "motion_timeout"),
    (MotionNotReady("원점 복귀가 확인되지 않았습니다"), "motion_not_ready"),
    (OSError(5, "Input/output error"), "motion_link_error"),
])
def test_motion_abort_is_not_retried_and_reports_cause_and_real_attempts(exc, reason):
    grbl = _RaisingGrbl(exc)
    safety = MockSafetyController()
    result = _controller(grbl, safety).execute(["즉석밥", "시작"])
    assert grbl.presses == 1  # 재시도하지 않는다
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert outcome_of(result) is ExecutionOutcome.SAFETY_STOP
    assert result.abort_reason == reason
    assert [(b.button, b.attempts) for b in result.buttons] == [("즉석밥", 1)]
    assert result.failed_layer is None  # 눌림(L1) 확인 실패가 아니다
    assert safety.reasons and reason in safety.reasons[-1]


def test_ordinary_adapter_error_still_retries_with_correction():
    grbl = _RaisingGrbl(RuntimeError("일시 오류"))
    result = _controller(grbl).execute(["시작"])
    assert grbl.presses == 3
    assert result.abort_reason is None


# ── 실제 모션 어댑터 + 가짜 MCU ──────────────────────────────────────────────


@pytest.fixture
def link():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    yield pipe, mcu
    mcu.close()


def _client(pipe, config=TEST_CONFIG):
    return SerialMotionClient(pipe.host, config, poll_s=0.01)


def _run(client, buttons=("즉석밥",)):
    controller = ClosedLoopController(client, MockVerifier([True] * 10), MockAlertSink(),
                                      MotionSafetyController(client), retry_waiter=MockRetryWaiter())
    targets = {b: ButtonTarget(10.0, 10.0) for b in buttons}
    return controller.execute(list(buttons), targets)


def test_stall_alarm_on_the_first_move_stops_after_one_move(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    mcu.handlers["move"] = lambda d: [{"event": "alarm", "reason": "stall"}]
    result = _run(client)
    assert mcu.cmds().count("move") == 1
    assert "press" not in mcu.cmds()
    assert result.abort_reason == "motion_alarm: stall"
    assert result.buttons[0].attempts == 1


def test_stall_error_reply_reports_the_mcu_code(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    mcu.handlers["move"] = lambda d: [{"id": d["id"], "ok": False, "error": "stall"}]
    result = _run(client)
    assert mcu.cmds().count("move") == 1
    assert result.abort_reason == "motion_alarm: stall"


def test_mcu_restart_mid_move_is_reported_as_reset(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    mcu.handlers["move"] = lambda d: [{"event": "ready", "fw": "t", "reset": "brownout"}]
    result = _run(client)
    assert mcu.cmds().count("move") == 1
    assert result.abort_reason == "motion_reset"


def test_move_deadline_is_reported_as_timeout(link):
    pipe, mcu = link
    client = _client(pipe, replace(TEST_CONFIG, move_timeout_s=0.05))
    client.home()
    mcu.handlers["move"] = lambda d: None
    result = _run(client)
    assert mcu.cmds().count("move") == 1
    assert result.abort_reason == "motion_timeout"


def test_unhomed_without_auto_home_is_not_ready(link):
    pipe, mcu = link
    client = _client(pipe)  # 원점 복귀 전
    result = _run(client)
    assert "move" not in mcu.cmds()
    assert result.abort_reason == "motion_not_ready"
    assert result.buttons[0].attempts == 1


# ── RPi4 결과 프레임 → RPi5 해석 → 상태·기록 ─────────────────────────────────


def test_rpi5_reads_the_abort_reason_from_the_result_frame():
    from rpi.services.act_client import parse_abort_reason
    from rpi.services.aggregate_result import synthesize_execution_result

    assert parse_abort_reason({"abort_reason": "motion_alarm: stall"}) == "motion_alarm: stall"
    assert parse_abort_reason({"abort_reason": "motion_reset"}) == "motion_reset"
    assert parse_abort_reason({}) is None
    assert parse_abort_reason({"abort_reason": "x" * 300}) is None
    assert parse_abort_reason({"abort_reason": "motion_alarm: <script>"}) is None
    assert parse_abort_reason({"abort_reason": 3}) is None
    result = synthesize_execution_result(["즉석밥", "시작"], False, 0, ExecutionOutcome.SAFETY_STOP,
                                         abort_reason="motion_alarm: stall")
    assert result.abort_reason == "motion_alarm: stall"
    assert result.status is ExecutionStatus.SAFETY_STOPPED


def test_service_status_and_history_carry_the_abort_reason(tmp_path):
    from rpi.api.router import result_detail_fields
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.history import InMemoryJobHistory, Termination
    from rpi.services.persistence import SimpleLayDb, SqliteJobHistory

    grbl = _RaisingGrbl(MotionAlarm("MCU 알람: stall", reason="stall"))
    store = InMemoryJobHistory()
    service = SimpleLayService(RuleBasedIntentResolver({"즉석밥 데워줘": ("즉석밥", "시작")}),
                               _controller(grbl), history_store=store)
    service.execute_purpose("즉석밥 데워줘")
    fields = result_detail_fields(service.status().last_result)
    assert fields["last_abort_reason"] == "motion_alarm: stall"
    assert fields["last_retry_count"] == 0
    (entry,) = store.recent()
    assert entry.abort_reason == "motion_alarm: stall"
    assert entry.termination is not Termination.RETRIES_EXHAUSTED  # '다시 눌러도 확인 못 함'이 아니다
    assert [b.attempts for b in entry.buttons] == [1]

    sqlite = SqliteJobHistory(SimpleLayDb(str(tmp_path / "h.db")))
    sqlite.append(entry)
    assert sqlite.recent()[0].abort_reason == "motion_alarm: stall"


def test_history_api_exposes_the_abort_reason():
    from fastapi.testclient import TestClient

    from rpi.api import deps
    from rpi.main import app
    from rpi.services.history import JobHistoryEntry, Termination
    from datetime import datetime, timezone

    deps.get_job_history.cache_clear()
    try:
        deps.get_job_history().append(JobHistoryEntry(
            job_id="j-abort", finished_at=datetime(2026, 10, 14, tzinfo=timezone.utc), purpose="즉석밥 데워줘",
            status="safety_stopped", buttons=(), termination=Termination.MOTION_ABORTED,
            outcome="safety_stop", abort_reason="motion_alarm: stall",
        ))
        body = TestClient(app).get("/history").json()
        row = next(r for r in body if r["job_id"] == "j-abort")
        assert row["abort_reason"] == "motion_alarm: stall"
        assert row["termination"] == "motion_aborted"
    finally:
        deps.get_job_history.cache_clear()


def test_status_payload_defaults_to_null_abort_reason():
    from rpi.api.router import result_detail_fields

    assert result_detail_fields(None)["last_abort_reason"] is None
