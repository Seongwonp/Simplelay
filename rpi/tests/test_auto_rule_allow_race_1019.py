"""외부 검토 2026-10-19 (2): '다음부터도 자동으로' 허용 저장이 읽은 규칙을 잠금 밖에서 무조건 저장했다.

허용 요청이 같은 조건의 규칙을 읽은 뒤 저장하기 전에 목록에서 그 규칙을 지우거나 끄면, 허용 저장이 그 변경을 덮어
지운 규칙이 되살아나거나 끈 규칙이 다시 켜졌다. 이제 철회와 같은 전송권 잠금 안에서 읽은 그대로인지 보고 바꾼다.

전부 모의 ThinQ(프로세스 안 모의 클라이언트)다.
"""

from __future__ import annotations

import pytest

from rpi.routines.auto_rules import AutoRuleError
from rpi.tests.test_auto_rules import _allow, _engine, api  # noqa: F401


def _race_on_first_list(monkeypatch, engine, change):
    """허용 저장이 같은 규칙을 찾으려고 목록을 읽은 바로 뒤에 ``change``(다른 요청의 삭제·끄기)가 끝난다."""
    store = engine.store
    original = store.list
    state = {"done": False}

    def racing():
        snapshot = original()
        if not state["done"]:
            state["done"] = True
            change()
        return snapshot

    monkeypatch.setattr(store, "list", racing)


def test_allow_from_offer_does_not_resurrect_a_rule_deleted_meanwhile(api, monkeypatch):
    _allow(api)
    engine = _engine()
    (rule,) = engine.store.list()
    _race_on_first_list(monkeypatch, engine, lambda: engine.delete(rule.rule_id))
    with pytest.raises(AutoRuleError):
        engine.allow_from_offer(rule)
    assert engine.store.get(rule.rule_id) is None


def test_allow_from_offer_does_not_turn_back_on_a_rule_turned_off_meanwhile(api, monkeypatch):
    _allow(api)
    engine = _engine()
    (rule,) = engine.store.list()
    _race_on_first_list(monkeypatch, engine, lambda: engine.set_enabled(rule.rule_id, False))
    with pytest.raises(AutoRuleError):
        engine.allow_from_offer(rule)
    assert engine.store.get(rule.rule_id).enabled is False
