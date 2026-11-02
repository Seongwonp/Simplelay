"""앱·키오스크 없이 쓴 전자레인지를 CT로 안다 — 끝 프레임 → 사용 기록·알림·'알게 된 것'(rpi/services/observed_use.py).

합성 전력 곡선과 모의 저장소로만 시험했다. 실제 CT·RPi4 링크로 확인한 것이 아니다.
"""

from __future__ import annotations

from datetime import datetime, time, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.controller.models import ExecutionMode
from rpi.intent import InMemoryUsageLog, PatternConfig, PatternDetector, TimeBand
from rpi.intent.habit_words import duration_text
from rpi.intent.mock import FixedClock
from rpi.intent.models import UsageOutcome, UsageRecord, UsageSource
from rpi.main import app
from rpi.services import CareEventStore, RoutineQuietChecker
from rpi.services.appliance_done import parse_appliance_done
from rpi.services.appliance_registry import ApplianceCategory
from rpi.services.history import InMemoryJobHistory, JobHistoryEntry
from rpi.services.kit_binding import KitBound
from rpi.services.observed_use import HEAT_DONE_MESSAGE, OBSERVED_PURPOSE, ObservedUses
from rpi.services.persistence import SimpleLayDb, SqliteUsageLog
from rpi.verifier.cycle_end import CycleEndConfig
from rpi.verifier.done_fusion import DoneFusionConfig
from rpi.verifier.power import PowerSample
from rpi4.services.appliance_done_watch import ApplianceDoneWatch, DoneWatchSpec

KST = timezone(timedelta(hours=9))
NOW = datetime(2026, 11, 2, 19, 5, tzinfo=KST)  # 월요일
BAND = TimeBand("저녁", time(17), time(22))


def _frame(appliance_id="microwave", *, heat_s=60.0, source="real", gap=False, sent_after_s=0.0):
    """RPi4 관찰을 실제로 지나 나온 프레임 — 대기 → 시작 튐 → 가열 → 대기."""
    frames = []
    watch = ApplianceDoneWatch(DoneWatchSpec(appliance_id, ("power",)), frames.append,
                               cycle_config=CycleEndConfig.for_appliance("microwave", {}),
                               fusion_config=DoneFusionConfig.for_appliance("microwave", {}),
                               power_source=source, clock=lambda: 0.0)
    t = 1000.0
    for seconds, watts in ((2, 0.0), (0.2, 3550.0), (heat_s, 1000.0)):
        for _ in range(round(seconds * 10)):
            watch.feed_power(PowerSample(t, watts))
            t += 0.1
    if gap:
        watch.note_power_gap()
        t += 30.0
    for _ in range(40):
        watch.feed_power(PowerSample(t, 0.0))
        t += 0.1
    assert len(frames) == 1
    frame = frames[0]
    frame["t_monotonic_ns"] = int((frame["evidence"]["power"]["done_at_s"] + sent_after_s) * 1e9)
    checked = parse_appliance_done(frame)
    assert checked is not None
    return checked


class _Service:
    def __init__(self, bound=None, running=None):
        self.bound = bound or KitBound("microwave", True, False)
        self.running = running

    def kit_id(self):
        return "kit-1"

    def kit_bound(self, _kit_id):
        return self.bound

    def status(self):
        return SimpleNamespace(running=self.running is not None, appliance_id=self.running)


def _appliance(appliance_id, category):
    return SimpleNamespace(appliance_id=appliance_id, category=category)


_REGISTRY = {
    "microwave": _appliance("microwave", ApplianceCategory.MICROWAVE),
    "my_oven": _appliance("my_oven", ApplianceCategory.MICROWAVE),
    "my_fan": _appliance("my_fan", ApplianceCategory.AIR_PURIFIER),
}


def _setup(service=None, *jobs):
    clock = FixedClock(NOW)
    log = InMemoryUsageLog()
    care = CareEventStore(clock)
    history = InMemoryJobHistory()
    for job in jobs:
        history.append(job)
    registry = SimpleNamespace(get=_REGISTRY.get)
    uses = ObservedUses(usage_log=lambda: log, care_events=lambda: care, clock=clock,
                        service=lambda: service or _Service(), registry=lambda: registry, jobs=lambda: history)
    return uses, log, care


