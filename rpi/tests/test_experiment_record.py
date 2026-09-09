"""F4 — 실험 기록. 실기기(H1) 앞에 먼저 세워두는 계측이다.

발표에서 주장할 수 있는 것은 **기록한 것뿐**이다. 지금 이력에는 무엇을·언제
끝났고·버튼별 몇 번 시도했는지만 있다. 실기기 실험을 시작하면 바로 아쉬운
것들이 빠져 있다:

- **어떤 가전에서** 한 실행인가 (가전마다 성공률이 다르다)
- **실제인가 mock인가** — 이걸 못 가르면 mock 실행이 성공률 통계에 섞인다.
  숫자를 부풀리려 한 게 아니어도 결과는 같다.
- **얼마나 걸렸나** (시작 시각이 없어 소요시간을 못 뺀다)
- **왜 끝났나** — 사용자가 멈춘 것과 재시도를 소진한 것은 전혀 다른 사건인데
  둘 다 상태값 하나로 뭉개져 있었다. 정지 지연을 재려면 이 구분이 필요하다.

기록해도 새어 나가면 안 되는 것이 있다: 주소·키·가정 식별정보·원문 음성.
내보내기는 **허용 목록**으로만 나간다.
"""

from datetime import datetime, timedelta, timezone

import pytest

from rpi.api import SimpleLayService
from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ClosedLoopController,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.services.history import (
    ButtonAttempt,
    ExecutionMode,
    InMemoryJobHistory,
    JobHistoryEntry,
    Termination,
    history_csv,
)
from rpi.services.persistence import SimpleLayDb, SqliteJobHistory
from rpi.verifier import MockVerifier

KST = timezone(timedelta(hours=9))
_NOW = datetime(2026, 9, 9, 19, 0, tzinfo=KST)


class _SteppingClock:
    """호출할 때마다 1초씩 흐른다 — 소요시간을 실제로 재는지 보기 위해."""

    def __init__(self, start: datetime) -> None:
        self._now = start

    def now(self) -> datetime:
        value = self._now
        self._now = self._now + timedelta(seconds=1)
        return value


def _wait_until(predicate, timeout: float = 2.0) -> None:
    """백그라운드 job은 다른 스레드에서 끝난다."""
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("시간 안에 조건이 성립하지 않았다")


class _RealGrbl(MockGrblClient):
    """실기기 클라이언트 흉내 — 자기가 실제로 누른다고 말한다.

    모드는 **실행 대상이** 말한다(서비스에 주입하는 전역 플래그가 아니다).
    가전별 원격 노드로 라우팅되면 서비스 설정과 실제 실행 대상이 달라지기
    때문이다 — test_execution_mode_routing.py가 그 이음매를 고정한다.
    """

    execution_mode = ExecutionMode.REAL


def _service(history, *, clock=None, outcomes=None, mode=ExecutionMode.MOCK):
    grbl = _RealGrbl() if mode is ExecutionMode.REAL else MockGrblClient()
    return SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            grbl,
            MockVerifier(outcomes=outcomes or [True] * 20),
            MockAlertSink(),
            MockSafetyController(),
            retry_waiter=MockRetryWaiter(),
        ),
        clock=clock or FixedClock(_NOW),
        history_store=history,
    )


# ── 실행이 남기는 것 ──────────────────────────────────────────────────────


def test_records_the_appliance_and_mode():
    history = InMemoryJobHistory()
    _service(history).execute_purpose("우유 데워줘", appliance_id="microwave")

    (entry,) = history.recent()
    assert entry.appliance_id == "microwave"
    assert entry.execution_mode is ExecutionMode.MOCK


def test_real_mode_is_recorded_as_real():
    """mock 실행이 성공률 통계에 섞이면 숫자가 사실이 아니게 된다."""
    history = InMemoryJobHistory()
    _service(history, mode=ExecutionMode.REAL).execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.execution_mode is ExecutionMode.REAL


def test_records_duration():
    history = InMemoryJobHistory()
    _service(history, clock=_SteppingClock(_NOW)).execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.started_at is not None
    assert entry.duration is not None
    assert entry.duration > timedelta(0)
    assert entry.finished_at > entry.started_at


def test_success_is_terminated_as_completed():
    history = InMemoryJobHistory()
    _service(history).execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.termination is Termination.COMPLETED


