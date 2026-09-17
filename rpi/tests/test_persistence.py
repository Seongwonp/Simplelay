"""SQLite 영속화 — 재시작(새 인스턴스) 후 상태 복원 계약 검증."""

from datetime import datetime, timezone

from rpi.intent.models import UsageOutcome, UsageRecord
from rpi.services.node_registry import NodeRegistry
from rpi.services.persistence import SimpleLayDb, SqliteUsageLog


def _record(purpose="즉석밥 데워줘", outcome=UsageOutcome.SUCCEEDED):
    return UsageRecord(
        datetime(2026, 8, 21, 19, 30, tzinfo=timezone.utc), purpose, outcome
    )


def test_usage_log_survives_reopen(tmp_path):
    path = str(tmp_path / "simplelay.db")

    log = SqliteUsageLog(SimpleLayDb(path))
    log.append(_record())
    log.append(_record(outcome=UsageOutcome.FAILED))

    # 서버 재시작 시뮬레이션 — 새 커넥션으로 다시 연다
    reopened = SqliteUsageLog(SimpleLayDb(path))
    records = reopened.records()

    assert len(records) == 2
    assert records[0].purpose == "즉석밥 데워줘"
    assert records[0].outcome is UsageOutcome.SUCCEEDED
    assert records[1].outcome is UsageOutcome.FAILED
    # timezone-aware가 보존돼야 패턴 감지의 시간대 판정이 안 깨진다
    assert records[0].occurred_at.tzinfo is not None
    assert records[0].occurred_at == _record().occurred_at


def test_node_registrations_survive_reopen(tmp_path):
    path = str(tmp_path / "simplelay.db")

    db = SimpleLayDb(path)
    registry = NodeRegistry(controller_factory=lambda url: object(), store=db)
    registry.register("에어컨", "http://192.168.0.50:8080")
    registry.register("인덕션", "http://192.168.0.51:8080")
    registry.register("에어컨", "http://192.168.0.99:8080")  # 재등록 = 교체
    registry.unregister("인덕션")

    restored = NodeRegistry(
        controller_factory=lambda url: object(), store=SimpleLayDb(path)
    )

    assert restored.list_appliance_ids() == ["에어컨"]
    assert restored.base_url("에어컨") == "http://192.168.0.99:8080"


def test_store_none_keeps_registry_in_memory_only(tmp_path):
    # store 없는 기존 사용처는 동작이 완전히 동일해야 한다
    registry = NodeRegistry(controller_factory=lambda url: object())
    registry.register("에어컨", "http://192.168.0.50:8080")
    assert registry.base_url("에어컨") == "http://192.168.0.50:8080"
