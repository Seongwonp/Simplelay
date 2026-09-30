"""내장 가전은 개발자 모드·리허설 런처에서만 '내 가전' 목록에 보인다(UI 확정 §1-6).

목록에서만 숨기고 등록부의 조회·실행 경로는 그대로 둔다 -- 시연 규칙과
기존 테스트가 내장 전자레인지를 전제로 하기 때문이다.
"""

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
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


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DEV_MODE", raising=False)
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    yield TestClient(app)
    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()


def _ids(client):
    res = client.get("/appliances")
    assert res.status_code == 200
    return [a["id"] for a in res.json()]


def test_normal_mode_lists_no_builtins(client):
    assert deps.builtin_appliances_visible() is False
    assert _ids(client) == []


def test_normal_mode_lists_only_user_registered(client):
    assert client.put("/appliances/custom_fan", json=_FAN).status_code == 200
    assert _ids(client) == ["custom_fan"]


def test_normal_mode_keeps_builtin_lookup_for_execution(client):
    # 목록에서만 숨긴다 -- 규칙·실행이 쓰는 get()은 그대로다.
    assert deps.get_appliance_registry().get("microwave") is not None


@pytest.mark.parametrize("value", ["1", "true", "TRUE"])
def test_developer_mode_lists_builtins(client, monkeypatch, value):
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", value)
    assert _ids(client) == ["microwave", "induction"]


def test_simulator_launcher_lists_builtins(client, monkeypatch):
    # rpi.simulator_main은 DEV_MODE를 끄고 ACT_MODE=simulator로 고정한다.
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "false")
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "simulator")
    assert client.put("/appliances/custom_fan", json=_FAN).status_code == 200
    assert _ids(client) == ["microwave", "induction", "custom_fan"]


@pytest.mark.parametrize("mode", ["mock", "local", ""])
def test_other_act_modes_hide_builtins(client, monkeypatch, mode):
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", mode)
    assert "microwave" not in _ids(client)


def test_simulator_main_sets_the_mode_that_shows_builtins():
    # 런처가 바뀌어 리허설에서 내장 가전이 사라지는 일을 막는다.
    import inspect

    import rpi.simulator_main as sim

    src = inspect.getsource(sim.main)
    assert 'os.environ["SIMPLELAY_ACT_MODE"] = "simulator"' in src
