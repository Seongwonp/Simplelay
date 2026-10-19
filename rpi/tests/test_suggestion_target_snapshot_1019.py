"""외부 검토 2026-10-19 (1): 승인 카드가 화면에 보인 그때의 가전 설정(보정 판·ThinQ 기기)에 묶이지 않았다.

카드의 명령 지문은 대상 이름·동작·인자·버튼 이름뿐이라, 카드를 띄운 뒤 승인 전에 그 가전을 다시 보정(판 번호가 바뀜)하거나
ThinQ 연결을 다른 기기로 바꾸면 승인이 **새** 좌표·기기로 실행됐다. 이제 카드를 만들 때 대상의 판 번호·보정 버전·ThinQ 기기
ID를 함께 적어 두고, 승인 때(실행 서비스의 시작 게이트 안에서도) 다르면 실행하지 않고 재승인(``ApprovalMismatchError``).
"""

from __future__ import annotations

from datetime import datetime, time as dtime, timezone
from types import SimpleNamespace

import pytest

from rpi.api.thinq_wiring import appliance_for
from rpi.commands import ApprovalMismatchError, Command
from rpi.intent.log import InMemoryUsageLog
from rpi.intent.mock import FixedClock
from rpi.intent.models import PatternConfig, TimeBand
from rpi.intent.patterns import PatternDetector
from rpi.intent.suggestions import ProactiveSuggestionService
from rpi.services.appliance_registry import ApplianceRegistry

HEAT = Command.physical("microwave", ("즉석밥", "시작"))
PURIFIER_ON = Command.thinq("air_purifier", "set_power", {"power": "POWER_ON"})


class _Executor:
    """실행 서비스 흉내 — 시작 게이트(``approval_guard``)를 부른 뒤 받은 승인을 적는다."""

    def __init__(self, registry, before_start=None):
        self._appliance_registry = registry
        self.ran: list = []
        self._before_start = before_start

    def _start(self, approved, kw):
        if self._before_start is not None:
            self._before_start()  # 승인 확인과 실행 시작 사이에 끼어든 변경
        guard = kw.get("approval_guard")
        if guard is not None:
            guard()
        self.ran.append(approved)

    def submit_approved(self, approved, **kw):
        self._start(approved, kw)
        return "job-1"

    def execute_approved(self, approved, **kw):
        self._start(approved, kw)
        return SimpleNamespace(status=SimpleNamespace(value="succeeded"))


def _service(registry, command, before_start=None):
    clock = FixedClock(datetime(2026, 10, 19, 20, tzinfo=timezone.utc))
    executor = _Executor(registry, before_start)
    detector = PatternDetector(InMemoryUsageLog(), clock, PatternConfig(
        minimum_occurrences=3, time_bands=(TimeBand("저녁", dtime(17), dtime(21)),)))
    svc = ProactiveSuggestionService(detector, clock, executor,
                                     scenario_resolver=lambda _sid: (command,))
    card = svc.create_scenario_suggestion(scenario_id="sc-test", purpose="할까요?", commands=(command,),
                                          summaries=("요약",), reason="시험", is_demo=True)
    return svc, executor, card


def _recalibrate(registry):
    registry.apply_calibration("microwave", version="v2", coords={"BT-08": (40.0, 60.0)})


def _registry_with_purifier(device_id):
    registry = ApplianceRegistry()
    registry.register_system(appliance_for("air_purifier", device_id, "공기청정기"))
    return registry


def test_recalibrated_appliance_needs_a_new_approval():
    registry = ApplianceRegistry()
    svc, executor, card = _service(registry, HEAT)
    _recalibrate(registry)
    with pytest.raises(ApprovalMismatchError):
        svc.approve_submit(card.suggestion_id)
    assert executor.ran == []
    assert svc.pending() == ()  # 카드를 내리고 재승인을 받는다


def test_thinq_rebinding_to_another_device_needs_a_new_approval():
    registry = _registry_with_purifier("dev-A")
    svc, executor, card = _service(registry, PURIFIER_ON)
    registry.unregister_system("air_purifier")
    registry.register_system(appliance_for("air_purifier", "dev-B", "공기청정기"))
    with pytest.raises(ApprovalMismatchError):
        svc.approve(card.suggestion_id)
    assert executor.ran == []


def test_change_between_the_check_and_the_execution_start_is_caught_at_the_start_gate():
    registry = ApplianceRegistry()
    svc, executor, card = _service(registry, HEAT, before_start=lambda: _recalibrate(registry))
    with pytest.raises(ApprovalMismatchError):
        svc.approve_submit(card.suggestion_id)
    assert executor.ran == []


def test_unchanged_target_still_runs():
    registry = _registry_with_purifier("dev-A")
    svc, executor, card = _service(registry, PURIFIER_ON)
    assert svc.approve_submit(card.suggestion_id) == "job-1"
    assert len(executor.ran) == 1