def test_retry_exhaustion_and_user_stop_are_different_endings():
    """상태값 하나로 뭉개면 정지 지연을 잴 수 없다 — 사용자가 멈춘 실행과
    스스로 포기한 실행은 실험에서 전혀 다른 표본이다."""
    history = InMemoryJobHistory()
    service = _service(history, outcomes=[False] * 30)

    service.execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.termination is Termination.RETRIES_EXHAUSTED


def test_user_stop_is_recorded_as_user_stop():
    # 실행 '중'에 도착한 정지여야 한다. 실행 전에 부른 정지는 _begin_run이
    # 의도적으로 지운다(그건 '실행 중 작업 없음'으로 정확히 보고된다).
    history = InMemoryJobHistory()
    holder: list[SimpleLayService] = []

    class _StopsItself:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons):
            holder[0].emergency_stop()
            return ExecutionResult(
                ExecutionStatus.SAFETY_STOPPED,
                tuple(
                    ButtonResult(b, ButtonStatus.FAILED, 1, None)
                    for b in buttons
                ),
            )

    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _StopsItself(),
        clock=FixedClock(_NOW),
        history_store=history,
    )
    holder.append(service)

    service.execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.termination is Termination.STOPPED_BY_USER


def test_user_stop_records_when_the_stop_was_accepted():
    """정지 지연은 **접수 시각과 종료 시각의 차이**다. 시작·종료 시각만으로는
    "전체 얼마나 걸렸나"까지가 한계라, 그 열이 없으면 CSV에서 정지 지연을
    아예 뺄 수 없다 — H1이 요구하는 다섯 지표 중 하나가 통째로 빠진다."""
    history = InMemoryJobHistory()
    holder: list[SimpleLayService] = []

    class _StopsItself:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons):
            holder[0].emergency_stop()
            return ExecutionResult(
                ExecutionStatus.SAFETY_STOPPED,
                tuple(
                    ButtonResult(b, ButtonStatus.FAILED, 1, None)
                    for b in buttons
                ),
            )

    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _StopsItself(),
        clock=_SteppingClock(_NOW),
        history_store=history,
    )
    holder.append(service)

    service.execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.stop_requested_at is not None
    assert entry.stop_latency is not None
    assert entry.stop_latency >= timedelta(0)
    # 접수는 시작 뒤, 종료 앞이다.
    assert entry.started_at <= entry.stop_requested_at <= entry.finished_at


def test_a_run_that_finished_on_its_own_has_no_stop_time():
    """정지하지 않은 실행에 접수 시각이 남으면 지연 통계의 분모가 오염된다."""
    history = InMemoryJobHistory()
    _service(history).execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.stop_requested_at is None
    assert entry.stop_latency is None


def test_stop_time_does_not_leak_into_the_next_run():
    """정지로 끝난 실행 다음에 정상 실행이 오면, 앞 실행의 접수 시각이
    따라붙어선 안 된다."""
    history = InMemoryJobHistory()
    holder: list[SimpleLayService] = []
    stop_once = [True]

    class _StopsOnce:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons):
            if stop_once[0]:
                stop_once[0] = False
                holder[0].emergency_stop()
                return ExecutionResult(
                    ExecutionStatus.SAFETY_STOPPED,
                    tuple(
                        ButtonResult(b, ButtonStatus.FAILED, 1, None)
                        for b in buttons
                    ),
                )
            return ExecutionResult(
                ExecutionStatus.SUCCEEDED,
                tuple(
                    ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None)
                    for b in buttons
                ),
            )

    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _StopsOnce(),
        clock=_SteppingClock(_NOW),
        history_store=history,
    )
    holder.append(service)

    service.execute_purpose("우유 데워줘")
    service.execute_purpose("우유 데워줘")

    # recent()는 최신순이다.
    latest, first = history.recent()
    assert first.stop_requested_at is not None
    assert latest.stop_requested_at is None


