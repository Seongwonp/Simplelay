"""누름 장치 세트 연결: env에서 이어받기·연결·거절·풀린 가전·자리 확인·옛 RPi4·실행 대상 표시."""

from __future__ import annotations

import asyncio
import json
import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps, kit_router
from rpi.api.service import GANTRY_ABSENT_REASON, KIT_UNVERIFIED_REASON, ApplianceNotReadyError
from rpi.main import app
from rpi.services.act_client import ActClient
from rpi.services.control_arbiter import ControlArbiter
from rpi.services.kit_binding import KitBindingStore
from rpi.services.persistence import SimpleLayDb

FAN = {
    "id": "custom_fan", "name": "선풍기", "rows": 1, "cols": 2,
    "buttons": [{"id": "B01", "label": "전원", "x": 0, "y": 0}, {"id": "B02", "label": "약풍", "x": 1, "y": 0}],
}
MAPPING = {
    "photo_width": 1000, "photo_height": 1000,
    "corners_px": [[100, 100], [900, 100], [900, 900], [100, 900]],
    "buttons_px": {"B01": [300, 300], "B02": [600, 600]},
    "orientation": {"rotation": 0, "flipped": False},
}
_DEPS = (deps.get_appliance_registry, deps.get_service, deps.get_readiness_registry,
         deps.get_node_registry, deps.get_job_history, deps.get_db)


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    monkeypatch.delenv("SIMPLELAY_LOCAL_APPLIANCES", raising=False)
    monkeypatch.delenv("SIMPLELAY_GANTRY_APPLIANCES", raising=False)
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "kit.db"))
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
    monkeypatch.setenv("SIMPLELAY_WORKSPACE_W_MM", "200")
    monkeypatch.setenv("SIMPLELAY_WORKSPACE_H_MM", "200")
    for dep in _DEPS:
        dep.cache_clear()
    yield TestClient(app)
    for dep in _DEPS:
        dep.cache_clear()


def _by_id(client):
    return {a["id"]: a for a in client.get("/appliances").json()}


def _add_mapped_fan(client):
    assert client.put("/appliances/custom_fan", json=FAN).status_code in (200, 201)
    res = client.put("/appliances/custom_fan/mapping", json=MAPPING)
    assert res.status_code == 200, res.text


def _pass(client, appliance_id):
    res = client.post(f"/appliances/{appliance_id}/verify-pass")
    assert res.status_code == 202, res.text
    for _ in range(200):
        doc = client.get(f"/appliances/{appliance_id}/verify-pass").json()
        if doc["state"] != "running":
            return doc
        asyncio.run(asyncio.sleep(0.01))
    raise AssertionError("verify pass did not finish")


def test_env_gantry_keeps_working_with_no_setup(client):
    kit = client.get("/kit").json()
    assert kit["found"] is True and kit["bound_appliance"] == "microwave" and kit["verified"] is True
    assert kit["name"]
    appliances = _by_id(client)
    assert appliances["microwave"]["can_execute"] is True
    assert appliances["induction"]["readiness_reasons"] == [GANTRY_ABSENT_REASON]


def test_bind_refused_without_confirm_names_current_appliance(client):
    _add_mapped_fan(client)
    res = client.post("/kit/bind", json={"appliance_id": "custom_fan"})
    assert res.status_code == 409
    assert "이 세트는" in res.json()["detail"] and client.get("/kit").json()["name"] in res.json()["detail"]
    assert client.get("/kit").json()["bound_appliance"] == "microwave"


def test_confirmed_bind_moves_kit_and_requires_verify_pass(client):
    _add_mapped_fan(client)
    res = client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    assert res.status_code == 200, res.text
    assert res.json()["bound_appliance"] == "custom_fan" and res.json()["verified"] is False
    appliances = _by_id(client)
    assert (appliances["custom_fan"]["can_execute"], appliances["custom_fan"]["readiness_reasons"]) == (
        False, [KIT_UNVERIFIED_REASON])
    blocked = client.post("/execute-buttons", json={"appliance_id": "custom_fan", "buttons": ["전원"]})
    assert blocked.status_code == 412 and KIT_UNVERIFIED_REASON in blocked.json()["detail"]
    # 자리 확인을 마치면 사용자 등록 가전도 세트로 돈다.
    assert _pass(client, "custom_fan")["state"] == "done"
    assert client.get("/kit").json()["verified"] is True
    assert _by_id(client)["custom_fan"]["can_execute"] is True
    assert deps.get_service().runs_locally("custom_fan") is True
    assert client.post("/execute-buttons", json={"appliance_id": "custom_fan", "buttons": ["전원"]}).status_code == 200
    for _ in range(500):  # 제어권은 프로세스 전체에서 하나다 — 끝나기 전에 다음 시험으로 넘기지 않는다
        if not client.get("/status").json()["running"]:
            break
        time.sleep(0.01)
    else:
        raise AssertionError("run did not finish")


