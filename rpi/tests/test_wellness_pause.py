"""F5 — 안부 확인 일시 중지.

안부 신호는 "평소 그 시간대에 쓰던 가전이 오늘 조용하다"를 알린다. 그런데
**집을 비운 것을 아는 날**에도 그대로 울린다 — 여행, 입원, 자녀 집에 며칠.
보호자는 이미 알고 있는 일로 알림을 받고, 그런 알림이 며칠 이어지면 정작
진짜 신호가 왔을 때 무시하게 된다. 안부 기능이 스스로를 무디게 만드는 것이다.

**제안 DND와는 다른 것이다.** DND는 "지금 말 걸지 마"이고, 이건 "며칠간
조용한 게 정상이다"이다. 하나로 묶으면 방해 금지 30분이 안부 확인까지
꺼버리거나, 여행 일주일이 제안까지 막는다.

규칙은 최소로:
- 종료 날짜까지(그 날짜 포함) 안부 확인을 쉰다. 무기한은 두지 않는다 --
  꺼둔 것을 잊으면 안부 기능이 있는 채로 없는 것과 같아진다.
- 쉬는 동안에도 **실패·위험소리·긴급정지 알림은 그대로 간다.** 사람이 집을
  비웠다는 것은 조용한 것이 정상이라는 뜻이지, 가전이 고장 나도 된다는
  뜻이 아니다.
"""

from datetime import date, datetime, time, timedelta, timezone

import pytest

from rpi.intent import InMemoryUsageLog, PatternConfig, TimeBand, UsageOutcome
from rpi.intent.mock import FixedClock
from rpi.intent.models import UsageRecord
from rpi.services.care_events import (
    CareEventStore,
    RoutineQuietChecker,
    WellnessPause,
)

KST = timezone(timedelta(hours=9))
_EVENING = TimeBand("저녁", time(18, 0), time(21, 0))


def _at(day: int, hour: int = 19) -> datetime:
    return datetime(2026, 7, day, hour, 0, tzinfo=KST)


def _checker(now: datetime, pause: WellnessPause | None = None):
    """저녁 루틴이 3일 성립해 있고, 오늘은 그 시간대가 조용하다."""
    usage = InMemoryUsageLog(
        tuple(
            UsageRecord(_at(d), "우유 데워줘", UsageOutcome.SUCCEEDED, "microwave")
            for d in (20, 21, 22)
        )
    )
    store = CareEventStore(FixedClock(now))
    checker = RoutineQuietChecker(
        usage,
        FixedClock(now),
        PatternConfig(minimum_occurrences=3, time_bands=(_EVENING,)),
        store,
        pause=pause,
    )
    return checker, store


# ── 쉬지 않을 때는 종전대로 ────────────────────────────────────────────────


def test_quiet_routine_still_alerts_without_a_pause():
    checker, _ = _checker(_at(23, 22))

    assert len(checker.check()) == 1


# ── 쉬는 동안 ─────────────────────────────────────────────────────────────


def test_paused_until_today_suppresses_the_alert():
    """종료 날짜 당일도 포함한다 — '오늘까지 여행'이 자연스러운 말이다."""
    pause = WellnessPause(until=date(2026, 7, 23))
    checker, store = _checker(_at(23, 22), pause)

    assert checker.check() == ()
    assert store.recent() == ()


def test_paused_until_a_later_date_suppresses_the_alert():
    pause = WellnessPause(until=date(2026, 7, 30))
    checker, _ = _checker(_at(23, 22), pause)

    assert checker.check() == ()


def test_pause_expires_the_day_after_it_ends():
    """지난 일시 중지가 안부 기능을 영영 꺼두면 안 된다."""
    pause = WellnessPause(until=date(2026, 7, 22))
    checker, _ = _checker(_at(23, 22), pause)

    assert len(checker.check()) == 1


def test_cleared_pause_resumes_immediately():
    pause = WellnessPause(until=date(2026, 7, 30))
    checker, _ = _checker(_at(23, 22), pause)
    assert checker.check() == ()

    pause.clear()

    assert len(checker.check()) == 1


# ── 쉬어도 꺼지지 않는 것 ─────────────────────────────────────────────────


def test_pause_does_not_touch_failure_or_danger_alerts():
    """집을 비웠다는 것은 조용한 것이 정상이라는 뜻이지, 가전이 고장 나도
    된다는 뜻이 아니다. 안부 신호만 쉰다."""
    pause = WellnessPause(until=date(2026, 7, 30))
    _, store = _checker(_at(23, 22), pause)

    store.append("execution_failed", "실행이 완료되지 못했어요", purpose="우유 데워줘")
    store.append("danger_sound", "위험할 수 있는 신호음이 감지되었어요", purpose=None)

    # recent()는 최신순이다.
    assert [e.kind for e in store.recent()] == [
        "danger_sound",
        "execution_failed",
    ]


# ── 상태 ──────────────────────────────────────────────────────────────────


def test_pause_reports_whether_it_is_active():
    pause = WellnessPause(until=date(2026, 7, 30))

    assert pause.is_active(date(2026, 7, 23)) is True
    assert pause.is_active(date(2026, 7, 30)) is True
    assert pause.is_active(date(2026, 7, 31)) is False


def test_no_pause_is_never_active():
    assert WellnessPause().is_active(date(2026, 7, 23)) is False


