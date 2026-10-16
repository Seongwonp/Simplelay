"""실행 이력 — 저장소 계약·재시작 복원·서비스 기록 검증."""
from rpi.services.appliance_registry import ApplianceRegistry


from datetime import datetime, timezone

from rpi.controller import ClosedLoopController
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.api.service import SimpleLayService
from rpi.intent import RuleBasedIntentResolver
from rpi.services.history import ButtonAttempt, InMemoryJobHistory, JobHistoryEntry
from rpi.services.persistence import SimpleLayDb, SqliteJobHistory
from rpi.verifier import MockVerifier


def _entry(job_id="job-1", purpose="즉석밥 데워줘", attempts=(1, 2)):
    return JobHistoryEntry(
        job_id=job_id,
        finished_at=datetime(2026, 8, 23, 19, 0, tzinfo=timezone.utc),
        purpose=purpose,
        status="succeeded",
        buttons=tuple(
            ButtonAttempt(f"버튼{i}", True, a) for i, a in enumerate(attempts)
        ),
    )


def test_retry_count_sums_extra_attempts():
    # attempts (1, 3) → 재시도 0 + 2 = 2회
    assert _entry(attempts=(1, 3)).retry_count == 2
    assert _entry(attempts=(1, 1)).retry_count == 0


def test_in_memory_recent_is_newest_first_and_limited():
    store = InMemoryJobHistory(max_entries=3)
    for i in range(5):
        store.append(_entry(job_id=f"job-{i}"))

    recent = store.recent(limit=2)

    assert [e.job_id for e in recent] == ["job-4", "job-3"]
    # maxlen 초과분은 오래된 것부터 버려진다
    assert [e.job_id for e in store.recent(limit=10)] == ["job-4", "job-3", "job-2"]


def test_sqlite_history_survives_reopen(tmp_path):
    path = str(tmp_path / "simplelay.db")
    SqliteJobHistory(SimpleLayDb(path)).append(_entry())

    reopened = SqliteJobHistory(SimpleLayDb(path))
    recent = reopened.recent()

    assert len(recent) == 1
    entry = recent[0]
    assert entry.purpose == "즉석밥 데워줘"
    assert entry.status == "succeeded"
    assert entry.finished_at.tzinfo is not None
    assert [(b.button, b.success, b.attempts) for b in entry.buttons] == [
        ("버튼0", True, 1),
        ("버튼1", True, 2),
    ]
    assert entry.retry_count == 1


def test_service_records_history_with_retry_counts():
    # 두 번째 버튼이 1차 검증 실패 → 재시도 성공하는 시나리오
    controller = ClosedLoopController(
        MockGrblClient(),
        MockVerifier([True, False, True]),
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
    )
    store = InMemoryJobHistory()
    service = SimpleLayService(
        RuleBasedIntentResolver({"테스트": ("시작", "10초")}),
        controller,
        history_store=store, appliance_registry=ApplianceRegistry(),
    )

    service.execute_purpose("테스트")

    (entry,) = store.recent()
    assert entry.purpose == "테스트"
    assert entry.status == "succeeded"
    assert entry.retry_count == 1  # 폐루프가 1회 재시도로 회복했다는 기록
    assert entry.buttons[1].attempts == 2


def test_service_without_store_does_not_crash():
    controller = ClosedLoopController(
        MockGrblClient(),
        MockVerifier([True]),
        MockAlertSink(),
        MockSafetyController(),
    )
    service = SimpleLayService(
        RuleBasedIntentResolver({"테스트": ("전원",)}), controller
    )
    result = service.execute_purpose("테스트")
    assert result.status.value == "succeeded"
