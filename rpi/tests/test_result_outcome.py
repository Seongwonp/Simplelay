"""실행 종료 방식(outcome) — 정지 요청으로 멈춤과 실패를 끝까지 가른다.

결함(본선 준비 목록 P1): RPi4 → RPi5 ``result`` 프레임은 ``success=false`` 하나로
'정지 요청으로 멈춤'과 '검증 실패로 안전 정지'를 함께 보냈다. RPi5는 둘을 가를 수
없어 이력·/status·SSE가 같은 값만 보였다. 이제 프레임에 ``outcome``을 싣고
(``success`` | ``failed`` | ``stopped`` | ``safety_stop``), 필드가 없는 옛 프레임은
``success``에서 유도한다(실패는 ``failed`` — 정지로 추측하지 않는다).
"""

from __future__ import annotations

import asyncio
import json
import sqlite3
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import get_job_history, get_service
from rpi.api.router import status_event_payload
from rpi.api.service import SimpleLayService, StatusSnapshot
from rpi.commands import Command, CommandStatus, command_result_from_execution
from rpi.commands.physical import status_of
from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ClosedLoopController,
    ExecutionMode,
    ExecutionOutcome,
    ExecutionResult,
    ExecutionStatus,
    VerificationLayer,
    outcome_of,
)
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
from rpi.main import app
from rpi.services.act_client import ActClient, parse_result_outcome
from rpi.services.aggregate_result import synthesize_execution_result
from rpi.services.history import (
    ButtonAttempt,
    InMemoryJobHistory,
    JobHistoryEntry,
    Termination,
    history_csv,
)
from rpi.services.persistence import SimpleLayDb, SqliteJobHistory
from rpi.verifier import MockVerifier


def _ok(name: str) -> ButtonResult:
    return ButtonResult(name, ButtonStatus.SUCCEEDED, 1, None)


def _fail(name: str, attempts: int = 3) -> ButtonResult:
    return ButtonResult(name, ButtonStatus.FAILED, attempts, None)


# ── 로컬 폐루프 결과에서 유도 ────────────────────────────────────────────────


def test_local_outcome_success():
    r = ExecutionResult(ExecutionStatus.SUCCEEDED, (_ok("시작"),))
    assert outcome_of(r) is ExecutionOutcome.SUCCESS


def test_local_stop_without_failed_button_is_stopped():
    # 정지 요청으로 두 번째 버튼 전에 멈춤 — 실패한 버튼도 실패 층도 없다
    r = ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (_ok("즉석밥"),))
    assert outcome_of(r) is ExecutionOutcome.STOPPED


def test_local_retry_exhaustion_is_safety_stop():
    r = ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED,
        (_ok("즉석밥"), _fail("시작")),
        failed_layer=VerificationLayer.PRESS,
    )
    assert outcome_of(r) is ExecutionOutcome.SAFETY_STOP


def test_local_operation_unconfirmed_is_safety_stop():
    # L3 미확인·센서 불가: 버튼은 다 성공했지만 실패 층이 있다
    r = ExecutionResult(
        ExecutionStatus.SAFETY_STOPPED,
        (_ok("즉석밥"), _ok("시작")),
        failed_layer=VerificationLayer.OPERATION,
    )
    assert outcome_of(r) is ExecutionOutcome.SAFETY_STOP


def test_controller_exception_is_failed():
    assert outcome_of(ExecutionResult(ExecutionStatus.FAILED, ())) is ExecutionOutcome.FAILED


def test_real_closed_loop_stop_and_exhaustion_differ():
    stopped_loop = ClosedLoopController(
        MockGrblClient(), MockVerifier([True] * 5), MockAlertSink(), MockSafetyController()
    )
    stopped_loop.request_stop()
    assert outcome_of(stopped_loop.execute(["즉석밥", "시작"])) is ExecutionOutcome.STOPPED

    failing_loop = ClosedLoopController(
        MockGrblClient(), MockVerifier([False] * 20), MockAlertSink(), MockSafetyController()
    )
    assert outcome_of(failing_loop.execute(["시작"])) is ExecutionOutcome.SAFETY_STOP


# ── UART result 프레임 파싱(RPi5 쪽) ─────────────────────────────────────────