def test_released_appliance_keeps_mapping_and_is_refused(client):
    _add_mapped_fan(client)
    client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    microwave = _by_id(client)["microwave"]
    assert (microwave["can_execute"], microwave["readiness_reasons"]) == (False, [GANTRY_ABSENT_REASON])
    refused = client.post("/execute-buttons", json={"appliance_id": "microwave", "buttons": ["전원"]})
    assert refused.status_code == 412 and GANTRY_ABSENT_REASON in refused.json()["detail"]
    # 되돌려 이어도 버튼 자리는 그대로이고 자리 확인을 다시 한다.
    fan_buttons = _by_id(client)["custom_fan"]["buttons"]
    client.post("/kit/bind", json={"appliance_id": "microwave", "confirm_release": True})
    fan = _by_id(client)["custom_fan"]
    assert fan["buttons"] == fan_buttons and fan["readiness_reasons"] == [GANTRY_ABSENT_REASON]


def test_unmapped_custom_appliance_is_not_called_released(client):
    assert client.put("/appliances/custom_fan", json=FAN).status_code in (200, 201)
    assert GANTRY_ABSENT_REASON not in _by_id(client)["custom_fan"]["readiness_reasons"]


def test_saving_new_positions_drops_the_verification(client):
    _add_mapped_fan(client)
    client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    _pass(client, "custom_fan")
    client.put("/appliances/custom_fan/mapping", json=MAPPING)
    assert client.get("/kit").json()["verified"] is False


@pytest.mark.parametrize("holder", [ControlArbiter.EXECUTION, ControlArbiter.DEVELOPER, ControlArbiter.VERIFY_PASS])
def test_bind_refused_while_machine_is_held(client, holder):
    _add_mapped_fan(client)
    arbiter = deps.get_service()._control_arbiter
    arbiter.acquire(holder)
    try:
        res = client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    finally:
        arbiter.release(holder)
    assert res.status_code == 409 and res.json()["detail"] == kit_router.KIT_BUSY_DETAIL
    assert client.get("/kit").json()["bound_appliance"] == "microwave"


def test_bind_refused_during_stop_hold(client, monkeypatch):
    _add_mapped_fan(client)
    monkeypatch.setattr(deps.get_service(), "hold_status", lambda: {"hold_state": "holding"})
    res = client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    assert res.status_code == 409 and res.json()["detail"] == kit_router.KIT_BUSY_DETAIL


def test_bind_refused_while_routine_is_between_segments(client, monkeypatch):
    _add_mapped_fan(client)
    monkeypatch.setattr(deps.get_service(), "_kit_routine_active", lambda: True)
    assert client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True}).status_code == 409


def test_run_admitted_before_bind_is_refused_at_the_gate(client):
    """준비 판정과 시작 게이트 사이에 연결이 바뀌면 옛 좌표로 누르지 않고, 제어권도 남기지 않는다."""
    _add_mapped_fan(client)
    client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    service = deps.get_service()
    with pytest.raises(ApplianceNotReadyError):
        service._begin_run(1, service._controller, "microwave")
    assert service._control_arbiter.holder is None


def test_routine_for_released_appliance_gets_plain_refusal(client):
    from rpi.routines.engine import RoutineUnavailableError
    from rpi.routines.wiring import get_routine_engine

    _add_mapped_fan(client)
    client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    engine = get_routine_engine()

    class _Command:
        from rpi.commands import ControlRoute
        route = ControlRoute.PHYSICAL
        target_id = "microwave"

    import rpi.routines.engine as module

    original = module.compile_commands
    module.compile_commands = lambda *_: (_Command(),)
    try:
        with pytest.raises(RoutineUnavailableError) as caught:
            engine._offer(object(), "시험", True, "manual")
    finally:
        module.compile_commands = original
    assert GANTRY_ABSENT_REASON in str(caught.value)


