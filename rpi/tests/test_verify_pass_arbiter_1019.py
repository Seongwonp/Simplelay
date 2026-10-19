"""확인 주행도 일반 실행과 같은 기계 제어권(ControlArbiter)을 잡는다(10/19 검토 #8).

옛 경로는 ``service.status().running``을 본 뒤 중재자 밖에서 돌아, 그 사이 일반 실행이 시작되면 둘이
같은 모션을 동시에 움직일 수 있었다. 모의 컨트롤러로만 시험한다(실물 미검증).
"""

from __future__ import annotations

import threading
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app
from rpi.services.control_arbiter import ControlArbiter, ControlConflictError

H = np.array([[2.1, 0.3, 150.0], [0.1, 2.4, 90.0], [0.0004, 0.0006, 1.0]])


def px(x_mm, y_mm):
    u, v, w = H @ np.array([x_mm, y_mm, 1.0])
    return [float(u / w), float(v / w)]


MAPPING = {
    "photo_width": 1200, "photo_height": 900,
    "corners_px": [px(0, 0), px(300, 0), px(300, 200), px(0, 200)],
    "buttons_px": {"BT-08": px(100, 60), "BT-05": px(250, 150)}, "stop_button": "BT-06",
    "stop_px": px(200, 150), "park_px": px(20, 185),
}


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    for name in ("SIMPLELAY_MOTION_X_MIN_MM", "SIMPLELAY_MOTION_X_MAX_MM",
                 "SIMPLELAY_MOTION_Y_MIN_MM", "SIMPLELAY_MOTION_Y_MAX_MM"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_FRAME_W_MM", "300")
    monkeypatch.setenv("SIMPLELAY_FRAME_H_MM", "200")
    caches = (deps.get_appliance_registry, deps.get_service, deps.get_control_arbiter)
    for dep in caches:
        dep.cache_clear()
    c = TestClient(app)
    assert c.put("/appliances/microwave/mapping", json=MAPPING).status_code == 200
    yield c
    for dep in caches:
        dep.cache_clear()


def _wait_done(c, timeout=5.0):
    deadline = time.monotonic() + timeout
    while (doc := c.get("/appliances/microwave/verify-pass").json())["state"] == "running":
        assert time.monotonic() < deadline
        time.sleep(0.01)
    return doc


def test_verify_pass_is_refused_when_execution_holds_control(client):
    """상태 확인 뒤 일반 실행이 먼저 제어권을 잡은 경우 — 확인 주행은 움직이지 않고 409."""
    arbiter = deps.get_control_arbiter()
    arbiter.acquire(ControlArbiter.EXECUTION)
    try:
        res = client.post("/appliances/microwave/verify-pass")
        assert res.status_code == 409, res.text
    finally:
        arbiter.release(ControlArbiter.EXECUTION)
    assert client.get("/appliances/microwave/verify-pass").status_code == 404  # 시작하지 않음


def test_verify_pass_holds_control_for_the_whole_pass(client, monkeypatch):
    import rpi4.services.stop_hold as stop_hold

    entered, release = threading.Event(), threading.Event()
    original = stop_hold.run_verify_pass

    def blocking(motion, targets, on_progress):
        entered.set()
        assert release.wait(5)
        return original(motion, targets, on_progress)

    monkeypatch.setattr(stop_hold, "run_verify_pass", blocking)
    arbiter = deps.get_control_arbiter()
    assert client.post("/appliances/microwave/verify-pass").status_code == 202
    try:
        assert entered.wait(5)
        with pytest.raises(ControlConflictError):  # 진행 중에는 일반 실행이 제어권을 얻지 못한다
            arbiter.acquire(ControlArbiter.EXECUTION)
    finally:
        release.set()
    assert _wait_done(client)["state"] == "done"
    deadline = time.monotonic() + 2
    while arbiter.holder is not None:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    arbiter.acquire(ControlArbiter.EXECUTION)  # 끝나면 돌려준다
    arbiter.release(ControlArbiter.EXECUTION)
