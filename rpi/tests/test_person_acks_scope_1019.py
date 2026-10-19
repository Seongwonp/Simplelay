"""'확인함'은 사람이 실제로 본 것만 덮는다(검토 2026-10-19 #2·#3·#4·#10).

- #2 실행 하나에 답해도 다른 실행의 못 한 일 알림은 그대로다.
- #3 폰 '기록 보기'는 화면에 보인 알림 번호·실행 기록까지만 적는다(그 뒤에 생긴 실패·실행은 아직 안 봤다).
- #4 기준은 본체 시계가 아니라 알림 번호다 — RTC 없는 본체의 시계가 뒤로 가도 새 실패를 덮지 않는다.
- #10 여러 단계 실행의 기록 번호(``base-N``)를 확인하면 ``/status``의 실행 번호(``base``)도 '봤다'가 된다.

옛 앱은 ``failures_seen_until``(시각)으로 ``occurred_at <= until``이면 봤다고 본다 — 그 규칙으로도 함께 확인한다.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.services.history import JobHistoryEntry

_CACHED = (deps.get_db, deps.get_person_acks, deps.get_care_events, deps.get_job_history)


def _reset() -> None:
    for dep in _CACHED:
        dep.cache_clear()


@pytest.fixture()
def api(monkeypatch, tmp_path):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "acks.db"))
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


class _Clock:
    def __init__(self, t: datetime) -> None:
        self.t = t

    def now(self) -> datetime:
        return self.t


def _job(job_id: str) -> JobHistoryEntry:
    return JobHistoryEntry(job_id=job_id, finished_at=datetime.now(timezone.utc).astimezone(),
                           purpose="공기청정기 켜기", status="failed", buttons=())


def _covered(body: dict, event) -> bool:
    """새 앱(번호)·옛 앱(시각) 어느 규칙으로든 '봤다'로 보이나."""
    if event.event_id <= body.get("care_seen_id", 0):
        return True
    if event.event_id <= body.get("failures_seen_id", 0):
        return True
    until = body.get("failures_seen_until")
    return until is not None and event.occurred_at <= datetime.fromisoformat(until)


def test_answer_on_one_job_keeps_an_unrelated_failure_unseen(api):
    care = deps.get_care_events()
    air_failure = care.append("execution_failed", "'공기청정기' 못 했어요")
    done_failure = care.append("appliance_done_undelivered", "완료 알림을 못 보냈어요")
    body = api.post("/acks", json={"job_id": "microwave-job", "answer": "moved"}).json()
    assert body["job_answers"] == {"microwave-job": "moved"}
    assert not _covered(body, air_failure)
    assert not _covered(body, done_failure)
    assert not _covered(api.get("/acks").json(), air_failure)


def test_phone_history_view_marks_only_what_the_phone_showed(api):
    care, history = deps.get_care_events(), deps.get_job_history()
    shown_failure = care.append("execution_failed", "'공기청정기' 못 했어요")
    history.append(_job("job-shown"))
    # 폰이 받아 온 뒤에 생긴 실패·실행 — 폰은 아직 모른다.
    new_failure = care.append("execution_failed", "'선풍기' 못 했어요")
    history.append(_job("job-new"))

    body = api.post("/acks", json={"failures_seen": True, "failures_seen_id": shown_failure.event_id,
                                   "seen_until_job_id": "job-shown"}).json()
    assert body["job_answers"] == {"job-shown": "seen"}
    assert _covered(body, shown_failure)
    assert not _covered(body, new_failure)


def test_phone_can_name_the_jobs_it_showed(api):
    history = deps.get_job_history()
    history.append(_job("job-a"))
    history.append(_job("job-b"))
    body = api.post("/acks", json={"seen_job_ids": ["job-a"]}).json()
    assert body["job_answers"] == {"job-a": "seen"}


def test_unknown_cursor_job_marks_nothing(api):
    deps.get_job_history().append(_job("job-a"))
    body = api.post("/acks", json={"seen_until_job_id": "job-gone"}).json()
    assert body["job_answers"] == {}


def test_failure_after_the_hub_clock_went_back_is_not_hidden(api):
    """RTC 없는 본체 — 정확한 시각에 확인을 적은 뒤, 인터넷 없이 켜 시계가 더 이른 시각에서 시작한 경우."""
    care = deps.get_care_events()
    care._clock = _Clock(datetime(2020, 1, 1, 21, 0, tzinfo=timezone.utc))
    seen = care.append("execution_failed", "'공기청정기' 못 했어요")
    api.post("/acks", json={"failures_seen": True, "failures_seen_id": seen.event_id})
    care._clock = _Clock(datetime(2020, 1, 1, 18, 10, tzinfo=timezone.utc))  # 시계가 뒤로 갔다
    later = care.append("execution_failed", "'공기청정기' 못 했어요")
    body = api.get("/acks").json()
    assert later.occurred_at < seen.occurred_at
    assert not _covered(body, later)


def test_step_job_ack_also_marks_the_run_id_the_kiosk_watches(api):
    history = deps.get_job_history()
    base = "0123456789ab"
    history.append(_job(f"{base}-1"))
    history.append(_job(f"{base}-2"))
    body = api.post("/acks", json={"failures_seen": True}).json()
    assert base in body["job_answers"], "키오스크는 /status의 실행 번호(base)로 확인을 본다"

    other = "ba9876543210"
    body = api.post("/acks", json={"job_id": f"{other}-2", "answer": "seen"}).json()
    assert other in body["job_answers"]
