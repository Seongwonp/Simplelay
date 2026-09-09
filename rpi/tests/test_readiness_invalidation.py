"""가전·노드가 바뀌면 준비 판정은 **무효**다.

`ReadinessRegistry.forget()`은 처음부터 있었지만 저장소 어디에서도 부르지
않았다. 그래서 이런 일이 생긴다.

- `operable`이던 가전을 지우고 **같은 id로 다시 등록**하면, 확인한 적 없는
  "조작 가능"을 그대로 물려받는다.
- 노드 주소를 다른 기기로 **교체**해도 앞 노드의 판정이 남는다. 새 기기의
  버튼 좌표는 맞춘 적이 없는데 화면은 맡겨도 된다고 말한다.
- 노드 연결을 **해제**해도 조작 가능이 남는다.

셋 다 F1이 막으려던 바로 그 상황이다 -- "등록됐다"와 "맡겨도 된다"를 같은
것으로 취급하는 것.

판정을 **잃는 쪽이 안전한 방향**이다. 다시 보고받으면 되지만, 확인하지 않은
조작 가능은 물리 버튼을 잘못 누르게 한다.
"""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app
from rpi.services.readiness import (
    ApplianceReadiness,
    ReadinessCheck,
    ReadinessState,
)

KST = timezone(timedelta(hours=9))
_NOW = datetime(2026, 9, 10, 12, 0, tzinfo=KST)

_CACHED = (
    deps.get_appliance_registry,
    deps.get_node_registry,
    deps.get_readiness_registry,
    deps.get_service,
    deps.get_suggestion_service,
)


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    for dep in _CACHED:
        dep.cache_clear()
    yield TestClient(app)
    for dep in _CACHED:
        dep.cache_clear()


def _make_operable(appliance_id: str) -> None:
    """그 가전을 '조작 가능'으로 만들어 둔다."""
    registry = deps.get_readiness_registry()
    registry.report(
        ApplianceReadiness.of(
            appliance_id,
            {check: True for check in ReadinessCheck},
            checked_at=_NOW,
        )
    )
    assert _state(appliance_id) is ReadinessState.OPERABLE


def _state(appliance_id: str) -> ReadinessState:
    return deps.get_readiness_registry().get(appliance_id).state


def _register_custom(client: TestClient, appliance_id: str) -> None:
    res = client.put(
        f"/appliances/{appliance_id}",
        json={
            "name": "테스트 가전",
            "icon": "custom",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )
    assert res.status_code == 200, res.text


# ── ① 가전 삭제 ───────────────────────────────────────────────────────────


def test_deleting_an_appliance_drops_its_readiness(client):
    _register_custom(client, "c1")
    _make_operable("c1")

    assert client.delete("/appliances/c1").status_code == 200

    assert _state("c1") is not ReadinessState.OPERABLE


def test_re_registering_the_same_id_does_not_inherit_operable(client):
    """가장 위험한 경로 -- 같은 id로 다시 등록했다고 앞 기기의 판정을
    물려받으면, 확인한 적 없는 좌표로 물리 버튼을 누르게 된다."""
    _register_custom(client, "c1")
    _make_operable("c1")
    client.delete("/appliances/c1")

    _register_custom(client, "c1")

    body = client.get("/appliances").json()
    (again,) = [a for a in body if a["id"] == "c1"]
    assert again["can_execute"] is False
    assert _state("c1") is not ReadinessState.OPERABLE


def test_a_failed_delete_does_not_wipe_readiness(client):
    """없는 가전을 지우려 했거나 판 번호가 어긋나 거절됐다면, 멀쩡한 판정을
    임의로 버리지 않는다."""
    _register_custom(client, "c1")
    _make_operable("c1")

    assert client.delete("/appliances/없는가전").status_code == 404

    assert _state("c1") is ReadinessState.OPERABLE


def test_revision_conflict_delete_keeps_readiness(client):
    _register_custom(client, "c1")
    _make_operable("c1")

    res = client.delete("/appliances/c1?expected_revision=99")

    assert res.status_code == 409
    assert _state("c1") is ReadinessState.OPERABLE


# ── ② 노드 주소 등록·교체 ─────────────────────────────────────────────────


def test_registering_a_node_invalidates_readiness(client):
    _register_custom(client, "c1")
    _make_operable("c1")

    res = client.post("/nodes/c1", json={"base_url": "http://node-a:8080"})

    assert res.status_code == 200
    assert _state("c1") is not ReadinessState.OPERABLE


def test_replacing_a_node_address_invalidates_readiness(client):
    """다른 기기로 갈아 끼운 것일 수 있다. 앞 기기에서 맞춘 버튼 좌표가
    새 기기에도 맞다고 볼 근거는 없다."""
    _register_custom(client, "c1")
    client.post("/nodes/c1", json={"base_url": "http://node-a:8080"})
    _make_operable("c1")

    client.post("/nodes/c1", json={"base_url": "http://node-b:8080"})

    assert _state("c1") is not ReadinessState.OPERABLE


# ── ③ 노드 연결 해제 ──────────────────────────────────────────────────────


def test_unregistering_a_node_invalidates_readiness(client):
    """가전 정의는 남아도, 누를 장치가 없으면 조작 가능일 수 없다."""
    _register_custom(client, "c1")
    client.post("/nodes/c1", json={"base_url": "http://node-a:8080"})
    _make_operable("c1")

    assert client.delete("/nodes/c1").status_code == 200

    assert _state("c1") is not ReadinessState.OPERABLE


# ── 남의 가전은 건드리지 않는다 ───────────────────────────────────────────


def test_other_appliances_keep_their_readiness(client):
    _register_custom(client, "c1")
    _register_custom(client, "c2")
    _make_operable("c1")
    _make_operable("c2")

    client.delete("/appliances/c1")

    assert _state("c2") is ReadinessState.OPERABLE


# ── 부가 정리가 실패해도 안전 정리는 끝난다 ───────────────────────────────


def test_readiness_is_dropped_even_if_node_cleanup_raises(client, monkeypatch):
    """가전 삭제는 `registry.delete → nodes.unregister → suggestions.drop`
    순서다. 가운데가 던지면 뒤가 실행되지 않는다 -- 그런데 뒤에 있는 것이
    **안전 정리**면, 부가 작업 하나의 실패가 위험 상태를 남기게 된다."""
    _register_custom(client, "c1")
    _make_operable("c1")

    nodes = deps.get_node_registry()
    monkeypatch.setattr(
        nodes,
        "unregister",
        lambda _id: (_ for _ in ()).throw(RuntimeError("노드 정리 실패")),
    )

    # 응답은 실패로 나가더라도(삼키지 않는다),
    with pytest.raises(RuntimeError):
        client.delete("/appliances/c1")

    # 판정은 남아 있으면 안 된다.
    assert _state("c1") is not ReadinessState.OPERABLE