def test_stop_pressed_twice_keeps_the_first_moment():
    """연타로 기준점이 뒤로 밀리면 지연이 실제보다 짧게 기록된다 --
    사용자가 멈추라고 한 순간은 첫 번째다."""
    history = InMemoryJobHistory()
    holder: list[SimpleLayService] = []

    class _StopsTwice:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons):
            holder[0].emergency_stop()
            first = holder[0]._stop_requested_at
            holder[0].emergency_stop()
            assert holder[0]._stop_requested_at == first
            return ExecutionResult(
                ExecutionStatus.SAFETY_STOPPED,
                tuple(
                    ButtonResult(b, ButtonStatus.FAILED, 1, None)
                    for b in buttons
                ),
            )

    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _StopsTwice(),
        clock=_SteppingClock(_NOW),
        history_store=history,
    )
    holder.append(service)

    service.execute_purpose("우유 데워줘")

    (entry,) = history.recent()
    assert entry.stop_requested_at is not None


def test_a_stopped_run_that_then_crashed_is_still_a_user_stop():
    """사용자가 멈춘 뒤 컨트롤러가 예외로 끝나는 경우가 있다(UART 단절 등).
    그걸 '재시도 소진'으로 기록하면 실패율 분모에 사용자 정지가 섞인다."""
    history = InMemoryJobHistory()
    holder: list[SimpleLayService] = []

    class _StopsThenCrashes:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons):
            holder[0].emergency_stop()
            raise RuntimeError("가전과 연결이 끊겼다")

    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _StopsThenCrashes(),
        clock=_SteppingClock(_NOW),
        history_store=history,
    )
    holder.append(service)

    service.submit_purpose("우유 데워줘")
    _wait_until(lambda: len(history.recent()) == 1)

    (entry,) = history.recent()
    assert entry.termination is Termination.STOPPED_BY_USER
    assert entry.stop_requested_at is not None


# ── 영속화 ────────────────────────────────────────────────────────────────


def _entry(**over) -> JobHistoryEntry:
    base = dict(
        job_id="job-1",
        finished_at=_NOW,
        purpose="우유 데워줘",
        status="succeeded",
        buttons=(ButtonAttempt("해동", True, 2),),
        appliance_id="microwave",
        execution_mode=ExecutionMode.REAL,
        started_at=_NOW - timedelta(seconds=7),
        termination=Termination.COMPLETED,
    )
    base.update(over)
    return JobHistoryEntry(**base)


def test_sqlite_round_trips_the_new_fields(tmp_path):
    db = SimpleLayDb(str(tmp_path / "s.db"))
    SqliteJobHistory(db).append(_entry())
    db.close()

    reopened = SimpleLayDb(str(tmp_path / "s.db"))
    try:
        (entry,) = SqliteJobHistory(reopened).recent()
        assert entry.appliance_id == "microwave"
        assert entry.execution_mode is ExecutionMode.REAL
        assert entry.started_at == _NOW - timedelta(seconds=7)
        assert entry.termination is Termination.COMPLETED
        assert entry.duration == timedelta(seconds=7)
        assert entry.stop_requested_at is None
    finally:
        reopened.close()


def test_sqlite_round_trips_the_stop_time(tmp_path):
    stopped = _entry(
        termination=Termination.STOPPED_BY_USER,
        status="safety_stopped",
        stop_requested_at=_NOW - timedelta(seconds=2),
    )
    db = SimpleLayDb(str(tmp_path / "stop.db"))
    SqliteJobHistory(db).append(stopped)
    db.close()

    reopened = SimpleLayDb(str(tmp_path / "stop.db"))
    try:
        (entry,) = SqliteJobHistory(reopened).recent()
        assert entry.stop_requested_at == _NOW - timedelta(seconds=2)
        assert entry.stop_latency == timedelta(seconds=2)
    finally:
        reopened.close()


def test_existing_db_without_the_columns_is_migrated(tmp_path):
    """실기기에는 이미 이력이 쌓인 DB가 깔려 있다. 지우게 하면 그동안의
    실행 기록이 날아간다."""
    import sqlite3

    path = str(tmp_path / "old.db")
    old = sqlite3.connect(path)
    old.executescript(
        """
        CREATE TABLE job_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            finished_at TEXT NOT NULL,
            purpose TEXT,
            status TEXT NOT NULL,
            buttons_json TEXT NOT NULL
        );
        """
    )
    old.execute(
        "INSERT INTO job_history (job_id, finished_at, purpose, status,"
        " buttons_json) VALUES (?, ?, ?, ?, ?)",
        ("old-1", _NOW.isoformat(), "우유 데워줘", "succeeded", "[]"),
    )
    old.commit()
    old.close()

    db = SimpleLayDb(path)
    try:
        store = SqliteJobHistory(db)
        (migrated,) = store.recent()
        assert migrated.job_id == "old-1"
        # 옛 기록은 모드를 모른다 -- 지어내지 않는다
        assert migrated.execution_mode is ExecutionMode.UNKNOWN
        assert migrated.started_at is None
        assert migrated.duration is None

        store.append(_entry(job_id="new-1"))
        assert [e.job_id for e in store.recent()] == ["new-1", "old-1"]
    finally:
        db.close()


