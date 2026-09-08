"""B1 — 사용 이력이 '어떤 가전에서' 했는지까지 기록한다.

지금까지 이력에는 목적과 결과만 남았다. 그래서 패턴 제안은 자기 대상 가전을
모르고, 화면이 현재 선택 가전으로 폴백해 그렸다. 가전 한 대만 쓸 때는 대개
맞지만, 전자레인지와 에어컨을 함께 쓰기 시작하면 "저녁마다 하던 그것"이
엉뚱한 가전의 버튼 지도를 달고 나온다.

여기서 확인하는 것은 그 사슬 전체다: 실행 → 이력 → 패턴 후보 → 제안 →
승인 실행 대상. 중간 어느 고리가 끊겨도 화면과 실제 조작이 어긋난다.
"""

from datetime import datetime, time, timedelta, timezone
from time import sleep

from rpi.api.service import SimpleLayService
from rpi.intent import (
    InMemoryUsageLog,
    PatternConfig,
    PatternDetector,
    ProactiveSuggestionService,
    RuleBasedIntentResolver,
    TimeBand,
    UsageOutcome,
    UsageRecord,
)
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.controller import ClosedLoopController
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.verifier import MockVerifier
from rpi.services.persistence import SimpleLayDb, SqliteUsageLog

KST = timezone(timedelta(hours=9))

_MORNING = TimeBand("아침", time(6, 0), time(10, 0))


def _at(day: int, hour: int = 8) -> datetime:
    return datetime(2026, 7, day, hour, 0, tzinfo=KST)


def _detector(records, *, now=_at(23)) -> PatternDetector:
    return PatternDetector(
        InMemoryUsageLog(tuple(records)),
        FixedClock(now),
        PatternConfig(minimum_occurrences=3, time_bands=(_MORNING,)),
    )


# ── 기록 경로: 실행이 대상 가전을 이력에 남긴다 ──────────────────────────


def _service(usage_log, clock):
    return SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(),
            MockVerifier([True] * 10),
            MockAlertSink(),
            MockSafetyController(),
            retry_waiter=MockRetryWaiter(),
        ),
        usage_log=usage_log,
        clock=clock,
    )


def test_execute_records_the_appliance_it_ran_on():
    log = InMemoryUsageLog()
    svc = _service(log, FixedClock(_at(23)))

    svc.execute_purpose("우유 데워줘", appliance_id="microwave")

    (record,) = log.records()
    assert record.appliance_id == "microwave"


def test_async_job_records_the_appliance():
    """비동기 job 경로는 실행이 별도 스레드로 넘어간다 — 그 사이 대상이
    유실되지 않는지가 핵심(스레드 인자로 같이 넘어가야 한다)."""
    log = InMemoryUsageLog()
    svc = _service(log, FixedClock(_at(23)))

    job_id = svc.submit_purpose("우유 데워줘", appliance_id="microwave")
    assert job_id
    for _ in range(200):
        if log.records():
            break
        sleep(0.01)

    (record,) = log.records()
    assert record.appliance_id == "microwave"


def test_direct_button_run_still_stays_out_of_the_usage_log():
    """가전을 알게 됐다고 해서 목적 없는 버튼 실행까지 학습하지는 않는다 —
    패턴 제안은 되풀이 가능한 '말'을 전제로 한다."""
    log = InMemoryUsageLog()
    svc = _service(log, FixedClock(_at(23)))

    svc.execute_buttons(("해동",), appliance_id="microwave")

    assert log.records() == ()


# ── 패턴 후보: 최근 실행한 가전을 물고 온다 ──────────────────────────────


