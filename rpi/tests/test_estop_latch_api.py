"""콘센트 모듈 비상정지 걸림 — RPi5 끝단(/status·가전 준비 상태·실행 거절·POST /stop/ack). 2026-10-05 리뷰 H1.

SimulatorController(실제 ActClient ↔ ActExecutor, 모의 모터)로 돈다. 콘센트 모듈은 실행기의
``handle_outlet_estop``을 직접 불러 흉내 낸다 — 실물 미검증.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.services.link_tap import LinkFrameTap


@pytest.fixture
def sim(tmp_path, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "simulator")  # 내장 가전을 목록에 보이게(리허설 런처와 같다)
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.simulator_controller import SimulatorController

    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    registry = deps.get_appliance_registry()
    controller = SimulatorController(step_seconds=0, tap=LinkFrameTap(None, transport="in_memory"))
    service = SimpleLayService(RuleBasedIntentResolver(), controller, appliance_registry=registry)
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        yield TestClient(app), controller
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        controller.close()
        for dep in (deps.get_appliance_registry, deps.get_service):
            dep.cache_clear()


def _trip(controller, reset=None) -> None:
    executor = controller._executor  # noqa: SLF001 - 모의 RPi4 실행기
    if reset is not None:
        executor.set_estop_reset(reset)
    controller._loop.call_soon_threadsafe(executor.handle_outlet_estop, "button")  # noqa: SLF001


def _until(c, pred, timeout=4.0):
    deadline = time.monotonic() + timeout
    while True:
        status = c.get("/status").json()
        if pred(status):
            return status
        assert time.monotonic() < deadline, status
        time.sleep(0.02)


def _microwave(c) -> dict:
    return next(a for a in c.get("/appliances").json() if a["id"] == "microwave")


def test_status_and_readiness_show_latch_and_execute_is_refused(sim):
    c, controller = sim
    assert c.get("/status").json()["estop_latched"] in (None, False)
    _trip(controller)
    status = _until(c, lambda s: s["estop_latched"] is True)
    assert "비상정지가 걸려 있어요" in status["estop_detail"]
    appliance = _microwave(c)
    assert appliance["can_execute"] is False
    assert any("비상정지가 걸려 있어요" in r for r in appliance["readiness_reasons"])
    res = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
    assert res.status_code == 412, res.text  # ApplianceNotReadyError — 준비 안 됨
    assert "비상정지가 걸려 있어요" in res.text
    assert controller._motor.commands == []  # noqa: SLF001 - 아무것도 누르지 않았다


def test_ack_while_button_pressed_keeps_latch(sim):
    c, controller = sim
    _trip(controller, reset=lambda: (False, "estop_button_pressed"))
    _until(c, lambda s: s["estop_latched"] is True)
    res = c.post("/stop/ack")
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["ok"] is False and body["latched"] is True and body["reason"] == "estop_button_pressed"
    assert "눌려 있어요" in body["detail"]
    assert c.get("/status").json()["estop_latched"] is True
    assert _microwave(c)["can_execute"] is False


def test_ack_after_release_clears_latch_and_allows_execute(sim):
    c, controller = sim
    _trip(controller, reset=lambda: (True, None))
    _until(c, lambda s: s["estop_latched"] is True)
    body = c.post("/stop/ack").json()
    assert body["ok"] is True and body["latched"] is False
    assert c.get("/status").json()["estop_latched"] is False
    assert _microwave(c)["can_execute"] is True
    job = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"})
    assert job.status_code == 200, job.text
    status = _until(c, lambda s: s["last_job_id"] == job.json()["job_id"] and not s["running"])
    assert status["last_outcome"] == "success"


def test_stop_ack_requires_api_key(sim, monkeypatch):
    c, _controller = sim
    monkeypatch.setenv("SIMPLELAY_API_KEY", "k" * 32)
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    assert c.post("/stop/ack").status_code == 401


def test_ack_without_latch_reporting_controller_is_409(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    from rpi.api.service import SimpleLayService
    from rpi.controller import ClosedLoopController
    from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.verifier import MockVerifier

    local = ClosedLoopController(MockGrblClient(), MockVerifier([True] * 10), MockAlertSink(),
                                 MockSafetyController())
    service = SimpleLayService(RuleBasedIntentResolver(), local)
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        c = TestClient(app)
        assert c.get("/status").json()["estop_latched"] is None
        assert c.post("/stop/ack").status_code == 409
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
