"""제안 억제(다시 추천 안 함) — 스토어·영속화·서비스 필터."""

from datetime import datetime, time, timedelta, timezone

from rpi.intent.models import ExecutionMode, UsageSource

from rpi.intent import (
    InMemoryUsageLog,
    PatternConfig,
    PatternDetector,
    ProactiveSuggestionService,
    TimeBand,
    UsageOutcome,
    UsageRecord,
)
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.suppression import InMemorySuppressionStore
from rpi.services.persistence import SimpleLayDb, SqliteSuppressionStore

KST = timezone(timedelta(hours=9))
MORNING = TimeBand("아침", time(6, 0), time(10, 0))
CONFIG = PatternConfig(minimum_occurrences=3, time_bands=(MORNING,))


def _at_morning(day: int) -> datetime:
    return datetime(2026, 7, day, 8, 0, tzinfo=KST)


def _three(purpose: str) -> tuple[UsageRecord, ...]:
    return tuple(
        UsageRecord(_at_morning(d), purpose, UsageOutcome.SUCCEEDED, execution_mode=ExecutionMode.REAL, source=UsageSource.DIRECT)
        for d in (20, 21, 22)
    )


def _service(store=None, records=()):
    clock = FixedClock(_at_morning(23))
    detector = PatternDetector(InMemoryUsageLog(records), clock, CONFIG)
    return ProactiveSuggestionService(
        detector, clock, MockPurposeExecutor(), suppression_store=store
    )


# ── 스토어 ────────────────────────────────────────────────────────────────


def test_inmemory_mute_unmute_strips():
    s = InMemorySuppressionStore()
    assert s.muted() == frozenset()
    s.mute("  즉석밥 데워줘 ")
    assert s.muted() == frozenset({"즉석밥 데워줘"})
    s.unmute("즉석밥 데워줘")
    assert s.muted() == frozenset()


def test_sqlite_suppression_persists(tmp_path):
    path = str(tmp_path / "s.db")
    db = SimpleLayDb(path)
    SqliteSuppressionStore(db).mute("라면 끓여줘")
    db.close()
    # 재오픈 후에도 남아 있다
    reopened = SqliteSuppressionStore(SimpleLayDb(path))
    assert "라면 끓여줘" in reopened.muted()


# ── 서비스 필터 ──────────────────────────────────────────────────────────


def test_muted_routine_is_not_suggested():
    store = InMemorySuppressionStore()
    store.mute("즉석밥 데워줘")
    assert _service(store, _three("즉석밥 데워줘")).create_suggestions() == ()
    # 억제 안 된 같은 이력은 정상 제안
    assert len(_service(InMemorySuppressionStore(), _three("즉석밥 데워줘")).create_suggestions()) == 1


def test_reject_with_mute_suppresses_future():
    store = InMemorySuppressionStore()
    svc = _service(store, _three("즉석밥 데워줘"))
    (sug,) = svc.create_suggestions()
    svc.reject(sug.suggestion_id, mute=True)
    assert "즉석밥 데워줘" in store.muted()
    # 이력이 그대로여도 다시 만들어지지 않는다 (원래 문제의 해결)
    assert svc.create_suggestions() == ()


def test_reject_without_mute_waits_until_next_band():
    store = InMemorySuppressionStore()
    svc = _service(store, _three("즉석밥 데워줘"))
    (sug,) = svc.create_suggestions()
    svc.reject(sug.suggestion_id)  # 이번만 넘기기
    assert store.muted() == frozenset()
    assert svc.create_suggestions() == ()  # 영구 억제는 아니지만 같은 시간대에는 쉬기


def test_muted_purposes_sorted_and_unmute():
    store = InMemorySuppressionStore()
    svc = _service(store)
    store.mute("라면 끓여줘")
    store.mute("해동해줘")
    assert svc.muted_purposes() == ("라면 끓여줘", "해동해줘")
    svc.unmute("라면 끓여줘")
    assert svc.muted_purposes() == ("해동해줘",)
