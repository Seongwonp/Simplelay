"""SIMPLELAY_DEMO_PACING 게이팅 -- 기본은 페이싱 없음, 켜면 주입."""

from rpi.controller import ClosedLoopController
from rpi.controller.ports import SleepingRetryWaiter
from rpi.services.controller_factory import build_controller


def test_no_pacing_by_default(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_DEMO_PACING", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    controller = build_controller()
    assert isinstance(controller, ClosedLoopController)
    # 기본은 지연 0 -- 페이서 미주입, 대기자는 NoOp(SleepingRetryWaiter 아님)
    assert controller._step_pacer is None
    assert not isinstance(controller._retry_waiter, SleepingRetryWaiter)


def test_demo_pacing_injects_pacer_and_sleeping_waiter(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    monkeypatch.setenv("SIMPLELAY_DEMO_PACING", "1")
    monkeypatch.setenv("SIMPLELAY_DEMO_PACING_SECONDS", "0")  # 테스트는 실제로 안 잔다
    controller = build_controller()
    assert controller._step_pacer is not None
    assert isinstance(controller._retry_waiter, SleepingRetryWaiter)
    # 주입된 페이서는 호출돼도 (0초) 예외 없이 통과
    controller._step_pacer("즉석밥", 0)