def _job(*, appliance="microwave", started_ago=70.0, finished_ago=68.0):
    return JobHistoryEntry("job", NOW - timedelta(seconds=finished_ago), "즉석밥 데워줘", "succeeded", (),
                           appliance_id=appliance, started_at=NOW - timedelta(seconds=started_ago))


def test_hand_use_is_recorded_with_start_and_duration_and_notice():
    uses, log, care = _setup()
    assert uses.on_done(_frame(sent_after_s=2.0)) == "recorded"
    [record] = log.records()
    assert record.purpose == OBSERVED_PURPOSE
    assert record.source is UsageSource.OBSERVED_POWER
    assert record.execution_mode is ExecutionMode.REAL and record.outcome is UsageOutcome.SUCCEEDED
    assert record.appliance_id == "microwave"
    assert record.duration_s == pytest.approx(60.2, abs=0.3)
    # 나이 = 가동 60.2 + 대기 확인 3 + 늦게 보낸 2
    assert (NOW - record.occurred_at).total_seconds() == pytest.approx(65.2, abs=0.4)
    [event] = care.recent()
    assert event.kind == "heat_done" and event.message == HEAT_DONE_MESSAGE == "가열이 끝났어요"


def test_notice_wording_does_not_claim_more_than_ct_knows():
    assert "조리" not in HEAT_DONE_MESSAGE and "완료" not in HEAT_DONE_MESSAGE
    assert OBSERVED_PURPOSE == "전자레인지 사용"  # 메뉴·버튼 이름이 없다


@pytest.mark.parametrize("job", [
    _job(),  # 누르고 바로 가열 시작
    _job(started_ago=90.0, finished_ago=78.0),  # 누름이 끝나고 10초 뒤 시작해도 같은 사용
    _job(started_ago=30.0, finished_ago=20.0),  # 가열 중 다른 조작(정지 누름)
])
def test_use_overlapping_a_job_is_not_counted_twice_but_notice_stays(job):
    uses, log, care = _setup(None, job)
    assert uses.on_done(_frame()) == "job_overlap"
    assert log.records() == ()
    assert len(care.recent()) == 1


def test_running_job_on_this_appliance_overlaps():
    uses, log, _ = _setup(_Service(running="microwave"))
    assert uses.on_done(_frame()) == "job_overlap"
    assert log.records() == ()


@pytest.mark.parametrize("job", [
    _job(appliance="air_purifier"),  # 다른 가전 실행은 상관없다
    _job(started_ago=400.0, finished_ago=300.0),  # 오래전 실행
])
def test_unrelated_job_does_not_hide_a_hand_use(job):
    uses, log, _ = _setup(None, job)
    assert uses.on_done(_frame()) == "recorded"
    assert len(log.records()) == 1


def test_unrelated_running_job_does_not_hide_a_hand_use():
    uses, log, _ = _setup(_Service(running="air_purifier"))
    assert uses.on_done(_frame()) == "recorded"


@pytest.mark.parametrize("source", ["mock", "injected"])
def test_not_real_power_never_becomes_a_record_or_notice(source):
    uses, log, care = _setup()
    assert uses.on_done(_frame(source=source)) == "not_real"
    assert log.records() == () and care.recent() == ()


def test_gap_during_run_invents_nothing():
    uses, log, care = _setup()
    frame = _frame(gap=True)
    assert frame["evidence"]["power"]["gaps"] >= 1
    assert uses.on_done(frame) == "no_power_run"
    assert log.records() == () and care.recent() == ()


def test_beep_only_end_has_no_power_run():
    uses, log, care = _setup()
    frame = dict(_frame(), inputs=["beep"], evidence={"beep": {}})
    assert uses.on_done(frame) == "no_power_run"
    assert log.records() == () and care.recent() == ()


def test_same_event_received_twice_counts_once():
    uses, log, care = _setup()
    frame = _frame()
    assert uses.on_done(frame) == "recorded"
    assert uses.on_done(frame) == "duplicate"
    assert len(log.records()) == 1 and len(care.recent()) == 1


def test_old_rpi4_frame_without_gaps_still_counts():
    uses, log, _ = _setup()
    frame = _frame()
    del frame["evidence"]["power"]["gaps"]
    assert uses.on_done(frame) == "recorded"


