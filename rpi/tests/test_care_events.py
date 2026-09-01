"""보호자 알림 + 안부 신호 — 저장소·배선·감지 규칙 계약.

실패·위험소리·긴급정지는 키오스크(가전 옆)에만 표시됐다 — 정작 걱정하는
보호자는 밖에 있다. 안부 신호는 실제 고독사 예방 서비스(스마트플러그류)와
같은 원리를 usage_log로 구현한 것: 전부 설명 가능한 임계값, AI 아님.
"""

from datetime import datetime, time, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import (
    InMemoryUsageLog,
    PatternConfig,
    RuleBasedIntentResolver,
    TimeBand,
    UsageOutcome,
    UsageRecord,
)
from rpi.intent.mock import FixedClock
from rpi.main import app
from rpi.services import CareEventStore, RoutineQuietChecker
from rpi.services.act_client import AlertEvent
from rpi.services.alert_store import DangerAlertStore
from rpi.services.persistence import SimpleLayDb
from rpi.verifier import MockVerifier

KST = timezone(timedelta(hours=9))
EVENING = TimeBand("저녁", time(17, 0), time(21, 0))
NIGHT = TimeBand("야간", time(21, 0), time(6, 0))  # 자정 걸침
CONFIG = PatternConfig(minimum_occurrences=3, time_bands=(EVENING, NIGHT))


def at(day: int, hour: int, minute: int = 0) -> datetime:
    return datetime(2026, 8, day, hour, minute, tzinfo=KST)


def make_store(clock=None, db=None) -> CareEventStore:
    return CareEventStore(clock or FixedClock(at(31, 22)), db=db)


# ── 저장소 ───────────────────────────────────────────────────────────────


def test_append_and_recent_newest_first():
    store = make_store()
    store.append("execution_failed", "첫 번째")
    store.append("danger_sound", "두 번째")

    events = store.recent()
    assert [e.message for e in events] == ["두 번째", "첫 번째"]
    assert events[0].event_id > events[1].event_id


def test_events_survive_restart(tmp_path):
    db_path = str(tmp_path / "care.db")
    store = make_store(db=SimpleLayDb(db_path))
    store.append("quiet_routine", "안부", purpose="우유 데워줘")

    reloaded = make_store(db=SimpleLayDb(db_path))
    events = reloaded.recent()
    assert len(events) == 1
    assert events[0].kind == "quiet_routine"
    assert events[0].purpose == "우유 데워줘"
    # 재시작 후 새 이벤트가 기존 id와 충돌하지 않는다
    new = reloaded.append("execution_failed", "이후")
    assert new.event_id > events[0].event_id


def test_has_on_date_dedupe_key():
    clock = FixedClock(at(31, 22))
    store = make_store(clock)
    store.append("quiet_routine", "안부", purpose="우유 데워줘")

    assert store.has_on_date("quiet_routine", "우유 데워줘", at(31, 22).date())
    assert not store.has_on_date("quiet_routine", "다른 루틴", at(31, 22).date())
    assert not store.has_on_date("quiet_routine", "우유 데워줘", at(30, 22).date())


# ── 실행 실패·긴급정지 배선 ──────────────────────────────────────────────


def _service(verifier_outcomes, care, clock=None):
    return SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(),
            MockVerifier(verifier_outcomes),
            MockAlertSink(),
            MockSafetyController(),
            retry_waiter=MockRetryWaiter(),
        ),
        clock=clock or FixedClock(at(31, 19)),
        care_events=care,
    )


def test_failed_execution_records_care_event():
    care = make_store()
    service = _service([False] * 20, care)

    service.execute_purpose("우유 데워줘")

    events = care.recent()
    assert len(events) == 1
    assert events[0].kind == "execution_failed"
    assert "우유 데워줘" in events[0].message


def test_successful_execution_records_nothing():
    care = make_store()
    _service([True] * 20, care).execute_purpose("우유 데워줘")

    assert care.recent() == ()


def test_emergency_stop_outcome_is_reported_as_stop_not_failure():
    # 사용자가 멈춘 것과 스스로 실패한 것은 보호자에게 전혀 다른 소식이다
    care = make_store()
    service = _service([False] * 20, care)

    # 실행 시작 표시 후 정지 요청이 온 상황을 재현
    service._begin_run(1, service._controller)
    service.emergency_stop()
    try:
        service._run_buttons(("시작",), service._controller, "우유 데워줘")
    finally:
        service._end_run()

    events = care.recent()
    assert len(events) == 1
    assert events[0].kind == "emergency_stop"
    assert "멈췄" in events[0].message


def test_buttons_only_run_uses_labels_in_message():
    care = make_store()
    service = _service([False] * 20, care)

    service.execute_buttons(("전원", "냉방", "시작"))

    assert "전원, 냉방 외 1개" in care.recent()[0].message


# ── 위험소리 배선 (rising edge) ──────────────────────────────────────────


