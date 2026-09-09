"""F2 충돌 규칙 — 다른 기기가 먼저 바꿨으면 조용히 덮어쓰지 않는다.

폰이 둘이면 같은 가전을 각자 편집할 수 있다. 지금은 나중에 저장한 쪽이
그냥 이긴다(last-write-wins). 진 쪽 사용자는 **자기가 방금 한 편집이
사라진 것도 모른다.**

가장 작은 규칙으로 막는다: 서버가 가전마다 판(revision)을 세고, 클라이언트가
"내가 본 판은 3이었다"고 밝히면서 저장한다. 그 사이 누가 4로 올려놨으면
409로 거절하고 **서버 내용을 유지한다.** 자동 병합도, 자동 덮어쓰기도 하지
않는다 — 무엇을 살릴지는 사람이 정할 일이다.

판을 밝히지 않은 저장은 종전대로 통과시킨다(구버전 폰·최초 등록).
"""

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app
from rpi.services.appliance_registry import (
    ApplianceButtonDef,
    ApplianceDef,
    ApplianceRegistry,
    RevisionConflictError,
)


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    caches = (
        deps.get_appliance_registry,
        deps.get_node_registry,
        deps.get_readiness_registry,
        deps.get_service,
    )
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def _body(name="선풍기", **extra):
    return {
        "name": name,
        "rows": 1,
        "cols": 1,
        "buttons": [{"id": "F-01", "label": "전원", "x": 0, "y": 0}],
        **extra,
    }


def _fan(**over) -> ApplianceDef:
    base = dict(
        appliance_id="fan",
        name="선풍기",
        icon="custom",
        rows=1,
        cols=1,
        buttons=(ApplianceButtonDef("F-01", "전원", 0, 0),),
        is_custom=True,
    )
    base.update(over)
    return ApplianceDef(**base)


# ── 판 세기 ───────────────────────────────────────────────────────────────


def test_first_registration_starts_at_one():
    registry = ApplianceRegistry()
    registry.register(_fan())

    assert registry.get("fan").revision == 1


def test_each_save_bumps_the_revision():
    registry = ApplianceRegistry()
    registry.register(_fan())
    registry.register(_fan(name="거실 선풍기"))

    assert registry.get("fan").revision == 2
    assert registry.get("fan").name == "거실 선풍기"


def test_revision_survives_a_restart(tmp_path):
    """판이 재시작마다 1로 돌아가면 충돌 검사가 의미를 잃는다."""
    from rpi.services.persistence import SimpleLayDb

    db = SimpleLayDb(str(tmp_path / "s.db"))
    first = ApplianceRegistry(store=db)
    first.register(_fan())
    first.register(_fan(name="거실 선풍기"))
    db.close()

    reopened = SimpleLayDb(str(tmp_path / "s.db"))
    try:
        assert ApplianceRegistry(store=reopened).get("fan").revision == 2
    finally:
        reopened.close()


# ── 충돌 ──────────────────────────────────────────────────────────────────


def test_saving_against_the_current_revision_succeeds():
    registry = ApplianceRegistry()
    registry.register(_fan())

    registry.register(_fan(name="거실 선풍기"), expected_revision=1)

    assert registry.get("fan").name == "거실 선풍기"


def test_saving_against_a_stale_revision_is_refused():
    """폰 A와 B가 같은 판(1)을 보고 있다가 A가 먼저 저장했다."""
    registry = ApplianceRegistry()
    registry.register(_fan())
    registry.register(_fan(name="A가 바꾼 이름"), expected_revision=1)

    with pytest.raises(RevisionConflictError):
        registry.register(_fan(name="B가 바꾼 이름"), expected_revision=1)

    # 서버 내용을 유지한다 — 진 쪽이 조용히 이기지 않는다
    assert registry.get("fan").name == "A가 바꾼 이름"


def test_omitting_the_revision_still_saves():
    """판을 밝히지 않은 저장은 막지 않는다 — 구버전 폰과 최초 등록 경로다."""
    registry = ApplianceRegistry()
    registry.register(_fan())

    registry.register(_fan(name="바뀐 이름"))

    assert registry.get("fan").name == "바뀐 이름"


# ── HTTP 계약 ─────────────────────────────────────────────────────────────


def test_http_response_carries_the_revision(client):
    created = client.put("/appliances/fan", json=_body()).json()
    assert created["revision"] == 1

    listed = next(a for a in client.get("/appliances").json() if a["id"] == "fan")
    assert listed["revision"] == 1


def test_http_stale_save_returns_409_and_keeps_the_server_copy(client):
    client.put("/appliances/fan", json=_body())
    client.put("/appliances/fan", json=_body("A가 바꾼 이름", expected_revision=1))

    res = client.put(
        "/appliances/fan", json=_body("B가 바꾼 이름", expected_revision=1)
    )

    assert res.status_code == 409
    listed = next(a for a in client.get("/appliances").json() if a["id"] == "fan")
    assert listed["name"] == "A가 바꾼 이름"
    assert listed["revision"] == 2


def test_http_save_with_the_current_revision_succeeds(client):
    client.put("/appliances/fan", json=_body())

    res = client.put("/appliances/fan", json=_body("거실 선풍기", expected_revision=1))

    assert res.status_code == 200
    assert res.json()["revision"] == 2


def test_http_deleting_a_missing_appliance_is_idempotent(client):
    """재전송된 삭제가 실패로 보이면 대기열에서 영영 안 빠진다.

    되돌려 놓으려던 상태(그 가전이 없음)는 이미 성립했다.
    """
    client.put("/appliances/fan", json=_body())
    assert client.delete("/appliances/fan").status_code == 200

    again = client.delete("/appliances/fan")

    assert again.status_code == 404  # 서버는 사실대로 말하고
    # 클라이언트가 이걸 성공으로 취급하는 계약은 폰 쪽 테스트가 고정한다
