"""R1 — 실행 대상 가전 검증을 모든 진입점이 공유한다.

지금까지 게이트는 **라우터의 직접 실행 3개 경로**에만 있었다. 제안 승인은
`approve_submit → submit_purpose → _controller_for`로 곧장 내려가 검사를
지나치지 않는다. 그래서 이런 일이 가능했다:

    선풍기 제안 생성 → 폰에서 선풍기 삭제 → 남은 제안 승인
    → 노드 없음 → 로컬 기본 컨트롤러 폴백 → **전자레인지 갠트리가 움직인다**

검사를 라우터에 하나 더 붙이는 것으로는 닫히지 않는다. 진입점이 늘어날
때마다 같은 구멍이 다시 생기기 때문이다 — 대상을 고르는 **한 곳**
(`_controller_for`)에서 거절해야 한다.

거절했을 때의 기준은 하나다: **mock 컨트롤러 호출 0.**
"""

import pytest

from rpi.api import SimpleLayService
from rpi.api.service import UnknownApplianceError
from rpi.controller import ClosedLoopController
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import (
    ProactiveSuggestionService,
    RuleBasedIntentResolver,
    SuggestionStatus,
)
from rpi.intent.mock import FixedClock, MockLlmClient
from rpi.services import ApplianceRegistry, NodeRegistry
from rpi.verifier import MockVerifier

from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
_NOW = datetime(2026, 7, 23, 19, 0, tzinfo=KST)


def _service(appliance_registry=None, node_registry=None):
    grbl = MockGrblClient()
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            grbl,
            MockVerifier(outcomes=[True] * 20),
            MockAlertSink(),
            MockSafetyController(),
            retry_waiter=MockRetryWaiter(),
        ),
        clock=FixedClock(_NOW),
        appliance_registry=appliance_registry,
        node_registry=node_registry,
        llm_client=MockLlmClient({"우유 데워줘": '{"sequence": ["시작"]}'}),
    )
    return service, grbl


# ── 모든 진입점이 같은 게이트를 지난다 ────────────────────────────────────


@pytest.mark.parametrize(
    "call",
    [
        pytest.param(
            lambda s: s.execute_purpose("우유 데워줘", appliance_id="ghost"),
            id="execute_purpose",
        ),
        pytest.param(
            lambda s: s.execute_buttons(("시작",), appliance_id="ghost"),
            id="execute_buttons",
        ),
        pytest.param(
            lambda s: s.execute_purpose_for_appliance(
                "우유 데워줘", frozenset({"시작"}), appliance_id="ghost"
            ),
            id="execute_purpose_for_appliance",
        ),
        pytest.param(
            lambda s: s.submit_purpose("우유 데워줘", appliance_id="ghost"),
            id="submit_purpose",
        ),
        pytest.param(
            lambda s: s.submit_buttons(("시작",), appliance_id="ghost"),
            id="submit_buttons",
        ),
        pytest.param(
            lambda s: s.submit_purpose_for_appliance(
                "우유 데워줘", frozenset({"시작"}), appliance_id="ghost"
            ),
            id="submit_purpose_for_appliance",
        ),
    ],
)
def test_unknown_appliance_is_refused_on_every_entry_point(call):
    service, grbl = _service(ApplianceRegistry())

    with pytest.raises(UnknownApplianceError):
        call(service)

    # 거절의 기준 — 물리 명령이 한 번도 나가지 않았다
    assert grbl.commands == []


def test_known_builtin_still_runs():
    """게이트가 정상 경로를 막으면 안 된다."""
    service, grbl = _service(ApplianceRegistry())

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    assert [c.button for c in grbl.commands] != []


def test_registry_absent_keeps_previous_behavior():
    """레지스트리를 주입하지 않은 구성(테스트·rpi4 브리지)은 종전대로 동작한다."""
    service, grbl = _service(appliance_registry=None)

    service.execute_purpose("우유 데워줘", appliance_id="ghost")

    assert [c.button for c in grbl.commands] != []


def test_unknown_appliance_error_is_not_a_busy_error():
    """409('다른 작업 실행 중')로 뭉뚱그려지면 안 된다 — 사용자가 기다렸다
    다시 눌러도 영원히 안 되는 상황을 '잠시 후 다시'로 안내하게 된다."""
    assert not issubclass(UnknownApplianceError, RuntimeError)


# ── 제안 승인 — R1이 실제로 뚫려 있던 경로 ────────────────────────────────


def _suggestion_service(service, appliance_id="fan"):
    svc = ProactiveSuggestionService(
        _NullDetector(),
        FixedClock(_NOW),
        service,
        intent_resolver=RuleBasedIntentResolver(),
    )
    suggestion = svc.create_demo_suggestion(
        "우유 데워줘", appliance_id=appliance_id
    )
    assert suggestion is not None
    return svc, suggestion


class _NullDetector:
    def candidates(self):
        return ()


def test_approving_a_suggestion_for_a_deleted_appliance_does_not_run():
    """R1의 재현 경로. 제안을 만든 뒤 그 가전을 지우고 승인한다."""
    registry = ApplianceRegistry()
    registry.register(_fan())
    service, grbl = _service(registry)
    svc, suggestion = _suggestion_service(service)

    registry.delete("fan")

    with pytest.raises(UnknownApplianceError):
        svc.approve_submit(suggestion.suggestion_id)

    assert grbl.commands == []


