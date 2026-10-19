"""실행 중 받은 정지가 ThinQ 단계의 '확인 뒤 ~ 보내기 전' 틈에 와도 클라우드로 보내지 않는다(2026-10-19 검토 HIGH).

단계 확인(``_run_plan``의 정지 표시 확인)을 지난 뒤, 실행기가 '보내는 중(pending)'으로 들어가기 전에 /stop이 오면 실행기의
``request_stop``은 할 일이 없다고 답한다(idle). 예전에는 보내기 직전 확인이 비상정지 걸림만 봐서 그대로 보냈다 — 이제 같은
자리에서 이번 실행의 정지 표시도 보고, 결과는 '멈춤·보내지 않음'으로 남긴다. 전부 모의 ThinQ다.
"""

from __future__ import annotations

from rpi.api import deps
from rpi.tests.test_auto_rules import _controls, api  # noqa: F401 -- api는 fixture
from rpi.tests.test_cook_done_card import _wait_done


def _run_with_stop_at(api, monkeypatch, stop_at_call: int):  # noqa: F811
    service = deps.get_service()
    calls = {"n": 0, "report": None}

    def latched():
        calls["n"] += 1
        if calls["n"] == stop_at_call:
            calls["report"] = service.emergency_stop_report()
        return False

    monkeypatch.setattr(service, "estop_latched", latched)
    before = len(_controls())
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_wind_strength",
                                           "args": {"wind_strength": "HIGH"}})
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    return calls, before


def test_stop_between_step_check_and_dispatch_is_not_sent(api, monkeypatch):  # noqa: F811
    # 1번째 확인은 받을 때(412 판정), 2번째는 실행 스레드에서 실행기에 넘기기 전 — 그 틈에 /stop(실행기는 아직 idle)
    calls, before = _run_with_stop_at(api, monkeypatch, 2)
    assert calls["report"] is not None and calls["report"].was_running is True
    assert len(_controls()) == before, "정지를 받은 뒤 클라우드로 보냈다"
    status = api.get("/status").json()
    assert status["last_receipt"] == "not_dispatched", status
    assert status["last_status"] == "stopped", status


def test_stop_after_lookup_right_before_post_is_not_sent(api, monkeypatch):  # noqa: F811
    # 3번째는 실행기가 프로필·상태 조회를 마친 뒤 보내기 직전 확인
    calls, before = _run_with_stop_at(api, monkeypatch, 3)
    assert calls["report"] is not None
    assert len(_controls()) == before, "정지를 받은 뒤 클라우드로 보냈다"
    status = api.get("/status").json()
    assert status["last_receipt"] == "not_dispatched", status
    assert status["last_status"] == "stopped", status