def test_pause_rejects_a_past_date():
    """이미 지난 날짜로 쉬게 하면 아무 일도 안 일어나는데 화면은 '쉬는 중'
    이라고 말하게 된다."""
    pause = WellnessPause()

    with pytest.raises(ValueError):
        pause.set_until(date(2026, 7, 22), today=date(2026, 7, 23))


# ── 상한 (마감 감사 ①) ────────────────────────────────────────────────────


def test_pause_rejects_a_date_beyond_the_cap():
    """상한을 화면의 날짜 선택기에만 두면 그 규칙은 **화면에만** 있는 것이다.
    키오스크나 직접 호출은 2099년까지 쉬게 만들 수 있고, 그건 곧 무기한이다."""
    pause = WellnessPause()
    today = date(2026, 7, 23)

    with pytest.raises(ValueError):
        pause.set_until(today + timedelta(days=WellnessPause.MAX_DAYS + 1), today)

    assert pause.until is None


def test_pause_accepts_the_cap_itself():
    pause = WellnessPause()
    today = date(2026, 7, 23)
    until = today + timedelta(days=WellnessPause.MAX_DAYS)

    pause.set_until(until, today)

    assert pause.until == until


# ── 재시작 (마감 감사 ②) ──────────────────────────────────────────────────


class _RecordingStore:
    def __init__(self, until: date | None = None) -> None:
        self.until = until

    def load_wellness_pause(self) -> date | None:
        return self.until

    def save_wellness_pause(self, until: date | None) -> None:
        self.until = until


def test_pause_is_written_through_to_the_store():
    store = _RecordingStore()
    pause = WellnessPause(store=store)

    pause.set_until(date(2026, 7, 30), today=date(2026, 7, 23))

    assert store.until == date(2026, 7, 30)


def test_clearing_is_written_through_too():
    store = _RecordingStore(date(2026, 7, 30))
    pause = WellnessPause(store=store)

    pause.clear()

    assert store.until is None


def test_pause_survives_a_restart():
    """여행 이틀째의 재부팅 한 번으로 남은 닷새 동안 알림이 다시 오면,
    이 기능이 없애려던 바로 그 상황이 된다."""
    store = _RecordingStore()
    WellnessPause(store=store).set_until(date(2026, 7, 30), date(2026, 7, 23))

    restarted = WellnessPause(store=store)  # 프로세스가 새로 떴다

    assert restarted.is_active(date(2026, 7, 25)) is True


def test_sqlite_round_trips_the_pause(tmp_path):
    from rpi.services.persistence import SimpleLayDb

    path = str(tmp_path / "simplelay.db")
    SimpleLayDb(path).save_wellness_pause(date(2026, 7, 30))

    assert SimpleLayDb(path).load_wellness_pause() == date(2026, 7, 30)


def test_sqlite_forgets_a_cleared_pause(tmp_path):
    from rpi.services.persistence import SimpleLayDb

    path = str(tmp_path / "simplelay.db")
    db = SimpleLayDb(path)
    db.save_wellness_pause(date(2026, 7, 30))
    db.save_wellness_pause(None)

    assert SimpleLayDb(path).load_wellness_pause() is None


# ── HTTP 계약 ─────────────────────────────────────────────────────────────


@pytest.fixture()
def client(monkeypatch):
    import rpi.api.deps as deps
    from fastapi.testclient import TestClient
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    caches = (deps.get_wellness_pause, deps.get_wellness_checker)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def test_http_reports_not_paused_by_default(client):
    body = client.get("/wellness-pause").json()

    assert body["paused"] is False
    assert body["until"] is None


def test_http_sets_and_clears_the_pause(client):
    until = (datetime.now(KST).date() + timedelta(days=3)).isoformat()

    res = client.post("/wellness-pause", json={"until": until})
    assert res.status_code == 200
    assert res.json()["paused"] is True
    assert res.json()["until"] == until

    assert client.delete("/wellness-pause").status_code == 200
    assert client.get("/wellness-pause").json()["paused"] is False


def test_http_rejects_a_past_date(client):
    past = (datetime.now(KST).date() - timedelta(days=1)).isoformat()

    res = client.post("/wellness-pause", json={"until": past})

    assert res.status_code == 422


def test_http_rejects_a_date_beyond_the_cap(client):
    far = (datetime.now(KST).date() + timedelta(days=400)).isoformat()

    res = client.post("/wellness-pause", json={"until": far})

    assert res.status_code == 422


def test_http_does_not_report_an_expired_pause_as_a_date(client):
    """지난 날짜를 그대로 내보내면 화면은 "7월 23일까지 쉬어요"라고 말하는데
    서버는 이미 안부 신호를 다시 보내고 있는 상태가 된다."""
    import rpi.api.deps as deps
    from rpi.intent.mock import FixedClock
    from rpi.main import app

    today = datetime.now(KST)
    until = (today.date() + timedelta(days=3)).isoformat()
    assert client.post("/wellness-pause", json={"until": until}).status_code == 200

    # 열흘 뒤 -- 일시 중지는 이미 스스로 풀렸다.
    app.dependency_overrides[deps.get_clock] = lambda: FixedClock(
        today + timedelta(days=10)
    )
    try:
        body = client.get("/wellness-pause").json()
    finally:
        app.dependency_overrides.pop(deps.get_clock, None)

    assert body["paused"] is False
    assert body["until"] is None
