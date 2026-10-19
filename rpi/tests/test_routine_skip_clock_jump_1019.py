"""외부 검토 2026-10-19 (7): RPi5는 RTC 배터리가 없어 벽시계가 잠깐 앞으로 튈 수 있다.

시계를 한 번 본 것만으로 앞으로 올 회차의 '건너뛰기'를 지난 것으로 지웠다 — 시계가 돌아오면 건너뛰기로 한 회차가 그대로
카드로 떴다. 이제 건너뛰기는 그 회차에서 쓰고 지우며, 시계 한 번으로는 회차 시각이 넉넉히 지난 것만 정리한다.
"""

from __future__ import annotations

from datetime import timedelta

from rpi.tests.test_routines import THU_0730, FixedClock, _engine, _save

DAILY_0730 = {"kind": "time", "days": [0, 1, 2, 3, 4, 5, 6], "time": "07:30"}


def test_a_forward_clock_jump_does_not_drop_a_future_skip():
    clock = FixedClock(THU_0730 - timedelta(hours=1, minutes=30))  # 목 06:00
    engine, store, suggestions, *_ = _engine(clock)
    routine = _save(store, clock, trigger=DAILY_0730)
    engine.set_skip(routine.routine_id, THU_0730.isoformat(), True)
    clock.value = THU_0730 + timedelta(days=2, hours=-1, minutes=-30)  # 벽시계가 토 06:00으로 잠깐 튄다
    assert engine.tick() == []
    clock.value = THU_0730 + timedelta(minutes=2)  # 시계가 돌아와 목 07:32
    assert engine.tick() == []
    assert suggestions.cards == []  # 건너뛰기로 한 회차는 카드가 없다
    assert any(e["outcome"] == "skipped" for e in engine.recent_log())
