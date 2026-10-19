"""가전이 놓인 곳(방) — 폰이 보낸 ``location``을 본체가 버리던 것(2026-10-19 첫 사용 점검).

폰은 본체 사본(GET /appliances)을 받아 자기 기록을 바꾼다. 본체가 ``location``을 저장·응답하지 않으면 그때 방 이름이
사라진다. 선택 필드다 — 보내지 않는 옛 폰이 저장해도 이미 저장된 방 이름은 지우지 않고, 빈 문자열이면 지운다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app
from rpi.services import ApplianceRegistry
from rpi.services.appliance_registry import ApplianceButtonDef, ApplianceDef
from rpi.services.persistence import SimpleLayDb

FAN = {"name": "선풍기", "rows": 1, "cols": 2, "buttons": [
    {"id": "F-01", "label": "전원", "x": 0, "y": 0},
    {"id": "F-02", "label": "약풍", "x": 1, "y": 0}]}


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    yield TestClient(app)
    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()


def _listed(client, appliance_id: str) -> dict:
    return next(a for a in client.get("/appliances").json() if a["id"] == appliance_id)


def test_location_is_saved_returned_and_kept_by_old_phones(client):
    saved = client.put("/appliances/custom_fan", json={**FAN, "location": " 거실 "})
    assert saved.status_code == 200, saved.text
    assert saved.json()["location"] == "거실"
    assert _listed(client, "custom_fan")["location"] == "거실"

    # location을 모르는 옛 폰이 이름만 고쳐 저장 — 방 이름은 그대로
    renamed = client.put("/appliances/custom_fan", json={**FAN, "name": "큰 선풍기"})
    assert renamed.status_code == 200 and renamed.json()["location"] == "거실"

    moved = client.put("/appliances/custom_fan", json={**FAN, "location": "안방"})
    assert moved.json()["location"] == "안방"
    cleared = client.put("/appliances/custom_fan", json={**FAN, "location": ""})
    assert cleared.json()["location"] is None


def test_appliance_without_location_reports_null(client):
    assert client.put("/appliances/custom_fan", json=FAN).json()["location"] is None
    assert _listed(client, "custom_fan")["location"] is None


def test_too_long_location_is_rejected(client):
    res = client.put("/appliances/custom_fan", json={**FAN, "location": "가" * 41})
    assert res.status_code == 422


def test_location_survives_restart(tmp_path):
    db_path = str(tmp_path / "location.db")
    fan = ApplianceDef(appliance_id="custom_fan", name="선풍기", rows=1, cols=1,
                       buttons=(ApplianceButtonDef(id="F-01", label="전원", x=0, y=0),),
                       is_custom=True, location="거실")
    ApplianceRegistry(store=SimpleLayDb(db_path)).register(fan)
    assert ApplianceRegistry(store=SimpleLayDb(db_path)).get("custom_fan").location == "거실"
