"""외부 검토 2026-10-19 #10: 정지 뒤 되돌리기·무효화 경로가 읽어 둔 옛 사본을 잠금 밖에서 무조건 저장했다.

- 허용 저장 도중 정지(세대 바뀜)가 끼면 꺼진 상태로 되돌리는데, 그 사이 끝난 삭제·값 바꾸기를 옛 사본으로 덮었다
  (지운 규칙이 되살아나고 바꾼 값이 옛 값으로 돌아감).
- 사건 때 허용이 무효(대상 바뀜 등)라 규칙을 끌 때도, 판단 사이 끝난 삭제·값 바꾸기를 덮었다.

이제 둘 다 철회와 같은 전송권 잠금 안에서 지금 규칙이 읽은 그대로일 때만 바꾸고, 지워진 규칙은 다시 넣지 않는다.
전부 모의 ThinQ(프로세스 안 모의 클라이언트)다.
"""

from __future__ import annotations

import pytest

from rpi.routines.auto_rules import AutoRuleError
from rpi.tests.test_auto_rules import _after_allow, _allow, _engine, _inject, _wait_run, api  # noqa: F401


def _change(engine, rule_id, kind):
    if kind == "delete":
        engine.delete(rule_id)
    else:
        engine.update(rule_id, {"value": "MID"})


def _check(engine, rule_id, kind):
    current = engine.store.get(rule_id)
    if kind == "delete":
        assert current is None  # 되살리지 않는다
    else:
        assert current is not None and current.value == "MID" and current.enabled is False


@pytest.mark.parametrize("kind", ["delete", "change"])
def test_stop_rollback_does_not_overwrite_a_concurrent_delete_or_change(api, monkeypatch, kind):
    _allow(api)
    engine = _engine()
    (rule,) = engine.store.list()
    store = engine.store
    original = store.flush
    state = {"done": False}

    def racing_flush():
        if not state["done"]:
            state["done"] = True
            engine.emergency_stop()  # 허용 저장 도중 정지 — 세대가 바뀐다
            _change(engine, rule.rule_id, kind)  # 그 뒤 다른 요청의 삭제·값 바꾸기가 끝난다
        return original()

    monkeypatch.setattr(store, "flush", racing_flush)
    with pytest.raises(AutoRuleError) as err:
        engine.allow_from_offer(rule)
    assert err.value.status == 409
    _check(engine, rule.rule_id, kind)


@pytest.mark.parametrize("kind", ["delete", "change"])
def test_invalidation_does_not_overwrite_a_concurrent_delete_or_change(api, monkeypatch, kind):
    _after_allow(api)
    engine = _engine()
    (rule,) = engine.store.list()

    def racing_invalid(current):
        _change(engine, current.rule_id, kind)  # 판단 사이 다른 요청이 지우거나 값을 바꿨다
        return "허락한 뒤 내용이 바뀌어 자동으로 하기를 껐어요. 다시 허락해 주세요."

    monkeypatch.setattr(engine, "_invalid_reason", racing_invalid)
    _inject(api, inputs=("power",))
    _wait_run(api, lambda r: r["outcome"] == "blocked")
    _check(engine, rule.rule_id, kind)
