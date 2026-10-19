"""외부 검토 2026-10-19 (10): 옛 앱용 ``failures_seen_until``(시각)을 '못 한 일'이 아닌 알림까지 넣어 셈했다.

본 번호(``failures_seen_id``)까지의 알림 중 가장 늦은 시각을 줬는데, 그 안에 안내·자동 실행 같은 다른 종류가 있고 그 시각이
더 늦으면(시계가 뒤로 갔다가 돌아온 경우 등) 옛 앱이 보지 않은 시각까지 '봤다'로 넓혀 읽었다. 못 한 일 종류만 센다.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from rpi.services.person_acks import AckSnapshot, legacy_failures_seen_until

T0 = datetime(2026, 10, 19, 9, 0, tzinfo=timezone.utc)


def _event(event_id, kind, minutes):
    return SimpleNamespace(event_id=event_id, kind=kind, occurred_at=T0 + timedelta(minutes=minutes))


def test_only_failure_kinds_set_the_legacy_seen_until():
    events = [
        _event(1, "execution_failed", 0),
        _event(2, "routine_announce", 30),  # 못 한 일이 아니다 — 시각이 더 늦어도 기준이 되지 않는다
        _event(3, "execution_failed", 10),
    ]
    snap = AckSnapshot(failures_seen_id=3)
    assert legacy_failures_seen_until(snap, events) == T0 + timedelta(minutes=10)


def test_no_seen_failure_gives_no_legacy_value():
    snap = AckSnapshot(failures_seen_id=2)
    assert legacy_failures_seen_until(snap, [_event(1, "routine_announce", 0), _event(2, "auto_rule", 5)]) is None
