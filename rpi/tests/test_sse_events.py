"""SSE 이벤트 스트림(sse_event_lines) — 초기 스냅샷·변화 푸시·keepalive 계약.

무한 HTTP 스트림은 TestClient가 종료 처리에서 hang하므로, 제너레이터를
콜러블 주입으로 직접 구동해 검증한다 (엔드포인트는 얇은 껍데기).
"""

import asyncio
import json

from rpi.api.router import sse_event_lines, status_event_payload
from rpi.api.service import StatusSnapshot
from rpi.controller.models import ExecutionProgress


def _collect(alert_seq, status_seq, max_ticks, keepalive_every=1000):
    """max_ticks번 순회 후 연결 종료를 시뮬레이션하며 SSE 라인을 수집한다.

    is_disconnected가 루프 선두에서 한 번씩 불리는 것을 이용해 순회 횟수를
    센다 — n번째 순회는 alert_seq/status_seq의 [n-1] 값을 읽는다(부족하면
    마지막 값 유지).
    """
    ticks = 0

    async def counting_disconnected():
        nonlocal ticks
        ticks += 1
        return ticks > max_ticks

    def at(seq):
        return seq[min(ticks - 1, len(seq) - 1)]

    async def run():
        lines = []
        gen = sse_event_lines(
            counting_disconnected,
            lambda: at(alert_seq),
            lambda: at(status_seq),
            check_interval=0.0,
            keepalive_every=keepalive_every,
        )
        async for line in gen:
            lines.append(line)
        return lines

    return asyncio.run(run())


def _parse(lines):
    events = []
    for chunk in lines:
        if chunk.startswith(": "):
            events.append(("keepalive", None))
            continue
        name = chunk.split("\n")[0][len("event: "):]
        data = json.loads(chunk.split("\n")[1][len("data: "):])
        events.append((name, data))
    return events


_ALERT_OFF = {"active": False, "kind": None}
_ALERT_ON = {"active": True, "kind": "fire_alarm"}
_IDLE = {"running": False, "job_id": None}
_RUNNING = {"running": True, "job_id": "job-1"}


def test_initial_snapshot_is_sent_once():
    events = _parse(_collect([_ALERT_OFF], [_IDLE], max_ticks=3))

    # 첫 tick에 alert+status 스냅샷, 이후 변화 없으면 침묵
    assert events == [("alert", _ALERT_OFF), ("status", _IDLE)]


def test_changes_are_pushed_once_per_change():
    events = _parse(
        _collect(
            [_ALERT_OFF, _ALERT_OFF, _ALERT_ON, _ALERT_ON],
            [_IDLE, _RUNNING, _RUNNING, _RUNNING],
            max_ticks=5,
        )
    )

    assert events == [
        ("alert", _ALERT_OFF),
        ("status", _IDLE),
        ("status", _RUNNING),  # tick2에서 상태 변화
        ("alert", _ALERT_ON),  # tick3에서 경보 발생 — 지연 없이 즉시 푸시
    ]


def test_keepalive_emitted_periodically():
    events = _parse(
        _collect([_ALERT_OFF], [_IDLE], max_ticks=5, keepalive_every=2)
    )

    assert ("keepalive", None) in events
    # 변화가 없어도 keepalive는 주기마다 나온다
    assert events.count(("keepalive", None)) == 2


def test_disconnect_terminates_stream():
    # max_ticks=0 → 첫 확인에서 종료, 아무것도 보내지 않는다
    assert _collect([_ALERT_OFF], [_IDLE], max_ticks=0) == []


# ── status payload의 진행 필드 (교차 리뷰 #13) ───────────────────────────────


class _FakeService:
    def __init__(self, snapshot: StatusSnapshot) -> None:
        self._snapshot = snapshot

    def status(self) -> StatusSnapshot:
        return self._snapshot


def test_status_payload_carries_progress_fields_while_running():
    snapshot = StatusSnapshot(
        running=True,
        ready=True,
        last_result=None,
        progress=ExecutionProgress(
            button="해동", attempt=2, completed_steps=1, verification=None
        ),
        job_id="job-9",
        total_steps=3,
    )

    payload = status_event_payload(_FakeService(snapshot))

    assert payload["running"] is True
    assert payload["current_button"] == "해동"
    assert payload["current_attempt"] == 2
    assert payload["completed_steps"] == 1
    assert payload["total_steps"] == 3


def test_status_payload_progress_fields_are_none_when_idle():
    payload = status_event_payload(
        _FakeService(StatusSnapshot(running=False, ready=True, last_result=None))
    )

    assert payload["current_button"] is None
    assert payload["current_attempt"] is None
    assert payload["completed_steps"] is None
    assert payload["total_steps"] is None


def test_progress_change_produces_a_status_push():
    # 같은 job이라도 버튼 진행/재시도로 payload가 달라지면 status 이벤트가
    # 다시 나간다 — 키오스크의 "이벤트 → 즉시 폴링" 진행바가 성립하는 근거
    step1 = {"running": True, "job_id": "j", "completed_steps": 0}
    step2 = {"running": True, "job_id": "j", "completed_steps": 1}
    events = _parse(
        _collect([_ALERT_OFF], [step1, step1, step2], max_ticks=4)
    )

    assert events == [
        ("alert", _ALERT_OFF),
        ("status", step1),
        ("status", step2),  # 진행 변화만으로도 푸시
    ]
