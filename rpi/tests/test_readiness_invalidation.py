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


def _boom(message: str):
    """부르면 던지는 가짜 정리 단계."""

    def _raise(*_args, **_kwargs):
        raise RuntimeError(message)

    return _raise


def _pending_ids(appliance_id: str) -> list[str]:
    return [
        s.suggestion_id
        for s in deps.get_suggestion_service().pending()
        if s.appliance_id == appliance_id
    ]


def _make_suggestion(client: TestClient, appliance_id: str) -> None:
    res = client.post(
        "/demo/suggest",
        json={"purpose": f"{appliance_id} 시험", "appliance_id": appliance_id},
    )
    assert res.status_code == 200, res.text
    assert _pending_ids(appliance_id)


def test_readiness_is_dropped_even_if_node_cleanup_raises(client, monkeypatch):
    """가전 삭제 뒤의 정리는 **각각 독립적으로** 시도한다.

    예전에는 `nodes.unregister → suggestions.drop` 이 한 try 안에 있어서,
    앞이 던지면 뒤가 통째로 생략됐다. 부가 작업 하나의 실패가 다른 정리를
    막으면 안 된다."""
    _register_custom(client, "c1")
    _make_operable("c1")
    _make_suggestion(client, "c1")

    monkeypatch.setattr(
        deps.get_node_registry(), "unregister", _boom("노드 정리 실패")
    )

    # 예외는 숨기지 않는다 -- 호출자는 뒷정리가 덜 끝났다는 것을 알아야 한다.
    with pytest.raises(RuntimeError, match="노드 정리 실패"):
        client.delete("/appliances/c1")

    # 그래도 나머지 정리는 전부 수행된다.
    assert _state("c1") is not ReadinessState.OPERABLE
    assert _pending_ids("c1") == []


def test_cleanup_failure_does_not_touch_other_appliances(client, monkeypatch):
    _register_custom(client, "c1")
    _register_custom(client, "c2")
    _make_operable("c1")
    _make_operable("c2")
    _make_suggestion(client, "c1")
    _make_suggestion(client, "c2")

    monkeypatch.setattr(
        deps.get_node_registry(), "unregister", _boom("노드 정리 실패")
    )
    with pytest.raises(RuntimeError):
        client.delete("/appliances/c1")

    # 남의 가전은 그대로다.
    assert _state("c2") is ReadinessState.OPERABLE
    assert _pending_ids("c2") != []


def test_first_cleanup_error_is_the_one_raised(client, monkeypatch):
    """정리 단계가 여럿 실패하면 **첫 예외**를 호출자에게 전달한다.
    나머지는 로그로 남긴다 -- 하나로 뭉뚱그리면 원인 추적이 어려워지고,
    마지막 것을 던지면 먼저 무너진 곳을 잃는다."""
    _register_custom(client, "c1")
    _make_operable("c1")

    monkeypatch.setattr(deps.get_node_registry(), "unregister", _boom("먼저"))
    monkeypatch.setattr(
        deps.get_suggestion_service(), "drop_for_appliance", _boom("나중")
    )

    with pytest.raises(RuntimeError, match="먼저"):
        client.delete("/appliances/c1")

    # 그 와중에도 안전 정리는 끝난다.
    assert _state("c1") is not ReadinessState.OPERABLE


# ── 노드 등록이 도중에 실패하면 ───────────────────────────────────────────


def test_partial_node_registration_still_invalidates_readiness(
    client, monkeypatch
):
    """`NodeRegistry.register()`는 메모리 주소를 먼저 바꾸고 store에 저장한다.
    저장이 실패하면 **주소는 이미 바뀐 채로** 예외가 나간다 -- 그때 앞
    기기의 `operable`이 남아 있으면, 확인한 적 없는 새 주소로 맡겨도 된다고
    말하게 된다. 등록 성공이 불확실한 순간에는 판정을 버리는 쪽이 안전하다."""
    _register_custom(client, "c1")
    client.post("/nodes/c1", json={"base_url": "http://node-a:8080"})
    _make_operable("c1")

    monkeypatch.setattr(
        deps.get_node_registry(), "register", _boom("주소 저장 실패")
    )

    with pytest.raises(RuntimeError, match="주소 저장 실패"):
        client.post("/nodes/c1", json={"base_url": "http://node-b:8080"})

    assert _state("c1") is not ReadinessState.OPERABLE


def test_rejected_node_request_keeps_readiness(client):
    """registry에 닿기도 전에 걸러진 요청(입력 검증)까지 판정을 버릴 이유는
    없다. 아무 상태도 바뀌지 않았다."""
    _register_custom(client, "c1")
    client.post("/nodes/c1", json={"base_url": "http://node-a:8080"})
    _make_operable("c1")

    res = client.post("/nodes/c1", json={})

    assert res.status_code == 422
    assert _state("c1") is ReadinessState.OPERABLE