def test_candidate_carries_the_appliance():
    candidates = _detector(
        UsageRecord(_at(d), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave")
        for d in (20, 21, 22)
    ).candidates()

    assert [c.appliance_id for c in candidates] == ["microwave"]


def test_candidate_without_appliance_history_stays_none():
    """가전이 기록되기 전에 쌓인 이력만 있으면 대상을 지어내지 않는다 —
    None이어야 클라이언트가 현재 선택 가전으로 폴백할 수 있다."""
    candidates = _detector(
        UsageRecord(_at(d), "우유 데워줘", UsageOutcome.SUCCEEDED)
        for d in (20, 21, 22)
    ).candidates()

    assert [c.appliance_id for c in candidates] == [None]


def test_candidate_prefers_the_most_recent_appliance():
    """같은 루틴을 다른 가전으로 옮겨 쓰기 시작했다면 사용자가 뜻하는 대상은
    최신 쪽이다 — 옛 기록이 많다고 그쪽으로 끌려가면 안 된다."""
    candidates = _detector(
        [
            UsageRecord(_at(20), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave"),
            UsageRecord(_at(21), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave"),
            UsageRecord(_at(22), "우유 데워줘", UsageOutcome.SUCCEEDED, "kettle"),
        ]
    ).candidates()

    assert [c.appliance_id for c in candidates] == ["kettle"]


def test_candidate_ignores_appliance_of_failed_runs():
    """실패한 실행은 횟수에서도 빠지므로 대상 추정에도 쓰이면 안 된다."""
    candidates = _detector(
        [
            UsageRecord(_at(20), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave"),
            UsageRecord(_at(21), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave"),
            UsageRecord(_at(22), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave"),
            UsageRecord(_at(23), "우유 데워줘", UsageOutcome.FAILED, "kettle"),
        ]
    ).candidates()

    assert [c.appliance_id for c in candidates] == ["microwave"]


def test_separate_appliances_keep_separate_targets():
    """가전 두 대를 함께 쓰는 상황 — B1이 실제로 열어주는 데모다."""
    candidates = _detector(
        [
            UsageRecord(_at(d), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave")
            for d in (20, 21, 22)
        ]
        + [
            UsageRecord(_at(d), "에어컨 켜줘", UsageOutcome.SUCCEEDED, "aircon")
            for d in (20, 21, 22)
        ]
    ).candidates()

    assert {c.purpose: c.appliance_id for c in candidates} == {
        "우유 데워줘": "microwave",
        "에어컨 켜줘": "aircon",
    }


# ── 제안까지: 화면이 보여줄 대상과 실제 실행 대상이 같다 ─────────────────


def _suggestion_service(records, executor):
    return ProactiveSuggestionService(
        _detector(records),
        FixedClock(_at(23)),
        executor,
        intent_resolver=RuleBasedIntentResolver(),
    )


def test_pattern_suggestion_carries_and_executes_on_that_appliance():
    executor = MockPurposeExecutor()
    svc = _suggestion_service(
        [
            UsageRecord(_at(d), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave")
            for d in (20, 21, 22)
        ],
        executor,
    )

    (suggestion,) = svc.create_suggestions()
    assert suggestion.appliance_id == "microwave"

    svc.approve(suggestion.suggestion_id)
    assert executor.appliance_ids == ["microwave"]


def test_demo_suggestion_can_name_its_appliance():
    """데모 트리거로도 대상을 못 박을 수 있어야 여러 가전을 번갈아 보여준다."""
    svc = _suggestion_service((), MockPurposeExecutor())

    suggestion = svc.create_demo_suggestion("에어컨 켜줘", appliance_id="aircon")

    assert suggestion is not None
    assert suggestion.appliance_id == "aircon"


# ── 영속화: 재시작해도 대상이 남고, 옛 DB도 그대로 열린다 ────────────────


def test_sqlite_round_trips_the_appliance(tmp_path):
    db = SimpleLayDb(str(tmp_path / "s.db"))
    log = SqliteUsageLog(db)

    log.append(
        UsageRecord(_at(23), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave")
    )
    db.close()

    reopened = SimpleLayDb(str(tmp_path / "s.db"))
    try:
        (record,) = SqliteUsageLog(reopened).records()
        assert record.appliance_id == "microwave"
    finally:
        reopened.close()


def test_existing_db_without_the_column_is_migrated(tmp_path):
    """실기기에는 이미 이력이 쌓인 DB가 깔려 있다. CREATE TABLE IF NOT EXISTS는
    기존 테이블을 손대지 않으므로, 열 추가가 없으면 그 DB는 열자마자 깨진다.
    파일을 지우게 하면 학습 이력이 날아가므로 ALTER로 이어 붙인다."""
    import sqlite3

    path = str(tmp_path / "old.db")
    old = sqlite3.connect(path)
    old.executescript(
        """
        CREATE TABLE usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            occurred_at TEXT NOT NULL,
            purpose TEXT NOT NULL,
            outcome TEXT NOT NULL
        );
        """
    )
    old.execute(
        "INSERT INTO usage_log (occurred_at, purpose, outcome) VALUES (?, ?, ?)",
        (_at(20).isoformat(), "우유 데워줘", "succeeded"),
    )
    old.commit()
    old.close()

    db = SimpleLayDb(path)
    try:
        log = SqliteUsageLog(db)
        # 옛 행은 대상 없이 살아남고,
        (migrated,) = log.records()
        assert migrated.purpose == "우유 데워줘"
        assert migrated.appliance_id is None
        # 새 행부터 대상이 붙는다.
        log.append(
            UsageRecord(_at(23), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave")
        )
        assert [r.appliance_id for r in log.records()] == [None, "microwave"]
    finally:
        db.close()
