"""자동 실행 경계(3차 평가 2026-10-14) — 실제 API·ThinQ controller·공식 SDK·저장소 안 모의 클라우드 배선.

H1: 자동 실행의 마지막 검사가 controller의 프로필·상태 조회(네트워크 대기)보다 앞서 있었다. 조회를 기다리는 동안
    규칙을 끄거나 바꾸거나 지우면, 조회가 끝난 뒤 **전송 직전**에 다시 판정해 보내지 않아야 한다(모의 클라우드 POST 0건).
    정지는 그 네트워크 대기를 기다리지 않는다.

**실제 ThinQ 클라우드·실가전·실제 CT 판정은 쓰지 않는다.** 네트워크 대기는 시험이 SDK 호출 앞에 건 문으로 흉내 낸다.
"""

from __future__ import annotations

import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, _wait_run, cloud  # noqa: F401
from rpi.tests.test_cook_done_card import _inject, _reset

pytest.importorskip("thinqconnect")


class _NetworkGate:
    """ThinQ controller가 보내기 전에 하는 SDK 조회(``method``) 하나를 문 앞에 세운다(시험이 열 때까지)."""

    def __init__(self, monkeypatch, method: str) -> None:
        from rpi.services.thinq import sdk_client

        self.entered = threading.Event()
        self.release = threading.Event()
        self.armed = False
        original = getattr(sdk_client.SdkThinqClient, method)
        gate = self

        def gated(client, *args, **kwargs):
            if gate.armed and _called_from_controller_execute():
                gate.armed = False
                gate.entered.set()
                assert gate.release.wait(10), "시험이 문을 열지 않았다"
            return original(client, *args, **kwargs)

        monkeypatch.setattr(sdk_client.SdkThinqClient, method, gated)


def _called_from_controller_execute() -> bool:
    frame = sys._getframe(1)
    while frame is not None:
        if frame.f_code.co_name == "_execute" and frame.f_code.co_filename.endswith("controller.py"):
            return True
        frame = frame.f_back
    return False


def _rule(api):
    rules = api.get("/routines/auto-rules").json()
    assert len(rules) == 1
    return rules[0]


def _change(api, change: str) -> None:
    rule = _rule(api)
    if change == "off":
        res = api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False})
    elif change == "value_reallowed":
        res = api.put(f"/routines/auto-rules/{rule['id']}", json={"value": "MID"})
        assert res.status_code == 200, res.text
        res = api.post(f"/routines/auto-rules/{rule['id']}/enable",
                       json={"enabled": True, "fingerprint": res.json()["fingerprint"]})
    elif change == "delete":
        res = api.delete(f"/routines/auto-rules/{rule['id']}")
    else:  # pragma: no cover
        raise AssertionError(change)
    assert res.status_code == 200, res.text


@pytest.mark.parametrize("method", ["get_status", "get_profile"])
@pytest.mark.parametrize("change", ["off", "value_reallowed", "delete"])
def test_rule_revoked_while_the_controller_waits_on_the_network_sends_nothing(monkeypatch, tmp_path, cloud,
                                                                             method, change):
    """H1: dispatch_guard를 지난 뒤 controller가 프로필·상태 조회를 기다리는 사이 끄기·값 변경(다시 허용 포함)·삭제 →
    조회가 끝나도 모의 클라우드 POST 0건, 기록은 '보내지 않음'."""
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        gate = _NetworkGate(monkeypatch, method)
        gate.armed = True
        _inject(api, inputs=("power",))
        assert gate.entered.wait(10), "자동 실행이 controller 조회까지 오지 않았다"
        _change(api, change)
        gate.release.set()
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        time.sleep(0.3)
        assert len(cloud.controls()) == before, cloud.controls()[before:]
        assert run["receipt"] == "not_dispatched"
        assert run["outcome"] == "blocked"
        assert "바꿨어요" not in " / ".join(run["notices"])
    finally:
        _reset()


def test_stop_does_not_wait_for_the_controller_network_read_and_nothing_is_sent(monkeypatch, tmp_path, cloud):
    """H1: 조회 대기 중 전체 정지 — /stop은 그 네트워크 대기를 기다리지 않고 돌아오고, 조회가 끝나도 보내지 않는다."""
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        gate = _NetworkGate(monkeypatch, "get_status")
        gate.armed = True
        _inject(api, inputs=("power",))
        assert gate.entered.wait(10)
        started = time.monotonic()
        assert api.post("/stop").status_code == 200
        assert not gate.release.is_set()  # 문이 닫힌 채로 정지가 끝났다
        assert time.monotonic() - started < 5
        assert _rule(api)["enabled"] is False
        gate.release.set()
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        time.sleep(0.3)
        assert len(cloud.controls()) == before
        assert run["receipt"] == "not_dispatched"
    finally:
        _reset()
