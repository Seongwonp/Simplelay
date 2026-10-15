"""비상정지 걸림이면 ThinQ 직접·승인 명령도 보내지 않는다(2026-10-15 외부 검토 H1).

자동 실행은 걸림을 보고 막았지만(``test_auto_rules.test_latched_outlet_estop_blocks_auto``) 폰의 직접 조작
(``POST /thinq/command``)과 승인 카드는 그대로 클라우드에 보냈다. 받을 때(412)와 보내기 직전(not_dispatched) 두 곳에서 막는다.
전원 끄기도 예외로 두지 않는다. 전부 모의 ThinQ(프로세스 안 모의 클라이언트)다.
"""

from __future__ import annotations

from rpi.api import deps
from rpi.tests.test_auto_rules import _card, _controls, api  # noqa: F401 -- api는 fixture
from rpi.tests.test_cook_done_card import _wait_done


def _command(api, action="set_wind_strength", args=None):  # noqa: F811
    return api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": action,
                                            "args": args or {"wind_strength": "HIGH"}})


def test_direct_command_is_refused_while_latched(api, monkeypatch):  # noqa: F811
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True)
    before = len(_controls())
    res = _command(api)
    assert res.status_code == 412, res.text
    assert "비상정지" in res.text
    assert len(_controls()) == before


def test_power_off_is_not_an_exception(api, monkeypatch):  # noqa: F811
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True)
    before = len(_controls())
    res = _command(api, "set_power", {"power": "POWER_OFF"})
    assert res.status_code == 412, res.text
    assert len(_controls()) == before


def test_latch_between_accept_and_dispatch_is_not_sent(api, monkeypatch):  # noqa: F811
    """받을 때는 풀려 있다가 보내기 전에 걸리면 보내지 않고 사유를 남긴다."""
    calls = {"n": 0}

    def latched():
        calls["n"] += 1
        return calls["n"] > 1  # 첫 확인(받을 때)만 풀림

    service = deps.get_service()
    monkeypatch.setattr(service, "estop_latched", latched)
    before = len(_controls())
    res = _command(api)
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    status = api.get("/status").json()
    assert status["last_receipt"] == "not_dispatched", status
    assert "비상정지" in (status.get("last_detail") or ""), status
    assert len(_controls()) == before


def test_approved_card_is_not_sent_while_latched(api, monkeypatch):  # noqa: F811
    card = _card(api)
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True)
    before = len(_controls())
    res = api.post(f"/suggestions/{card['id']}/approve", json={})
    assert res.status_code == 412, res.text
    assert "비상정지" in res.text
    assert len(_controls()) == before


def test_not_latched_still_sends(api):  # noqa: F811
    before = len(_controls())
    res = _command(api)
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    assert len(_controls()) == before + 1
