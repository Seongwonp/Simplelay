"""외부 검토 2026-10-19 (4): 시각 루틴 회차의 '띄웠다' 표시.

회차를 '띄웠다'로 적고 저장한 **뒤에** 카드·자동 실행을 만들었다 — 그 사이 예외가 나면 카드도 없이 그 회차가 영영
쓰인 것으로 남았다(같은 창 안의 다음 확인에서도 다시 띄우지 않았다). 이제 결과가 난 뒤에 확정하고, 예외면 되돌린다.
"""

from __future__ import annotations

import json
from datetime import timedelta

from rpi.routines.engine import FIRED_SETTING
from rpi.tests.test_routines import THU_0730, Card, FixedClock, _engine, _save

DAILY_0730 = {"kind": "time", "days": [0, 1, 2, 3, 4, 5, 6], "time": "07:30"}


class _Settings:
    def __init__(self):
        self.values: dict[str, str] = {}

    def load(self, key):
        return self.values.get(key)

    def save(self, key, value):
        self.values[key] = value


def test_exception_while_making_the_card_does_not_consume_the_occurrence():
    engine, store, suggestions, *_ , clock = _engine(FixedClock(THU_0730 + timedelta(minutes=1)))
    settings = _Settings()
    engine.restore_fired(settings.load, settings.save)
    _save(store, clock, trigger=DAILY_0730)
    calls = {"n": 0}

    def flaky(**kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("카드 저장 실패")
        suggestions.cards.append(kw)
        return Card(f"s-{len(suggestions.cards)}", kw)

    suggestions.create_scenario_suggestion = flaky
    try:
        engine.tick()
    except RuntimeError:
        pass
    assert json.loads(settings.values.get(FIRED_SETTING) or "{}") == {}  # 쓰인 회차로 저장하지 않았다
    clock.value = THU_0730 + timedelta(minutes=2)
    assert len(engine.tick()) == 1  # 같은 창 안 다음 확인에서 다시 띄운다
    assert engine.tick() == []  # 띄운 뒤에는 한 번뿐
    assert json.loads(settings.values[FIRED_SETTING]) != {}