# ── 내보내기 ──────────────────────────────────────────────────────────────


def test_csv_has_a_header_and_one_row_per_run():
    rows = history_csv(
        (
            _entry(job_id="a"),
            _entry(job_id="b", termination=Termination.STOPPED_BY_USER),
        )
    ).splitlines()

    assert rows[0].startswith("job_id,")
    assert len(rows) == 3


def test_csv_carries_the_fields_experiments_need():
    line = history_csv((_entry(),) ).splitlines()[1]

    for expected in [
        "job-1",
        "microwave",
        "real",
        "completed",
        "7.0",  # 소요시간(초)
    ]:
        assert expected in line, expected


def test_csv_carries_the_stop_latency():
    """정지 지연은 CSV가 답해야 하는 다섯 지표 중 하나다."""
    line = history_csv(
        (
            _entry(
                termination=Termination.STOPPED_BY_USER,
                status="safety_stopped",
                stop_requested_at=_NOW - timedelta(milliseconds=350),
            ),
        )
    ).splitlines()[1]

    assert "0.35" in line


def test_csv_leaves_the_stop_columns_empty_when_nothing_was_stopped():
    """빈 칸과 0초는 다른 뜻이다 -- 0.00을 채우면 "즉시 멈췄다"가 된다."""
    header, row = history_csv((_entry(),)).splitlines()

    columns = dict(zip(header.split(","), row.split(",")))
    assert columns["stop_requested_at"] == ""
    assert columns["stop_latency_seconds"] == ""


def test_csv_records_per_button_attempts_and_verification():
    line = history_csv(
        (
            _entry(
                buttons=(
                    ButtonAttempt("해동", True, 2),
                    ButtonAttempt("시작", False, 3),
                )
            ),
        )
    ).splitlines()[1]

    # 첫 시도 성공률·재시도 후 성공률을 뽑으려면 버튼별 시도 수가 필요하다
    assert "해동:ok:2" in line
    assert "시작:fail:3" in line


@pytest.mark.parametrize(
    "field",
    ["base_url", "api_key", "X-API-Key", "photo", "192.168"],
)
def test_csv_does_not_leak_connection_or_household_details(field):
    """공개 가능한 실험 기록에 주소·키·가정 식별정보가 섞이면 안 된다.
    허용 목록 방식이라 새 필드가 늘어도 저절로 새지 않는다."""
    text = history_csv((_entry(),))
    assert field not in text


def test_csv_quotes_purposes_containing_commas():
    text = history_csv((_entry(purpose='우유, 데워줘'),))
    assert '"우유, 데워줘"' in text


# ── HTTP 계약 ─────────────────────────────────────────────────────────────


@pytest.fixture()
def client(monkeypatch):
    import rpi.api.deps as deps
    from fastapi.testclient import TestClient
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    caches = (deps.get_service, deps.get_job_history)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def test_http_export_returns_csv(client):
    client.post("/execute", json={"text": "우유 데워줘", "appliance_id": "microwave"})
    # 비동기 job — 기록될 때까지 잠깐 기다린다
    import time

    for _ in range(200):
        if client.get("/history").json():
            break
        time.sleep(0.01)

    res = client.get("/history.csv")

    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/csv")
    lines = res.text.splitlines()
    assert lines[0].startswith("job_id,")
    assert "microwave" in lines[1]


def test_http_history_carries_the_execution_mode(client):
    """개발 PC 기본은 mock이다. 실기기 실험 결과와 섞이면 안 되므로
    응답에서부터 구분된다."""
    client.post("/execute", json={"text": "우유 데워줘"})
    import time

    body = []
    for _ in range(200):
        body = client.get("/history").json()
        if body:
            break
        time.sleep(0.01)

    assert body[0]["execution_mode"] == "mock"
    assert body[0]["termination"] == "completed"
    assert body[0]["duration_seconds"] is not None