@pytest.mark.parametrize(
    ("doc", "success", "expected"),
    [
        ({"outcome": "stopped"}, False, "stopped"),
        ({"outcome": "safety_stop"}, False, "safety_stop"),
        ({"outcome": "failed"}, False, "failed"),
        ({"outcome": "success"}, True, "success"),
        ({}, False, None),  # 옛 RPi4 — 보고 없음
        ({"outcome": "exploded"}, False, None),  # 모르는 값
        ({"outcome": 3}, False, None),
        ({"outcome": "stopped"}, True, None),  # success와 모순 — 어느 쪽도 믿지 않음
        ({"outcome": "success"}, False, None),
    ],
)
def test_parse_result_outcome(doc, success, expected):
    assert parse_result_outcome(doc, success) == expected


class _FakeWriter:
    def __init__(self) -> None:
        self.lines: list[dict] = []

    def write(self, data: bytes) -> None:
        self.lines.extend(json.loads(x) for x in data.split(b"\n") if x.strip())

    async def drain(self) -> None:
        pass


def _client_result(frame: dict):
    async def _t():
        reader = asyncio.StreamReader()
        client = ActClient(reader, _FakeWriter())
        await client.start()
        task = asyncio.create_task(client.execute(["즉석밥", "시작"], sequence_id="s1", appliance_id="microwave"))
        await asyncio.sleep(0)
        reader.feed_data((json.dumps({"type": "result", "sequence_id": "s1", **frame}) + "\n").encode())
        result = await task
        await client.stop()
        return result

    return asyncio.run(_t())


def test_client_carries_reported_outcome():
    r = _client_result({"success": False, "retry": 0, "outcome": "stopped"})
    assert r.success is False and r.outcome == "stopped"


def test_client_legacy_frame_has_no_outcome():
    r = _client_result({"success": False, "retry": 2})
    assert r.success is False and r.outcome is None


# ── 집계 결과 합성 → 명령 상태·문구 ──────────────────────────────────────────


def test_legacy_failure_is_failed_not_guessed_as_stop():
    r = synthesize_execution_result(["즉석밥", "시작"], False, 2)
    assert r.status is ExecutionStatus.SAFETY_STOPPED  # 종전 status는 그대로
    assert outcome_of(r) is ExecutionOutcome.FAILED
    assert status_of(r) is CommandStatus.FAILED


def test_legacy_success_is_success():
    r = synthesize_execution_result(["시작"], True, 0)
    assert outcome_of(r) is ExecutionOutcome.SUCCESS


def test_reported_stop_becomes_stopped_command():
    r = synthesize_execution_result(["즉석밥", "시작"], False, 0, outcome=ExecutionOutcome.STOPPED)
    assert outcome_of(r) is ExecutionOutcome.STOPPED
    out = command_result_from_execution(
        Command.physical("microwave", ["즉석밥", "시작"]), r,
        execution_mode=ExecutionMode.UNKNOWN,
    )
    assert out.status is CommandStatus.STOPPED
    assert "작은 팔이 정지 요청으로 멈췄다고 알려 왔어요" in out.detail
    # 멈춘 버튼은 여전히 모른다 — 추정 버튼을 문구에 쓰지 않는다
    assert "'시작'" not in out.detail and "눌림 확인" not in out.detail


def test_reported_safety_stop_stays_a_failure():
    r = synthesize_execution_result(["시작"], False, 2, outcome=ExecutionOutcome.SAFETY_STOP)
    assert outcome_of(r) is ExecutionOutcome.SAFETY_STOP
    out = command_result_from_execution(
        Command.physical("microwave", ["시작"]), r, execution_mode=ExecutionMode.UNKNOWN
    )
    assert out.status is CommandStatus.FAILED
    assert "안전하게 멈췄다고 알려 왔어요" in out.detail and "재시도 2회" in out.detail


def test_contradictory_success_outcome_on_failure_is_failed():
    r = synthesize_execution_result(["시작"], False, 0, outcome=ExecutionOutcome.SUCCESS)
    assert outcome_of(r) is ExecutionOutcome.FAILED


# ── 서비스 이력·/status·SSE 노출 ─────────────────────────────────────────────


class _ScriptedController:
    execution_mode = ExecutionMode.UNKNOWN

    def __init__(self, result: ExecutionResult) -> None:
        self._result = result

    def execute(self, buttons):
        return self._result


def _run_service(result: ExecutionResult):
    store = InMemoryJobHistory()
    service = SimpleLayService(
        RuleBasedIntentResolver(), _ScriptedController(result), history_store=store
    )
    service.execute_buttons(("즉석밥", "시작"))
    return service, store


