"""루틴 건너뛰기·회차 표시 저장 순서(검토 2026-10-19 #8).

``_persist_skips``·``_persist_fired``는 스냅숏을 잠금 안에서 찍고 저장은 잠금 밖에서 했다. 두 요청(폰·키오스크)이 거의 동시에
오면 먼저 찍은(옛) 스냅숏이 나중에 저장될 수 있다 — 메모리는 맞지만 DB는 옛 값이라 재시작 뒤 건너뛰기가 사라지거나 되살아난다.
이제 스냅숏과 저장을 한 저장 잠금 안에서 함께 한다(마지막 저장이 늘 마지막 상태다).
"""

from __future__ import annotations

import json
import threading
from datetime import datetime, timezone

import pytest

from rpi.routines.engine import FIRED_SETTING, SKIP_SETTING, RoutineEngine


class _Clock:
    def now(self) -> datetime:
        return datetime(2026, 10, 19, 21, 0, tzinfo=timezone.utc)


class _SlowFirstSave:
    """첫 저장만 붙잡아 두는 저장 함수 — 그 사이 다른 저장이 끝나는지 본다."""

    def __init__(self) -> None:
        self.stored: dict[str, str] = {}
        self.first_in_save = threading.Event()
        self.release = threading.Event()
        self._calls = 0
        self._lock = threading.Lock()

    def __call__(self, key: str, value: str) -> None:
        with self._lock:
            self._calls += 1
            first = self._calls == 1
        if first:
            self.first_in_save.set()
            self.release.wait(5)
        self.stored[key] = value


def _engine() -> RoutineEngine:
    return RoutineEngine(store=None, suggestions=None, service=None, clock=_Clock())


@pytest.mark.parametrize("which", ["skips", "fired"])
def test_last_save_is_the_last_state(which):
    engine = _engine()
    save = _SlowFirstSave()
    if which == "skips":
        engine.restore_skips(lambda _k: None, save)
        attr, key, persist = "_skips", SKIP_SETTING, engine._persist_skips
        first_value: object = "2026-10-19T22:00:00+00:00"
    else:
        engine.restore_fired(lambda _k: None, save)
        attr, key, persist = "_fired", FIRED_SETTING, engine._persist_fired
        first_value = ("2026-10-19", "22:00")

    # 요청 1: 건너뛰기(또는 회차 표시)를 넣고 저장 — 저장이 늦다.
    with engine._lock:
        getattr(engine, attr)["r1"] = first_value
    t1 = threading.Thread(target=persist)
    t1.start()
    assert save.first_in_save.wait(5)
    # 요청 2: 되돌리고 저장.
    with engine._lock:
        getattr(engine, attr).pop("r1")
    t2 = threading.Thread(target=persist)
    t2.start()
    t2.join(0.3)
    save.release.set()
    t1.join(5)
    t2.join(5)

    assert json.loads(save.stored[key]) == {}, "옛 스냅숏이 마지막에 저장되면 재시작 뒤 되돌린 값이 되살아난다"
