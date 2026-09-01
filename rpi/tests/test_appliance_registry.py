"""가전 레지스트리 — 단일 진실원천 계약.

폰에서 등록한 가전이 키오스크에 뜨려면 서버가 가전 목록을 갖고 있어야 한다.
그동안 가전 정의가 다섯 곳에 흩어져 있었고 GET /appliances 자체가 없었다.
"""

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.intent.appliance import load_button_map
from rpi.main import app
from rpi.services import ApplianceRegistry, BuiltinApplianceError
from rpi.services.appliance_registry import (
    BUILTIN_MICROWAVE,
    ApplianceButtonDef,
    ApplianceDef,
)
from rpi.services.persistence import SimpleLayDb

CUSTOM = ApplianceDef(
    appliance_id="custom_aircon",
    name="거실 에어컨",
    icon="custom",
    rows=2,
    cols=2,
    buttons=(
        ApplianceButtonDef("AC-01", "전원", 0, 0),
        ApplianceButtonDef("AC-02", "냉방", 1, 0),
    ),
    is_custom=True,
)


# ── 진실원천 일치 — 내장 정의가 button-maps 매니페스트와 어긋나면 실패 ──────


def test_builtin_microwave_matches_button_map_manifest():
    # 8/31 코스 교체 때처럼 한쪽만 고치면 여기서 잡힌다
    manifest = load_button_map("docs/button-maps/microwave.json")
    manifest_buttons = {(b.id, b.label, b.x, b.y) for b in manifest.buttons}
    builtin_buttons = {
        (b.id, b.label, b.x, b.y) for b in BUILTIN_MICROWAVE.buttons
    }
    assert builtin_buttons == manifest_buttons


# ── 레지스트리 계약 ──────────────────────────────────────────────────────


def test_list_starts_with_builtins():
    registry = ApplianceRegistry()
    ids = [a.appliance_id for a in registry.list()]
    assert ids == ["microwave", "induction"]


def test_register_and_get_custom():
    registry = ApplianceRegistry()
    registry.register(CUSTOM)

    assert registry.get("custom_aircon") == CUSTOM
    assert CUSTOM in registry.list()


def test_register_same_id_replaces():
    registry = ApplianceRegistry()
    registry.register(CUSTOM)
    updated = ApplianceDef(
        appliance_id="custom_aircon",
        name="안방 에어컨",
        icon="custom",
        rows=1,
        cols=1,
        buttons=(ApplianceButtonDef("AC-01", "전원", 0, 0),),
        is_custom=True,
    )
    registry.register(updated)

    assert registry.get("custom_aircon").name == "안방 에어컨"
    assert len([a for a in registry.list() if a.is_custom]) == 1


def test_builtin_ids_cannot_be_overwritten_or_deleted():
    # 키오스크·의도 규칙이 내장 정의를 전제한다 — 조용히 바뀌면 안 된다
    registry = ApplianceRegistry()
    fake = ApplianceDef(
        appliance_id="microwave",
        name="가짜",
        icon="custom",
        rows=1,
        cols=1,
        buttons=(ApplianceButtonDef("X", "전원", 0, 0),),
        is_custom=True,
    )
    with pytest.raises(BuiltinApplianceError):
        registry.register(fake)
    with pytest.raises(BuiltinApplianceError):
        registry.delete("microwave")


def test_delete_custom():
    registry = ApplianceRegistry()
    registry.register(CUSTOM)

    assert registry.delete("custom_aircon") is True
    assert registry.get("custom_aircon") is None
    assert registry.delete("custom_aircon") is False


def test_custom_appliances_survive_restart(tmp_path):
    # 재시작하면 폰에서 등록한 가전이 증발하던 부류의 결함 방지
    db_path = str(tmp_path / "test.db")
    ApplianceRegistry(store=SimpleLayDb(db_path)).register(CUSTOM)

    reloaded = ApplianceRegistry(store=SimpleLayDb(db_path))
    assert reloaded.get("custom_aircon") == CUSTOM


# ── API ──────────────────────────────────────────────────────────────────


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    registry = ApplianceRegistry()
    app.dependency_overrides[deps.get_appliance_registry] = lambda: registry
    yield TestClient(app)
    app.dependency_overrides.pop(deps.get_appliance_registry, None)


def test_get_appliances_returns_builtins(client):
    body = client.get("/appliances").json()
    assert [a["id"] for a in body] == ["microwave", "induction"]
    microwave = body[0]
    assert microwave["name"] == "전자레인지"
    assert microwave["is_custom"] is False
    assert {"id", "label", "x", "y"} <= set(microwave["buttons"][0].keys())


def test_put_then_get_roundtrip(client):
    # 폰 편집기 저장 → 키오스크 목록 수신 경로
    res = client.put(
        "/appliances/custom_fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 2,
            "buttons": [
                {"id": "F-01", "label": "전원", "x": 0, "y": 0},
                {"id": "F-02", "label": "약풍", "x": 1, "y": 0},
            ],
        },
    )
    assert res.status_code == 200

    listed = client.get("/appliances").json()
    assert [a["id"] for a in listed] == ["microwave", "induction", "custom_fan"]
    assert listed[-1]["is_custom"] is True


def test_put_rejects_out_of_grid_button(client):
    res = client.put(
        "/appliances/custom_bad",
        json={
            "name": "이상한 가전",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "B", "label": "전원", "x": 5, "y": 0}],
        },
    )
    assert res.status_code == 422
    assert "outside" in res.json()["detail"]


