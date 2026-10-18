"""사람이 '확인함'을 본체 한 곳에 둔다(사용자 보고 버그 2026-10-19).

폰 홈 '못 한 일 … 기록 보기' 경고가 기록을 보고 와도 남고, 키오스크에서 지난 일을 확인·답해도 폰과 키오스크 가전 칸·확인 필요
안내에 계속 남았다(확인이 각 기기 메모리에만 있었다). 이제 ``POST /acks``로 본체에 적고 ``GET /acks``로 모든 기기가 읽는다.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.ambient_router import _attention
from rpi.services.history import JobHistoryEntry
from rpi.services.person_acks import JOB_LIMIT, PersonAckStore
from rpi.services.persistence import SimpleLayDb


class _Clock:
    def __init__(self) -> None:
        self.t = datetime(2026, 10, 19, 9, 0, tzinfo=timezone.utc)

    def now(self) -> datetime:
        return self.t


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


def _job(job_id: str, status: str = "failed") -> JobHistoryEntry:
    return JobHistoryEntry(
        job_id=job_id,
        finished_at=datetime.now(timezone.utc).astimezone(),
        purpose="공기청정기 바람 세기 중",
        status=status,
        buttons=(),
    )


# ── 저장소 ────────────────────────────────────────────────────────────────


def test_answer_and_seen_survive_a_restart(tmp_path):
    clock = _Clock()
    db = SimpleLayDb(str(tmp_path / "a.db"))
    store = PersonAckStore(clock, db=db)
    store.change(job_id="j1", answer="moved")
    store.change(care_seen_id=7)
    db.close()

    again = PersonAckStore(clock, db=SimpleLayDb(str(tmp_path / "a.db")))
    snap = again.snapshot()
    assert snap.job_answers == {"j1": "moved"}
    assert snap.care_seen_id == 7
    assert snap.failures_seen_until == clock.t, "답하면 못 한 일 표시도 지금까지 올린다"


def test_seen_does_not_overwrite_a_movement_answer_and_care_seen_only_grows():
    store = PersonAckStore(_Clock())
    store.change(job_id="j1", answer="not_moved")
    store.change(job_id="j1", answer="seen")
    store.change(failures_seen=True, seen_job_ids=["j1", "j2"])
    assert store.snapshot().job_answers == {"j1": "not_moved", "j2": "seen"}
    store.change(care_seen_id=9)
    store.change(care_seen_id=3)
    assert store.snapshot().care_seen_id == 9


def test_job_answers_are_bounded():
    store = PersonAckStore(_Clock())
    store.change(failures_seen=True, seen_job_ids=[f"j{i}" for i in range(JOB_LIMIT + 5)])
    answers = store.snapshot().job_answers
    assert len(answers) == JOB_LIMIT
    assert "j0" not in answers and f"j{JOB_LIMIT + 4}" in answers


def test_unreadable_saved_value_means_nothing_acked(tmp_path):
    db = SimpleLayDb(str(tmp_path / "b.db"))
    db.save_setting("person_acks_v1", "{not json")
    assert PersonAckStore(_Clock(), db=db).snapshot().job_answers == {}


# ── API ───────────────────────────────────────────────────────────────────


def test_get_acks_starts_empty(api):
    body = api.get("/acks").json()
    assert body == {"care_seen_id": 0, "failures_seen_until": None, "job_answers": {}}


def test_post_needs_something(api):
    assert api.post("/acks", json={}).status_code == 422
    assert api.post("/acks", json={"answer": "moved"}).status_code == 422
    assert api.post("/acks", json={"job_id": "j", "answer": "maybe"}).status_code == 422


def test_care_seen_id_is_clamped_to_the_newest_event(api):
    care = deps.get_care_events()
    first = care.append("execution_failed", "'공기청정기' 못 했어요")
    body = api.post("/acks", json={"care_seen_id": first.event_id + 50}).json()
    assert body["care_seen_id"] == first.event_id, "아직 없는 알림까지 미리 지우지 않는다"


def test_history_view_marks_recent_jobs_and_failures_then_a_new_failure_shows_again(api):
    history = deps.get_job_history()
    history.append(_job("old-fail"))
    body = api.post("/acks", json={"failures_seen": True}).json()
    assert body["job_answers"] == {"old-fail": "seen"}
    assert body["failures_seen_until"] is not None
    until = datetime.fromisoformat(body["failures_seen_until"])

    # 새 실패 — 확인 전이다(목록에 없고, 알림 시각은 표시보다 뒤).
    history.append(_job("new-fail"))
    care = deps.get_care_events()
    event = care.append("execution_failed", "'공기청정기' 못 했어요")
    body = api.get("/acks").json()
    assert "new-fail" not in body["job_answers"]
    assert event.occurred_at >= until


def test_kiosk_answer_reaches_the_phone_and_survives_restart(api):
    """키오스크 답(moved) → 폰이 읽는 GET /acks에 있고, 서버 재시작 뒤에도 남는다."""
    assert api.post("/acks", json={"job_id": "job-7", "answer": "moved"}).status_code == 200
    _reset()
    from rpi.main import app

    again = TestClient(app)
    body = again.get("/acks").json()
    assert body["job_answers"] == {"job-7": "moved"}
    assert body["failures_seen_until"] is not None


# ── 키오스크 확인 필요 안내(/ambient) ────────────────────────────────────────


class _Registry:
    def get(self, _id):
        return SimpleNamespace(name="공기청정기")


class _Alerts:
    def current(self):
        return SimpleNamespace(active=False)


def _failed_service(job_id: str):
    snap = SimpleNamespace(
        running=False,
        last_result=SimpleNamespace(),
        last_appliance_id="air",
        last_job_id=job_id,
        last_command_status=None,
        last_route="thinq",
    )
    return SimpleNamespace(status=lambda: snap)


def test_ambient_attention_hides_after_ack_and_returns_for_a_new_failure(monkeypatch):
    from rpi.api import ambient_router
    from rpi.controller.models import ExecutionOutcome

    monkeypatch.setattr(ambient_router, "outcome_of", lambda _r: ExecutionOutcome.FAILED)
    acks = PersonAckStore(_Clock())
    items = _attention(_failed_service("j1"), _Registry(), _Alerts(), None, acks)
    assert [i.text for i in items] == ["공기청정기 설정을 바꾸지 못했어요. 가전을 봐 주세요."]

    acks.change(job_id="j1", answer="seen")
    assert _attention(_failed_service("j1"), _Registry(), _Alerts(), None, acks) == []

    # 새 실패는 아직 확인 전 — 다시 뜬다.
    assert len(_attention(_failed_service("j2"), _Registry(), _Alerts(), None, acks)) == 1


def test_failures_seen_until_moves_forward_only():
    clock = _Clock()
    store = PersonAckStore(clock)
    store.change(failures_seen=True)
    first = store.snapshot().failures_seen_until
    clock.t = clock.t - timedelta(minutes=5)  # 시계가 뒤로 가도 표시는 내려가지 않는다
    store.change(failures_seen=True)
    assert store.snapshot().failures_seen_until == first