def test_danger_sound_rising_edge_records_once():
    care = make_store()
    store = DangerAlertStore(FixedClock(at(31, 19)), care_events=care)

    raised = AlertEvent(kind="danger_sound", raised=True)
    store.record(raised)
    store.record(raised)  # 지속 중 반복 수신 — 추가 기록 없어야 함
    store.record(AlertEvent(kind="danger_sound", raised=False))
    store.record(raised)  # 해제 후 재발생 — 새 rising edge

    kinds = [e.kind for e in care.recent()]
    assert kinds == ["danger_sound", "danger_sound"]


# ── 안부 신호 (quiet_routine) ────────────────────────────────────────────


def _routine_records(purpose="우유 데워줘", days=(25, 26, 27)):
    return tuple(
        UsageRecord(at(day, 18), purpose, UsageOutcome.SUCCEEDED) for day in days
    )


def _checker(records, now, care=None):
    clock = FixedClock(now)
    care = care or CareEventStore(clock)
    return (
        RoutineQuietChecker(InMemoryUsageLog(records), clock, CONFIG, care),
        care,
    )


def test_quiet_routine_fires_after_band_ends_without_usage_today():
    checker, care = _checker(_routine_records(), now=at(31, 21, 30))

    created = checker.check()

    assert len(created) == 1
    event = created[0]
    assert event.kind == "quiet_routine"
    assert event.purpose == "우유 데워줘"
    assert "저녁" in event.message and "우유 데워줘" in event.message
    assert care.recent()[0] == event


def test_no_signal_when_used_today():
    records = _routine_records() + (
        UsageRecord(at(31, 18), "우유 데워줘", UsageOutcome.SUCCEEDED),
    )
    checker, _ = _checker(records, now=at(31, 21, 30))

    assert checker.check() == ()


def test_failed_attempt_today_still_counts_as_activity():
    # 시도 자체가 활동 신호 — 실패했어도 "조용함"은 아니다
    # (실패는 execution_failed 이벤트가 따로 알린다)
    records = _routine_records() + (
        UsageRecord(at(31, 18), "우유 데워줘", UsageOutcome.FAILED),
    )
    checker, _ = _checker(records, now=at(31, 21, 30))

    assert checker.check() == ()


def test_no_signal_before_band_ends():
    # 저녁(17~21) 진행 중(19시) — 아직 쓸 시간이 남았다
    checker, _ = _checker(_routine_records(), now=at(31, 19))

    assert checker.check() == ()


def test_no_signal_without_enough_routine_days():
    checker, _ = _checker(
        _routine_records(days=(26, 27)), now=at(31, 21, 30)
    )  # 2일뿐 — 루틴 아님

    assert checker.check() == ()


def test_same_day_repeat_checks_fire_only_once():
    # 60초 주기 루프가 하루 종일 불러도 알림은 1회
    checker, care = _checker(_routine_records(), now=at(31, 21, 30))

    checker.check()
    checker.check()
    checker.check()

    assert len(care.recent()) == 1


def test_overnight_band_is_excluded():
    # 야간(21~06) 루틴이 조용해도 새벽 안부 알림은 만들지 않는다
    records = tuple(
        UsageRecord(at(day, 22), "가습기 켜줘", UsageOutcome.SUCCEEDED)
        for day in (25, 26, 27)
    )
    checker, _ = _checker(records, now=at(31, 23))

    assert checker.check() == ()


def test_multiple_occurrences_same_day_count_as_one_routine_day():
    # 하루에 3번 쓴 것은 '3일 루틴'이 아니다 — 서로 다른 날짜 기준
    records = tuple(
        UsageRecord(at(27, 17, 30 + i), "우유 데워줘", UsageOutcome.SUCCEEDED)
        for i in range(3)
    )
    checker, _ = _checker(records, now=at(31, 21, 30))

    assert checker.check() == ()


# ── API ──────────────────────────────────────────────────────────────────


def test_get_care_events_endpoint(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    store = make_store()
    store.append("danger_sound", "위험 신호음", purpose=None)
    store.append("quiet_routine", "안부", purpose="우유 데워줘")
    app.dependency_overrides[deps.get_care_events] = lambda: store
    try:
        body = TestClient(app).get("/care-events").json()
    finally:
        app.dependency_overrides.pop(deps.get_care_events, None)

    assert [e["kind"] for e in body] == ["quiet_routine", "danger_sound"]
    assert body[0]["purpose"] == "우유 데워줘"
    assert {"id", "kind", "message", "occurred_at"} <= set(body[0].keys())


def test_demo_care_event_trigger(monkeypatch):
    # 리허설 장치 — 시연장에서 안부 신호 장면을 원하는 시점에 연출
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    store = make_store()
    app.dependency_overrides[deps.get_care_events] = lambda: store
    try:
        client = TestClient(app)
        res = client.post("/demo/care-event", json={"kind": "quiet_routine"})
        assert res.status_code == 200
        assert "안부 전화" in res.json()["message"]  # 기본 문구 채움

        assert client.post(
            "/demo/care-event", json={"kind": "no_such_kind"}
        ).status_code == 422
    finally:
        app.dependency_overrides.pop(deps.get_care_events, None)

    assert store.recent()[0].kind == "quiet_routine"