def test_deleted_bound_appliance_leaves_kit_empty_not_env(client):
    _add_mapped_fan(client)
    client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    assert client.delete("/appliances/custom_fan").status_code == 200
    assert client.get("/kit").json()["bound_appliance"] is None
    assert _by_id(client)["microwave"]["can_execute"] is False


def test_binding_survives_restart(client):
    _add_mapped_fan(client)
    client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    for dep in _DEPS:
        dep.cache_clear()
    assert client.get("/kit").json()["bound_appliance"] == "custom_fan"


def test_store_other_kit_owns_nothing_and_old_rpi4_follows_last(tmp_path):
    store = KitBindingStore(SimpleLayDb(str(tmp_path / "s.db")), ("microwave",))
    assert store.bound("kit-a").appliance_id == "microwave" and store.bound("kit-a").explicit is False
    store.bind("kit-a", "custom_fan")
    assert store.bound("kit-a").appliance_id == "custom_fan"
    assert store.bound("kit-b").appliance_id is None
    assert store.bound(None).appliance_id == "custom_fan"  # 세트 ID를 말하지 않는 옛 RPi4
    store.bind("kit-b", "custom_fan")  # 일대일 — 먼저 맡던 세트는 놓는다
    assert store.bound("kit-a").appliance_id is None


def test_store_corrupt_record_connects_nothing(tmp_path):
    db = SimpleLayDb(str(tmp_path / "s.db"))
    db.save_setting("kit_binding", "{broken")
    bound = KitBindingStore(db, ("microwave",)).bound("kit-a")
    assert bound.appliance_id is None and bound.explicit is True


class _Controller:
    """링크 실행 대상 대역 — act_info만 다르다."""

    def __init__(self, info, status=None, link_up=True):
        self.info, self.status, self.link_up = info, status, link_up

    def rehearsal_status(self):
        return dict(self.info)

    def link_status(self):
        return {"link_up": self.link_up}

    def kit_id(self):
        return self.info.get("kit_id")

    def kit_status(self):
        return self.status


def test_old_rpi4_keeps_env_and_cannot_bind(client, monkeypatch):
    _add_mapped_fan(client)
    service = deps.get_service()
    monkeypatch.setattr(service, "_controller", _Controller({"execute_protocol": 2, "motion": "serial"}))
    kit = client.get("/kit").json()
    assert kit["found"] is False and kit["reason"] == kit_router.KIT_OLD_DETAIL
    assert service.runs_locally("microwave") is True
    res = client.post("/kit/bind", json={"appliance_id": "custom_fan", "confirm_release": True})
    assert res.status_code == 409 and res.json()["detail"] == kit_router.KIT_OLD_DETAIL


def test_link_down_is_not_found(client, monkeypatch):
    monkeypatch.setattr(deps.get_service(), "_controller", _Controller({}, link_up=False))
    kit = client.get("/kit").json()
    assert kit["found"] is False and kit["reason"] == kit_router.KIT_NOT_FOUND_DETAIL




@pytest.mark.parametrize("homed", [True, False])
def test_readiness_reports_real_homed_value(client, monkeypatch, homed):
    from rpi.api import readiness_checks as checks

    status = {"kit_id": "kit-a", "kit_protocol": 1, "motion_homed": homed}
    service = deps.get_service()
    monkeypatch.setattr(service, "_controller", _Controller(status, status))
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    assert checks.motion_homed_check(service, None)[0] is homed


def _line_client():
    class _Writer:
        def __init__(self):
            self.lines = []

        def write(self, data):
            self.lines.append(json.loads(data))

        async def drain(self):
            return None

        def is_closing(self):
            return False

    writer = _Writer()
    return ActClient(asyncio.StreamReader(), writer), writer


@pytest.mark.parametrize("info,expected", [({"execute_protocol": 2, "kit_protocol": 1}, True),
                                           ({"execute_protocol": 2}, False)])
def test_execute_names_press_appliance_only_for_new_rpi4(info, expected):
    async def run():
        client, writer = _line_client()
        client.act_info = dict(info)
        task = asyncio.create_task(client.execute(("전원",), appliance_id="custom_fan"))
        await asyncio.sleep(0.01)
        task.cancel()
        return writer.lines

    lines = asyncio.run(run())
    frames = [d for d in lines if d.get("type") == "execute"]
    assert frames and ("press_appliance" in frames[0]) is expected
    if expected:
        assert frames[0]["press_appliance"] == "custom_fan"