def test_failed_approval_does_not_consume_the_one_time_gate():
    """승인 게이트는 '실행을 제출했다'는 뜻이다. 제출 전에 거절당했으면
    소비되면 안 된다 — 카드만 사라지고 아무 일도 일어나지 않는다."""
    registry = ApplianceRegistry()
    registry.register(_fan())
    service, _ = _service(registry)
    svc, suggestion = _suggestion_service(service)

    registry.delete("fan")
    with pytest.raises(UnknownApplianceError):
        svc.approve_submit(suggestion.suggestion_id)

    still = svc.pending()
    assert [s.suggestion_id for s in still] == [suggestion.suggestion_id]
    assert still[0].status is SuggestionStatus.PENDING


def test_busy_server_also_leaves_the_suggestion_pending():
    """409로 거절당한 승인도 마찬가지다. 사용자는 '끝난 뒤 다시 시도하라'는
    안내를 받는데 정작 다시 시도할 카드가 사라져 있었다."""
    registry = ApplianceRegistry()
    service, _ = _service(registry)
    svc, suggestion = _suggestion_service(service, appliance_id="microwave")

    service.request_shutdown()  # 새 실행을 받지 않는 상태
    with pytest.raises(RuntimeError):
        svc.approve_submit(suggestion.suggestion_id)

    assert [s.suggestion_id for s in svc.pending()] == [suggestion.suggestion_id]


def _fan():
    from rpi.services.appliance_registry import ApplianceButtonDef, ApplianceDef

    return ApplianceDef(
        appliance_id="fan",
        name="선풍기",
        icon="custom",
        rows=1,
        cols=2,
        buttons=(
            ApplianceButtonDef("F-01", "전원", 0, 0),
            ApplianceButtonDef("F-02", "바람세기", 1, 0),
        ),
        is_custom=True,
    )


# ── HTTP 계약 — 진입점을 늘려도 같은 응답이어야 한다 ──────────────────────


@pytest.fixture()
def client(monkeypatch):
    import rpi.api.deps as deps
    from fastapi.testclient import TestClient
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    caches = (
        deps.get_appliance_registry,
        deps.get_service,
        deps.get_suggestion_service,
    )
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def _register_fan(client):
    return client.put(
        "/appliances/fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 2,
            "buttons": [
                {"id": "F-01", "label": "전원", "x": 0, "y": 0},
                {"id": "F-02", "label": "바람세기", "x": 1, "y": 0},
            ],
        },
    )


def test_http_execute_rejects_unknown_appliance_with_404(client):
    res = client.post(
        "/execute-buttons",
        json={"buttons": ["전원"], "appliance_id": "ghost"},
    )
    assert res.status_code == 404
    assert "삭제되었거나" in res.json()["detail"]


def test_http_registered_custom_without_node_is_refused(client):
    """노드가 없는 커스텀 가전은 누를 액추에이터가 없다 (F1 마감 감사).

    R1은 '없는 가전'을 막았고, 여기서는 '있지만 액추에이터가 없는 가전'을
    막는다. 로컬 폴백으로 흘리면 전자레인지 갠트리가 움직인다.
    """
    _register_fan(client)
    res = client.post(
        "/execute-buttons", json={"buttons": ["전원"], "appliance_id": "fan"}
    )
    assert res.status_code == 412


def test_http_deleting_an_appliance_takes_its_suggestion_down(client):
    """삭제하면 그 가전의 제안 카드도 사라진다 — 남겨두면 실행할 수 없는
    것을 계속 권유하게 된다."""
    _register_fan(client)
    created = client.post(
        "/demo/suggest", json={"purpose": "우유 데워줘", "appliance_id": "fan"}
    )
    assert created.status_code == 200
    assert client.get("/suggestions").json() != []

    assert client.delete("/appliances/fan").status_code == 200

    assert client.get("/suggestions").json() == []


def test_http_approving_a_suggestion_for_a_deleted_appliance_is_404(client):
    """R1의 재현 경로를 HTTP 계약으로 고정한다.

    보호는 두 겹이다: 삭제가 카드를 내리고(첫 겹), 이미 화면에 카드를 들고
    있던 클라이언트가 그 id로 승인해도 실행 게이트가 막는다(둘째 겹).
    여기서는 첫 겹이 먼저 걸려 "suggestion not found"가 오는데, 둘째 겹
    자체는 test_approving_a_suggestion_for_a_deleted_appliance_does_not_run
    이 서비스 층에서 직접 고정한다.

    **사용자에게 보이는 계약은 하나다: 404이고, 아무것도 실행되지 않는다.**
    409('다른 작업 실행 중')로 뭉뚱그리면 "잠시 후 다시 시도하세요"로
    안내되는데 기다려도 영원히 안 되는 상황이다.
    """
    _register_fan(client)
    suggestion_id = client.post(
        "/demo/suggest", json={"purpose": "우유 데워줘", "appliance_id": "fan"}
    ).json()["id"]

    client.delete("/appliances/fan")

    res = client.post(f"/suggestions/{suggestion_id}/approve")
    assert res.status_code == 404

    status = client.get("/status").json()
    assert status["running"] is False
    assert status["last_job_id"] is None
