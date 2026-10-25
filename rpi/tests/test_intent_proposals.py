"""휴대폰 말 확인 질문을 키오스크와 나누기(2026-10-26) — 60초, 먼저 고른 쪽 한 번, 서버는 실행하지 않는다."""

import threading
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from rpi.api.deps import get_appliance_registry, get_node_registry, get_service
from rpi.intent.proposals import IntentProposalStore, ProposalConflict
from rpi.main import app
from rpi.services.appliance_registry import ApplianceRegistry

ACTION = {"kind": "buttons", "appliance_id": "mw", "buttons": ["즉석밥", "시작"]}


class _Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def test_ttl_hides_expired_and_refuses_late_resolve():
    clock = _Clock()
    store = IntentProposalStore(ttl_s=60, now=clock)
    p = store.add("즉석밥을 데울까요?", "전자레인지 즉석밥 데우기", ACTION)
    assert [x.id for x in store.pending()] == [p.id]
    clock.t = 60.0
    assert store.pending() == []
    with pytest.raises(ProposalConflict):
        store.resolve(p.id, "yes")


def test_resolve_is_once_only_even_when_racing():
    store = IntentProposalStore()
    p = store.add("q", "l", ACTION)
    wins, losses = [], []
    barrier = threading.Barrier(8)

    def go(result):
        barrier.wait()
        try:
            wins.append(store.resolve(p.id, result).state)
        except ProposalConflict:
            losses.append(result)

    threads = [threading.Thread(target=go, args=("yes" if i % 2 else "no",)) for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(wins) == 1 and len(losses) == 7
    assert store.pending() == []


def test_new_proposal_replaces_the_previous_pending_one():
    store = IntentProposalStore()
    first = store.add("a", "a", ACTION)
    second = store.add("b", "b", ACTION)
    assert [x.id for x in store.pending()] == [second.id]
    with pytest.raises(ProposalConflict):
        store.resolve(first.id, "yes")


@pytest.fixture
def client(monkeypatch):
    from rpi.api import intent_router

    store = IntentProposalStore()
    monkeypatch.setattr(intent_router, "get_proposal_store", lambda: store)
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    executed = []
    service = SimpleNamespace(
        revision_options=lambda aid: {"즉석밥 데우기": ("즉석밥", "시작")},
        execute=lambda *a, **k: executed.append(a),
        submit=lambda *a, **k: executed.append(a),
    )
    monkeypatch.setenv("SIMPLELAY_LLM_URL", "http://localhost")
    monkeypatch.setattr(intent_router, "readiness_view", lambda *args: ("operable", [], True))
    monkeypatch.setattr(intent_router, "builtin_appliances_visible", lambda: True)
    monkeypatch.setattr(intent_router, "get_routine_store", lambda: SimpleNamespace(list=lambda: ()))
    monkeypatch.setattr("rpi.intent.llm_intent.http_transport",
                        lambda *a: {"choices": [{"message": {"content": "1"}}]})
    app.dependency_overrides[get_service] = lambda: service
    app.dependency_overrides[get_appliance_registry] = lambda: ApplianceRegistry()
    app.dependency_overrides[get_node_registry] = lambda: None
    try:
        yield TestClient(app), executed
    finally:
        app.dependency_overrides.clear()


def test_understood_proposal_is_shared_and_resolved_once_without_execution(client):
    http, executed = client
    result = http.post("/intent/understand", json={"text": "햇반 하나 돌려줘"}).json()
    assert result["understood"] is True
    pid = result["proposal_id"]
    pending = http.get("/intent/proposals").json()
    assert [p["id"] for p in pending] == [pid]
    assert pending[0]["question"] == result["question"]
    assert pending[0]["action"] == result["action"]
    assert http.get(f"/intent/proposals/{pid}").json()["state"] == "pending"

    won = http.post(f"/intent/proposals/{pid}/resolve", json={"result": "yes"})
    assert won.status_code == 200
    assert won.json()["state"] == "yes" and won.json()["action"] == result["action"]
    again = http.post(f"/intent/proposals/{pid}/resolve", json={"result": "no"})
    assert again.status_code == 409
    assert http.get("/intent/proposals").json() == []
    assert http.get(f"/intent/proposals/{pid}").json()["state"] == "yes"
    assert executed == [], "서버는 정하기만 하고 실행하지 않는다"
    assert "job_id" not in won.json()


def test_resolve_validation_and_unknown_id(client):
    http, _ = client
    assert http.post("/intent/proposals/nope/resolve", json={"result": "yes"}).status_code == 404
    assert http.get("/intent/proposals/nope").status_code == 404
    pid = http.post("/intent/understand", json={"text": "햇반 하나 돌려줘"}).json()["proposal_id"]
    assert http.post(f"/intent/proposals/{pid}/resolve", json={"result": "maybe"}).status_code == 422


def test_not_understood_keeps_nothing(client, monkeypatch):
    http, _ = client
    monkeypatch.setattr("rpi.intent.llm_intent.http_transport",
                        lambda *a: {"choices": [{"message": {"content": "0"}}]})
    result = http.post("/intent/understand", json={"text": "아무 말"}).json()
    assert result["understood"] is False and "proposal_id" not in result
    assert http.get("/intent/proposals").json() == []


def test_proposal_routes_require_auth(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_API_KEY", "test-only-key")
    http = TestClient(app)
    assert http.get("/intent/proposals").status_code == 401
    assert http.post("/intent/proposals/x/resolve", json={"result": "yes"}).status_code == 401
