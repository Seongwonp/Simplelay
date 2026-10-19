"""/stop의 잠금 안 순서 — 로컬 정지나 노드 목록 만들기가 예외를 올려도 정지 표시·다른 노드·ThinQ 정지는 간다(2026-10-19 LOW).

예전 순서는 로컬 ``request_stop()`` → 노드 목록(``_stoppable_nodes``) → 단계 사이 정지 표시(``_stop_sticky``) → ThinQ 정지였다.
앞의 둘 중 하나가 예외를 올리면 그 뒤가 전부 빠졌다 — 정지 표시가 안 서 루틴의 남은 단계가 나가고, 다른 노드와 ThinQ에는
정지가 가지 않았다. 이제 표시를 먼저 세우고, 두 호출은 각각 감싸 로그만 남긴다.
"""

from __future__ import annotations

import threading
import time

from rpi.api.service import SimpleLayService
from rpi.controller import ExecutionMode, ExecutionResult, ExecutionStatus
from rpi.intent.rules import RuleBasedIntentResolver
from rpi.services.thinq import StopOutcome


class _BlockingController:
    execution_mode = ExecutionMode.MOCK

    def __init__(self, stop_raises: bool):
        self.release = threading.Event()
        self.entered = threading.Event()
        self.stop_raises = stop_raises

    def execute(self, buttons):
        self.entered.set()
        self.release.wait(5)
        return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, ())

    def request_stop(self):
        self.release.set()
        if self.stop_raises:
            raise RuntimeError("local stop broke")


class _Node:
    execution_mode = ExecutionMode.MOCK

    def __init__(self):
        self.stops = 0

    def execute(self, buttons):
        return ExecutionResult(ExecutionStatus.SUCCEEDED, ())

    def request_stop(self):
        self.stops += 1
        return True


class _Thinq:
    def __init__(self):
        self.stops = 0

    def request_stop(self):
        self.stops += 1
        return StopOutcome.IDLE


def _running_service(stop_raises: bool):
    controller = _BlockingController(stop_raises)
    node, thinq = _Node(), _Thinq()
    service = SimpleLayService(RuleBasedIntentResolver(), controller, thinq_controller=thinq,
                               system_controllers={"fan_node": node})
    service.submit_buttons(("시작",), "microwave")
    assert controller.entered.wait(2)
    return service, controller, node, thinq


def _finish(service, controller):
    controller.release.set()
    deadline = time.monotonic() + 3
    while service.status().running and time.monotonic() < deadline:
        time.sleep(0.01)


def test_local_stop_exception_still_sets_sticky_and_stops_nodes_and_thinq():
    service, controller, node, thinq = _running_service(stop_raises=True)
    try:
        report = service.emergency_stop_report()
        assert report.was_running is True
        assert service._stop_sticky is True  # noqa: SLF001
        assert node.stops == 1
        assert thinq.stops == 1
    finally:
        _finish(service, controller)


def test_node_listing_exception_still_sets_sticky_and_stops_thinq(monkeypatch):
    service, controller, _node, thinq = _running_service(stop_raises=False)

    def broken():
        raise RuntimeError("registry broke")

    monkeypatch.setattr(service, "_stoppable_nodes", broken)
    try:
        report = service.emergency_stop_report()
        assert report.was_running is True
        assert service._stop_sticky is True  # noqa: SLF001
        assert thinq.stops == 1
    finally:
        _finish(service, controller)
