import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api import voice_router
from rpi.api.deps import get_appliance_registry, get_node_registry, get_service


class FakeSttClient:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.seconds = []

    async def listen(self, seconds):
        self.seconds.append(seconds)
        if self.error:
            raise self.error
        return self.result


@pytest.fixture
def app(monkeypatch):
    application = FastAPI()
    application.include_router(voice_router.router)
    sentinel = object()
    application.dependency_overrides[get_service] = lambda: sentinel
    application.dependency_overrides[get_appliance_registry] = lambda: sentinel
    application.dependency_overrides[get_node_registry] = lambda: sentinel

    async def fake_understand(text, _service, _registry, _nodes):
        return {"proposal": {
            "id": "proposal-1", "question": "공기청정기를 켤까요?", "label": "공기청정기 켜기",
            "action": {"kind": "thinq", "appliance_id": "air-purifier", "action": "set", "args": {"power": "on"}},
        }}

    monkeypatch.setattr(voice_router, "understand_text", fake_understand)
    return application


def _client(app, stt):
    app.dependency_overrides[voice_router.get_stt_client] = lambda: stt
    return TestClient(app)


def test_no_speech_returns_no_proposal(app):
    stt = FakeSttClient({"text": "", "reason": "no_speech"})
    response = _client(app, stt).post("/voice/listen")
    assert response.status_code == 200
    assert response.json() == {"text": "", "proposal": None, "reason": "no_speech"}
    assert stt.seconds == [5]


def test_text_uses_intent_proposal_flow(app):
    response = _client(app, FakeSttClient({"text": "공기청정기 켜 줘", "reason": "ok"})).post("/voice/listen")
    assert response.status_code == 200
    assert response.json()["text"] == "공기청정기 켜 줘"
    assert response.json()["proposal"]["id"] == "proposal-1"
    assert response.json()["reason"] == "ok"


def test_stt_busy_is_forwarded_as_conflict(app):
    error = voice_router.HTTPException(status_code=409, detail="이미 듣고 있어요.")
    response = _client(app, FakeSttClient(error=error)).post("/voice/listen")
    assert response.status_code == 409
    assert response.json()["detail"] == "이미 듣고 있어요."


def test_stt_down_has_plain_korean_message(app):
    response = _client(app, FakeSttClient(error=OSError("down"))).post("/voice/listen")
    assert response.status_code == 503
    assert response.json()["detail"] == voice_router.STT_UNAVAILABLE