def test_put_rejects_duplicate_position(client):
    res = client.put(
        "/appliances/custom_bad",
        json={
            "name": "이상한 가전",
            "rows": 1,
            "cols": 2,
            "buttons": [
                {"id": "A", "label": "전원", "x": 0, "y": 0},
                {"id": "B", "label": "정지", "x": 0, "y": 0},
            ],
        },
    )
    assert res.status_code == 422


def test_put_builtin_id_conflicts(client):
    res = client.put(
        "/appliances/microwave",
        json={
            "name": "가짜",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "X", "label": "전원", "x": 0, "y": 0}],
        },
    )
    assert res.status_code == 409


def test_delete_flow(client):
    client.put(
        "/appliances/custom_fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "F", "label": "전원", "x": 0, "y": 0}],
        },
    )
    assert client.delete("/appliances/custom_fan").status_code == 200
    assert client.delete("/appliances/custom_fan").status_code == 404
    assert client.delete("/appliances/microwave").status_code == 409


# ── 2차 리뷰 회귀 (실행 게이트·원자성·검증·격리) ─────────────────────────────


def test_execute_rejects_unknown_appliance_id(client):
    # 삭제된/미등록 가전의 실행이 로컬 기본 컨트롤러로 폴백하면 물리
    # 오라우팅이다 (교차 리뷰 치명 #1) — 게이트에서 404로 거부
    res = client.post(
        "/execute-buttons",
        json={"buttons": ["전원"], "appliance_id": "no_such_appliance"},
    )
    assert res.status_code == 404
    assert "삭제되었거나" in res.json()["detail"]


def test_execute_still_allows_registered_custom_without_node(client):
    # 레지스트리에 있는 커스텀은 노드 미등록이어도 로컬 폴백 허용 —
    # 8/31 에어컨 데모가 이 경로다 (실물 2번째 노드는 rpi4 합류 때)
    client.put(
        "/appliances/custom_fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "F", "label": "전원", "x": 0, "y": 0}],
        },
    )
    res = client.post(
        "/execute-buttons",
        json={"buttons": ["전원"], "appliance_id": "custom_fan"},
    )
    assert res.status_code == 200


def test_delete_appliance_also_unregisters_node(client):
    # 유령 노드가 남으면 긴급 정지가 계속 가고 재등록 시 옛 주소가
    # 재사용된다 (교차 리뷰 #4)
    client.put(
        "/appliances/custom_fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "F", "label": "전원", "x": 0, "y": 0}],
        },
    )
    assert (
        client.post(
            "/nodes/custom_fan", json={"base_url": "http://node:8080"}
        ).status_code
        == 200
    )
    assert client.delete("/appliances/custom_fan").status_code == 200
    node_ids = [n["appliance_id"] for n in client.get("/nodes").json()]
    assert "custom_fan" not in node_ids


def test_put_rejects_duplicate_button_label(client):
    # 실행은 라벨로 전송된다 — 같은 라벨 두 개는 어느 좌표인지 구분 불가
    res = client.put(
        "/appliances/custom_bad",
        json={
            "name": "이상한 가전",
            "rows": 1,
            "cols": 2,
            "buttons": [
                {"id": "A", "label": "전원", "x": 0, "y": 0},
                {"id": "B", "label": "전원", "x": 1, "y": 0},
            ],
        },
    )
    assert res.status_code == 422


def test_put_rejects_duplicate_button_id(client):
    res = client.put(
        "/appliances/custom_bad",
        json={
            "name": "이상한 가전",
            "rows": 1,
            "cols": 2,
            "buttons": [
                {"id": "A", "label": "전원", "x": 0, "y": 0},
                {"id": "A", "label": "정지", "x": 1, "y": 0},
            ],
        },
    )
    assert res.status_code == 422


def test_db_failure_keeps_memory_and_disk_consistent(tmp_path):
    # DB 쓰기 실패 시 메모리만 앞서가면 "지금은 보이는데 재시작하면
    # 사라지는" 가전이 생긴다 (교차 리뷰 #2)
    class FailingDb:
        def appliances(self):
            return ()

        def save_appliance(self, appliance):
            raise RuntimeError("disk full")

        def delete_appliance(self, appliance_id):
            raise RuntimeError("disk full")

    registry = ApplianceRegistry(store=FailingDb())
    with pytest.raises(RuntimeError):
        registry.register(CUSTOM)
    assert registry.get("custom_aircon") is None  # 메모리도 안 바뀜


def test_corrupt_db_row_does_not_block_other_appliances(tmp_path):
    # 한 행 손상이 레지스트리 전체 로딩을 막으면 안 된다 (교차 리뷰 #16)
    db_path = str(tmp_path / "test.db")
    db = SimpleLayDb(db_path)
    ApplianceRegistry(store=db).register(CUSTOM)
    # 손상 행 주입
    with db._lock:
        db._conn.execute(
            "INSERT INTO appliances (appliance_id, payload_json)"
            " VALUES ('broken', '{not json')"
        )
        db._conn.commit()

    reloaded = ApplianceRegistry(store=SimpleLayDb(db_path))
    assert reloaded.get("custom_aircon") == CUSTOM  # 정상 행은 산다
    assert reloaded.get("broken") is None