def test_washer_end_stays_out_of_observed_use():
    uses, log, care = _setup()
    frame = dict(_frame(), appliance_id="washer", event="wash_complete")
    assert uses.on_done(frame) == "not_microwave"
    assert log.records() == () and care.recent() == ()


def test_frame_is_written_to_the_appliance_the_kit_is_bound_to():
    uses, log, _ = _setup(_Service(bound=KitBound("my_oven", True, True)))
    assert uses.on_done(_frame("microwave")) == "recorded"
    assert log.records()[0].appliance_id == "my_oven"


def test_job_on_the_bound_appliance_overlaps_a_frame_with_the_fixed_name():
    uses, log, _ = _setup(_Service(bound=KitBound("my_oven", True, True)), _job(appliance="my_oven"))
    assert uses.on_done(_frame("microwave")) == "job_overlap"


@pytest.mark.parametrize("bound", [KitBound("my_fan", True, True), KitBound(None, False, True)])
def test_kit_moved_off_a_microwave_says_nothing(bound):
    uses, log, care = _setup(_Service(bound=bound))
    assert uses.on_done(_frame()) == "not_bound"
    assert log.records() == () and care.recent() == ()


def test_custom_watch_id_of_a_registered_microwave_counts():
    uses, log, _ = _setup(_Service(bound=KitBound("my_oven", True, True)))
    frame = dict(_frame("my_oven"), event="my_oven_done")
    assert uses.on_done(frame) == "recorded"


def _observed(days_ago, hour=19, minute=0, seconds=62.0, now=NOW, **changes):
    fields = dict(outcome=UsageOutcome.SUCCEEDED, appliance_id="microwave", execution_mode=ExecutionMode.REAL,
                  source=UsageSource.OBSERVED_POWER, duration_s=seconds)
    return UsageRecord((now - timedelta(days=days_ago)).replace(hour=hour, minute=minute), OBSERVED_PURPOSE,
                       **{**fields, **changes})


def _detector(records, now=NOW):
    return PatternDetector(InMemoryUsageLog(records), FixedClock(now), PatternConfig(3, (BAND,), ask_lead_minutes=10))


# 월요일(0)·금요일(3)·목요일(4) 저녁 — 주말을 지나도 평일에만 썼다.
_WEEKDAYS = [0, 3, 4]


def test_observed_habit_uses_the_same_three_days_three_times_rule():
    assert _detector([_observed(d) for d in _WEEKDAYS[:2]]).observed_uses() == []
    # 하루에 여러 번은 날 수를 채우지 못한다.
    assert _detector([_observed(3, minute=m) for m in (0, 5, 10, 15)]).observed_uses() == []
    [habit] = _detector([_observed(d, seconds=s) for d, s in zip(_WEEKDAYS, (58.0, 62.0, 66.0))]).observed_uses()
    assert habit["average_duration_s"] == pytest.approx(62.0)
    assert habit["text"] == "평일 오후 7시쯤, 1분쯤 직접 사용하셨어요"
    assert habit["appliance_id"] == "microwave"


def test_mock_and_failed_records_are_not_observed_habits():
    assert _detector([_observed(d, execution_mode=ExecutionMode.MOCK) for d in (1, 2, 3, 4)]).observed_uses() == []
    assert _detector([_observed(d, outcome=UsageOutcome.FAILED) for d in (1, 2, 3, 4)]).observed_uses() == []


def test_safety_observed_habit_never_reaches_cards_drafts_or_routines_list():
    """관찰 습관은 아는 것까지만 — 습관 카드·루틴 초안·'알게 된 것' 습관 목록(맡기기 단추가 붙는 곳)에 들어가지 않는다."""
    records = [_observed(d, minute=15) for d in range(1, 8)]
    detector = _detector(records, NOW.replace(hour=19, minute=10))
    assert detector.candidates() == ()
    assert detector.established() == ()
    status = detector.learning_status()
    assert status["routines"] == []
    assert len(status["observed"]) == 1


def test_direct_records_do_not_appear_as_observed():
    direct = [_observed(d, source=UsageSource.DIRECT, duration_s=None) for d in range(1, 6)]
    detector = _detector(direct)
    assert detector.observed_uses() == []
    assert "average_duration_s" not in detector.learning_status()["routines"][0]


