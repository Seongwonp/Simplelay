import json
from contextlib import contextmanager

import pytest

from rpi.intent import HttpLlmClient, HttpLlmClientConfig, LlmOutputError

CONFIG = HttpLlmClientConfig(
    base_url="https://example.invalid/v1", api_key="test-key", model="test-model"
)


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self._body = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._body


def test_complete_extracts_message_content(monkeypatch: pytest.MonkeyPatch):
    payload = {"choices": [{"message": {"content": '{"sequence": ["해동"]}'}}]}

    @contextmanager
    def fake_urlopen(request, timeout):
        assert request.full_url == "https://example.invalid/v1/chat/completions"
        assert request.get_header("Authorization") == "Bearer test-key"
        sent = json.loads(request.data.decode("utf-8"))
        assert sent["model"] == "test-model"
        assert "해동" in sent["messages"][1]["content"]
        yield FakeResponse(payload)

    monkeypatch.setattr("rpi.intent.llm.urllib.request.urlopen", fake_urlopen)

    client = HttpLlmClient(CONFIG)
    assert client.complete("우유 데워줘", ("해동", "시작")) == '{"sequence": ["해동"]}'


def test_network_failure_becomes_llm_output_error(monkeypatch: pytest.MonkeyPatch):
    def raising_urlopen(request, timeout):
        raise OSError("connection refused")

    monkeypatch.setattr("rpi.intent.llm.urllib.request.urlopen", raising_urlopen)

    client = HttpLlmClient(CONFIG)
    with pytest.raises(LlmOutputError):
        client.complete("우유 데워줘", ())


def test_unexpected_response_shape_becomes_llm_output_error(
    monkeypatch: pytest.MonkeyPatch,
):
    @contextmanager
    def fake_urlopen(request, timeout):
        yield FakeResponse({"unexpected": "shape"})

    monkeypatch.setattr("rpi.intent.llm.urllib.request.urlopen", fake_urlopen)

    client = HttpLlmClient(CONFIG)
    with pytest.raises(LlmOutputError):
        client.complete("우유 데워줘", ())
