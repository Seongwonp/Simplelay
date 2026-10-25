"""누름 장치(로컬 갠트리)가 누를 수 있는 기본 가전을 정한다 (2026-10-18, 사용자 요청).

실물 갠트리는 1대이고 전자레인지 위에만 있다. 예전에는 기본 가전(전자레인지·인덕션)을 모두 누름 장치 대상으로 보아
인덕션도 '준비됐어요'(operable)로 나왔다. ``SIMPLELAY_GANTRY_APPLIANCES``(쉼표 목록, 기본 ``microwave``)에 든
기본 가전만 누름 장치로 실행하고, 나머지 기본 가전은 '설정이 필요해요'(needs_setup) + 실행 거절(412, 쉬운 말 사유).
사용자 등록 가전(is_custom)의 판정은 바꾸지 않는다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.api.service import GANTRY_ABSENT_REASON
from rpi.main import app

_FAN = {
    "name": "선풍기",
    "rows": 1,
    "cols": 2,
    "buttons": [
        {"id": "F-01", "label": "전원", "x": 0, "y": 0},
        {"id": "F-02", "label": "약풍", "x": 1, "y": 0},
    ],
}

_DEPS = (deps.get_appliance_registry, deps.get_service, deps.get_readiness_registry,
         deps.get_node_registry, deps.get_job_history)


def _client(monkeypatch, gantry: str | None, local: str | None = None):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    monkeypatch.delenv("SIMPLELAY_DB_PATH", raising=False)
    if local is None:
        monkeypatch.delenv("SIMPLELAY_LOCAL_APPLIANCES", raising=False)
    else:
        monkeypatch.setenv("SIMPLELAY_LOCAL_APPLIANCES", local)
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")  # 내장 가전을 목록에 보인다
    if gantry is None:
        monkeypatch.delenv("SIMPLELAY_GANTRY_APPLIANCES", raising=False)
    else:
        monkeypatch.setenv("SIMPLELAY_GANTRY_APPLIANCES", gantry)
    for dep in _DEPS:
        dep.cache_clear()
    return TestClient(app)


@pytest.fixture(autouse=True)
def _clean():
    yield
    for dep in _DEPS:
        dep.cache_clear()


def _by_id(client):
    res = client.get("/appliances")
    assert res.status_code == 200
    return {a["id"]: a for a in res.json()}


def test_default_only_microwave_is_on_the_gantry(monkeypatch):
    client = _client(monkeypatch, None)
    items = _by_id(client)
    assert items["microwave"]["readiness"] == "operable"
    assert items["microwave"]["can_execute"] is True
    induction = items["induction"]
    assert induction["readiness"] == "needs_setup"
    assert induction["can_execute"] is False
    assert induction["readiness_reasons"] == [GANTRY_ABSENT_REASON]
    # GET /readiness도 같은 판정
    r = client.get("/readiness/induction").json()
    assert (r["state"], r["can_execute"], r["reasons"]) == ("needs_setup", False, [GANTRY_ABSENT_REASON])
    assert r["runs_locally"] is False


def test_execute_on_induction_is_refused_in_plain_words(monkeypatch):
    client = _client(monkeypatch, None)
    res = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "induction"})
    assert res.status_code == 412, res.text
    assert "누름 장치" in res.json()["detail"]
    # 전자레인지는 그대로 받는다
    ok = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert ok.status_code == 200, ok.text


def test_env_can_put_induction_on_the_gantry(monkeypatch):
    client = _client(monkeypatch, "microwave, induction")
    items = _by_id(client)
    assert items["induction"]["readiness"] == "operable"
    assert items["induction"]["can_execute"] is True


def test_env_without_microwave_takes_it_off(monkeypatch):
    client = _client(monkeypatch, "induction")
    items = _by_id(client)
    assert items["microwave"]["readiness"] == "needs_setup"
    assert items["induction"]["readiness"] == "operable"


def test_custom_appliance_judgement_is_unchanged(monkeypatch):
    client = _client(monkeypatch, None)
    assert client.put("/appliances/custom_fan", json=_FAN).status_code == 200
    fan = _by_id(client)["custom_fan"]
    # 노드도 로컬 배선도 없는 사용자 가전 — 종전처럼 '연결 안 됨'(누름 장치 사유가 아니다).
    assert fan["can_execute"] is False
    assert GANTRY_ABSENT_REASON not in fan["readiness_reasons"]


def test_custom_appliance_wired_locally_still_runs(monkeypatch):
    client = _client(monkeypatch, None, local="custom_fan")
    assert client.put("/appliances/custom_fan", json=_FAN).status_code == 200
    fan = _by_id(client)["custom_fan"]
    assert fan["readiness"] == "operable" and fan["can_execute"] is True


@pytest.mark.parametrize("gantry", ["induction", ""])
def test_execute_without_appliance_id_gets_the_same_gantry_check(monkeypatch, gantry):
    """대상 없는 실행도 누름 장치 대상 판정을 거친다(검토 2026-10-19 #1).

    대상 없는 ``/execute``는 RPi4에 내장 갠트리 가전(전자레인지)을 대상으로 싣는다. 예전에는 ``runs_locally(None)``이
    늘 참이라 누름 장치를 인덕션 위로 옮기거나 목록을 비워도 전자레인지 버튼 좌표로 눌렀다. 대상을 밝힌 요청과 같이 412.
    """
    client = _client(monkeypatch, gantry)
    explicit = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert explicit.status_code == 412, explicit.text
    implicit = client.post("/execute", json={"text": "즉석밥 데워줘"})
    assert implicit.status_code == 412, implicit.text
    assert implicit.json()["detail"] == explicit.json()["detail"]
    assert GANTRY_ABSENT_REASON in implicit.json()["detail"]
    assert deps.get_service().runs_locally(None) is False


def test_execute_without_appliance_id_still_runs_when_microwave_is_on_the_gantry(monkeypatch):
    client = _client(monkeypatch, None)
    ok = client.post("/execute", json={"text": "즉석밥 데워줘"})
    assert ok.status_code == 200, ok.text


def test_phone_and_kiosk_match_the_server_gantry_sentence():
    """폰·키오스크는 이 문장을 글자 그대로 비교한다(``kGantryAbsentReason``) — 서버와 같아야 인덕션 안내가 뜬다
    (2026-10-25 용어 통일: "누름 장치가 이 가전에 달려 있지 않아요", 서버·폰·키오스크 같은 커밋)."""
    import pathlib
    import re

    root = pathlib.Path(__file__).resolve().parents[2]
    assert GANTRY_ABSENT_REASON == "누름 장치가 이 가전에 달려 있지 않아요"
    for rel in ("app/lib/models/display_status.dart", "rpi5-touchscreen-app/lib/models/appliance.dart"):
        text = (root / rel).read_text(encoding="utf-8")
        m = re.search(r"const kGantryAbsentReason = '([^']*)';", text)
        assert m is not None, rel
        assert m.group(1) == GANTRY_ABSENT_REASON, rel