def test_observed_use_does_not_raise_a_quiet_routine_alert():
    clock = FixedClock(NOW.replace(hour=23))
    care = CareEventStore(clock)
    log = InMemoryUsageLog(tuple(_observed(d) for d in range(1, 6)))
    checker = RoutineQuietChecker(log, clock, PatternConfig(3, (BAND,)), care)
    assert checker.check() == ()


@pytest.mark.parametrize("seconds,text", [(5, "10초쯤"), (30, "30초쯤"), (62, "1분쯤"), (100, "2분쯤"), (200, "3분쯤")])
def test_duration_words(seconds, text):
    assert duration_text(seconds) == text


def test_duration_and_source_survive_the_database(tmp_path):
    db = SimpleLayDb(str(tmp_path / "s.db"))
    log = SqliteUsageLog(db)
    log.append(_observed(1))
    [record] = SqliteUsageLog(SimpleLayDb(str(tmp_path / "s.db"))).records()
    assert record.source is UsageSource.OBSERVED_POWER and record.duration_s == 62.0


def test_database_without_duration_column_is_migrated(tmp_path):
    import sqlite3

    path = str(tmp_path / "old.db")
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE usage_log (id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at TEXT NOT NULL,"
                 " purpose TEXT NOT NULL, outcome TEXT NOT NULL, appliance_id TEXT, execution_mode TEXT, source TEXT)")
    conn.execute("INSERT INTO usage_log (occurred_at, purpose, outcome, appliance_id, execution_mode, source)"
                 " VALUES (?, '옛 기록', 'succeeded', 'microwave', 'real', 'direct')", (NOW.isoformat(),))
    conn.commit()
    conn.close()
    [record] = SqliteUsageLog(SimpleLayDb(path)).records()
    assert record.purpose == "옛 기록" and record.duration_s is None


@pytest.fixture()
def api(monkeypatch):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_ACT_MODE", "SIMPLELAY_WEATHER_MODE"):
        monkeypatch.delenv(name, raising=False)
    caches = (deps.get_service, deps.get_suggestion_service, deps.get_care_events, deps.get_usage_log, deps.get_job_history, deps.get_db,
              deps.get_appliance_registry, deps.get_appliance_done_log, deps.get_alert_store, deps.get_observed_uses)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def test_received_frame_reaches_usage_log_phone_inbox_and_kiosk_tip(api):
    deps.receive_appliance_done(_frame())
    records = deps.get_usage_log().records()
    assert [r.source for r in records] == [UsageSource.OBSERVED_POWER]
    assert [e["message"] for e in api.get("/care-events").json()] == ["가열이 끝났어요"]
    tip = api.get("/ambient").json()["tip"]
    assert tip["text"] == "가열이 끝났어요" and tip["icon"] == "notice"


def test_no_suggestion_or_job_comes_from_an_observed_use(api):
    before = api.get("/status").json()["last_job_id"]
    deps.receive_appliance_done(_frame())
    assert api.get("/status").json()["last_job_id"] == before
    assert [s for s in api.get("/suggestions").json() if "전자레인지" in s.get("purpose", "")] == []


def test_rehearsal_injection_leaves_no_usage(api):
    assert api.post("/demo/appliance-done", json={"appliance_id": "microwave", "inputs": ["power"]}).status_code == 200
    assert deps.get_usage_log().records() == ()
    assert api.get("/care-events").json() == []


def test_learning_api_carries_observed_list(api):
    today = datetime.now(KST)
    for days in (1, 2, 3, 4):
        deps.get_usage_log().append(_observed(days, seconds=60.0, now=today))
    body = api.get("/learning").json()
    assert body["routines"] == []
    [habit] = body["observed"]
    assert habit["text"].endswith("오후 7시쯤, 1분쯤 직접 사용하셨어요") and habit["appliance_id"] == "microwave"


def test_observed_failure_does_not_stop_the_routine_path(monkeypatch, api):
    class Boom:
        def on_done(self, record):
            raise RuntimeError("boom")

    monkeypatch.setattr(deps, "get_observed_uses", lambda: Boom())
    deps.receive_appliance_done(_frame())
    assert len(deps.get_appliance_done_log().recent()) == 1
