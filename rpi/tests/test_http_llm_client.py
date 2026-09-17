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
    assert client.complete("즉석밥 데워줘", ("해동", "시작")) == '{"sequence": ["해동"]}'


def test_request_does_not_use_the_default_python_user_agent(
    monkeypatch: pytest.MonkeyPatch,
):
    # 앞단 방화벽이 Python-urllib 기본 User-Agent를 403(error 1010)으로 막는
    # 게이트웨이가 있다 -- 키가 맞아도 호출이 통째로 실패한다.
    seen = {}

    @contextmanager
    def fake_urlopen(request, timeout):
        seen["ua"] = request.get_header("User-agent")
        yield FakeResponse({"choices": [{"message": {"content": '{"sequence": []}'}}]})

    monkeypatch.setattr("rpi.intent.llm.urllib.request.urlopen", fake_urlopen)

    HttpLlmClient(CONFIG).complete("즉석밥 데워줘", ())

    assert seen["ua"]
    assert "python-urllib" not in seen["ua"].lower()


def test_network_failure_becomes_llm_output_error(monkeypatch: pytest.MonkeyPatch):
    def raising_urlopen(request, timeout):
        raise OSError("connection refused")

    monkeypatch.setattr("rpi.intent.llm.urllib.request.urlopen", raising_urlopen)

    client = HttpLlmClient(CONFIG)
    with pytest.raises(LlmOutputError):
        client.complete("즉석밥 데워줘", ())


def test_unexpected_response_shape_becomes_llm_output_error(
    monkeypatch: pytest.MonkeyPatch,
):
    @contextmanager
    def fake_urlopen(request, timeout):
        yield FakeResponse({"unexpected": "shape"})

    monkeypatch.setattr("rpi.intent.llm.urllib.request.urlopen", fake_urlopen)

    client = HttpLlmClient(CONFIG)
    with pytest.raises(LlmOutputError):
        client.complete("즉석밥 데워줘", ())
