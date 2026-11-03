"""가열 종료(CT 끝) 사건 때 공기청정기가 **꺼짐으로 읽혔으면** 바람 세기 카드·자동 실행을 내지 않는다.

꺼진 공기청정기는 전원 밖의 명령(바람 세기)을 클라우드가 거절한다(2304, 실물 확인). 그래서 꺼짐으로 읽혔으면 바람 세기
대신 '공기청정기가 꺼져 있어요. 켤까요?'(전원 켜기 한 단계) 카드를 띄우고, 자동 실행 규칙은 보내지 않고 이유를 남긴 뒤
그 켜기 카드로 묻는다. 전원은 이미 한 상태 조회의 기억(``ThinqPowerCache``)만 본다 — 모르면 종전처럼 바람 세기를 묻는다.

전부 모의(ThinQ mock·저장소 안 모의 클라우드, 주입한 가열 종료 사건)다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_cook_done_card import _cards, _inject, _wait_done
from rpi.tests.test_cook_done_card import api  # noqa: F401 -- 고정물


def _read_status(client):
    res = client.get("/thinq/status/air_purifier")
    assert res.status_code == 200, res.text
    return res.json()["state"]


def _power_on(client):
    res = client.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_power",
                                              "args": {"power": "POWER_ON"}})
    assert res.status_code == 200, res.text
    assert _wait_done(client, res.json()["job_id"])["last_status"] == "succeeded"


def test_purifier_read_off_offers_the_power_on_card_instead_of_wind(api):  # noqa: F811
    from rpi.api.thinq_wiring import get_thinq_client

    assert _read_status(api)["operation"]["airPurifierOperationMode"] == "POWER_OFF"
    _inject(api, inputs=("power",))
    assert _cards(api) == []  # 바람 세기 카드는 없다
    cards = _cards(api, "cook_done_air_power_on")
    assert len(cards) == 1
    card = cards[0]
    assert card["purpose"] == "공기청정기가 꺼져 있어요. 켤까요?"
    assert [(c["action"], c["args"]) for c in card["commands"]] == [("set_power", {"power": "POWER_ON"})]
    assert "멈춘 것 같아요" in card["reason"] and "조리 완료가 아닐 수 있어요" in card["reason"]
    assert "조리가 끝" not in card["reason"] and "조리 완료했" not in card["reason"]
    # 켜기는 자동 실행 허용 규칙의 범위가 아니다 — '다음부터 묻지 않고 하기'를 내지 않는다.
    assert not card.get("auto_rule_offer")
    assert get_thinq_client().controls == []  # 카드는 제안일 뿐


def test_power_on_card_runs_and_the_next_event_asks_for_wind_again(api):  # noqa: F811
    from rpi.api.thinq_wiring import get_thinq_client

    _read_status(api)
    _inject(api, inputs=("power",))
    card = _cards(api, "cook_done_air_power_on")[0]
    res = api.post(f"/suggestions/{card['id']}/approve")
    assert res.status_code == 200, res.text
    _wait_done(api, res.json()["job_id"])
    assert get_thinq_client().controls[-1][1] == {"operation": {"airPurifierOperationMode": "POWER_ON"}}
    _read_status(api)  # 켜짐으로 읽혔다
    _inject(api, inputs=("power",))
    assert len(_cards(api)) == 1
    assert _cards(api, "cook_done_air_power_on") == []


def test_purifier_read_on_keeps_the_wind_card(api):  # noqa: F811
    _power_on(api)
    assert _read_status(api)["operation"]["airPurifierOperationMode"] == "POWER_ON"
    _inject(api, inputs=("power",))
    assert [c["purpose"] for c in _cards(api)] == ["공기청정기 바람을 세게 할까요?"]
    assert _cards(api, "cook_done_air_power_on") == []


def test_unknown_power_still_asks_for_wind(api):  # noqa: F811
    """전원을 모르면(조회 기억 없음) 종전처럼 묻는다 — 지어내지 않는다."""
    from rpi.api.thinq_wiring import get_power_cache

    get_power_cache().clear()
    _inject(api, inputs=("power",))
    assert len(_cards(api)) == 1
    assert _cards(api, "cook_done_air_power_on") == []


def test_stale_power_memory_counts_as_unknown():
    from rpi.services.thinq.power import POWER_STALE_SECONDS, ThinqPowerCache

    class Cap:
        action, resource, keys, location = "set_power", "operation", ("airPurifierOperationMode",), None

    class Binding:
        capabilities = (Cap(),)

    now = [100.0]
    cache = ThinqPowerCache(monotonic=lambda: now[0])
    assert cache.power("air_purifier") is None
    cache.observe("air_purifier", Binding(), {"operation": {"airPurifierOperationMode": "POWER_OFF"}})
    assert cache.power("air_purifier") == "off"
    now[0] += POWER_STALE_SECONDS + 1
    assert cache.power("air_purifier") is None


# ── 자동 실행 허용 규칙(가열 종료 → 바람 세기) ────────────────────────────────────────────────────


def test_auto_rule_does_not_send_to_an_off_purifier_and_asks_to_power_on(monkeypatch, tmp_path):
    pytest.importorskip("thinqconnect")
    from rpi.tests.test_auto_rule_e2e import _allow, _env, _wait_run
    from rpi.tests.test_cook_done_card import _reset
    from rpi.tools.fake_thinq_cloud import FakeThinqCloud

    cloud = FakeThinqCloud()
    cloud.start()
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        device = cloud.device_id("air_purifier")
        _allow(api)  # 규칙 허용(이번 실행의 확인 조회가 전원을 읽는다 — 모의 클라우드 공기청정기는 꺼져 있다)
        assert cloud.state(device)["operation"]["airPurifierOperationMode"] == "POWER_OFF"
        before = len(cloud.controls())
        _inject(api, inputs=("power",))
        run = _wait_run(api, lambda r: r["outcome"] == "blocked")
        time.sleep(0.3)
        assert len(cloud.controls()) == before  # 꺼진 공기청정기에 바람 세기를 보내지 않았다
        assert run["reason"] == "공기청정기가 꺼져 있어 자동으로 하지 않았어요. 켤지 먼저 물어볼게요."
        assert [r for r in api.get("/routines/auto-rules/runs").json() if r["outcome"] == "sent"] == []
        assert _cards(api) == []
        assert [c["purpose"] for c in _cards(api, "cook_done_air_power_on")] == ["공기청정기가 꺼져 있어요. 켤까요?"]
        assert api.get("/routines/auto-rules").json()[0]["enabled"] is True  # 규칙은 그대로 켜져 있다
    finally:
        _reset()
        cloud.stop()