def test_service_history_records_remote_stop_and_failure_differently():
    stopped = synthesize_execution_result(["즉석밥", "시작"], False, 0, outcome=ExecutionOutcome.STOPPED)
    failed = synthesize_execution_result(["즉석밥", "시작"], False, 2, outcome=ExecutionOutcome.SAFETY_STOP)
    _, s_store = _run_service(stopped)
    _, f_store = _run_service(failed)
    (s_entry,) = s_store.recent()
    (f_entry,) = f_store.recent()
    # status는 종전대로 둘 다 safety_stopped — outcome만 다르다
    assert s_entry.status == f_entry.status == "safety_stopped"
    assert s_entry.outcome == "stopped"
    assert f_entry.outcome == "safety_stop"


def test_status_and_sse_expose_last_outcome():
    stopped = synthesize_execution_result(["즉석밥", "시작"], False, 0, outcome=ExecutionOutcome.STOPPED)
    service, _ = _run_service(stopped)

    assert status_event_payload(service)["last_outcome"] == "stopped"
    assert status_event_payload(service)["last_status"] == "safety_stopped"  # 옛 클라이언트용 유지

    app.dependency_overrides[get_service] = lambda: service
    try:
        body = TestClient(app, client=("127.0.0.1", 5000)).get("/status").json()
    finally:
        app.dependency_overrides.pop(get_service, None)
    assert body["last_status"] == "safety_stopped"
    assert body["last_outcome"] == "stopped"


def test_idle_status_has_no_outcome():
    snap = StatusSnapshot(running=False, ready=True, last_result=None)

    class _Svc:
        def status(self):
            return snap

    assert status_event_payload(_Svc())["last_outcome"] is None


def _entry(status: str, termination: Termination, outcome: str | None = None) -> JobHistoryEntry:
    return JobHistoryEntry(
        job_id="j",
        finished_at=datetime(2026, 9, 29, 10, 0, tzinfo=timezone.utc),
        purpose=None,
        status=status,
        buttons=(ButtonAttempt("시작", False, 3),),
        termination=termination,
        outcome=outcome,
    )


@pytest.mark.parametrize(
    ("status", "termination", "expected"),
    [
        ("succeeded", Termination.COMPLETED, "success"),
        ("safety_stopped", Termination.STOPPED_BY_USER, "stopped"),
        ("safety_stopped", Termination.RETRIES_EXHAUSTED, "safety_stop"),
        ("safety_stopped", Termination.UNKNOWN, "failed"),  # 근거 없이 정지로 적지 않는다
        ("failed", Termination.UNKNOWN, "failed"),
    ],
)
def test_old_history_entries_derive_outcome_conservatively(status, termination, expected):
    assert _entry(status, termination).effective_outcome == expected


def test_recorded_outcome_wins_over_derivation():
    e = _entry("safety_stopped", Termination.RETRIES_EXHAUSTED, outcome="stopped")
    assert e.effective_outcome == "stopped"


def test_history_endpoint_and_csv_carry_outcome():
    store = InMemoryJobHistory()
    store.append(_entry("safety_stopped", Termination.UNKNOWN, outcome="stopped"))
    app.dependency_overrides[get_job_history] = lambda: store
    try:
        body = TestClient(app, client=("127.0.0.1", 5000)).get("/history").json()
    finally:
        app.dependency_overrides.pop(get_job_history, None)
    assert body[0]["outcome"] == "stopped"
    header, row = history_csv(store.recent())[:-1].split("\n")
    assert header.split(",")[header.split(",").index("outcome")] == "outcome"
    assert row.split(",")[header.split(",").index("outcome")] == "stopped"


def test_sqlite_round_trip_and_old_table_migration(tmp_path):
    path = str(tmp_path / "old.db")
    # outcome 열이 생기기 전 스키마의 기존 DB — 파일을 지우지 않고 열을 더해야 한다
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE job_history (id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " job_id TEXT NOT NULL, finished_at TEXT NOT NULL, purpose TEXT,"
        " status TEXT NOT NULL, buttons_json TEXT NOT NULL)"
    )
    conn.execute(
        "INSERT INTO job_history (job_id, finished_at, purpose, status, buttons_json)"
        " VALUES ('old', '2026-09-01T10:00:00+00:00', NULL, 'safety_stopped', '[]')"
    )
    conn.commit()
    conn.close()

    store = SqliteJobHistory(SimpleLayDb(path))
    store.append(_entry("safety_stopped", Termination.STOPPED_BY_USER, outcome="stopped"))
    new, old = store.recent()
    assert new.outcome == "stopped"
    assert old.outcome is None and old.effective_outcome == "failed"
