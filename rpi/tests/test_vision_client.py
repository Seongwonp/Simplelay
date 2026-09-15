"""인식 서비스 호출 — 요청 모양, 오류를 사용자 문장으로 바꾸기, 키가 새지 않기."""

import io
import json
import urllib.error

import pytest

from rpi.vision import (
    HttpVisionClient,
    HttpVisionClientConfig,
    VisionUnavailable,
    sniff_image_mime,
)

SECRET = "sk-test-0123456789abcdef"
CONFIG = HttpVisionClientConfig(
    base_url="https://gateway.example.invalid/v1/gateway/",
    api_key=SECRET,
    model="vision-model-x",
    timeout_seconds=12.5,
)
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _ok(content):
    return _Response(json.dumps({"choices": [{"message": {"content": content}}]}).encode())


def _capture(content='{"buttons": []}'):
    seen = {}

    def opener(request, timeout):
        seen["request"] = request
        seen["timeout"] = timeout
        return _ok(content)

    return seen, opener


def test_request_shape_headers_and_image_payload() -> None:
    seen, opener = _capture("결과")
    client = HttpVisionClient(CONFIG, opener=opener)

    assert client.describe_panel(PNG, "image/png") == "결과"

    request = seen["request"]
    assert request.full_url == "https://gateway.example.invalid/v1/gateway/chat/completions/"
    assert request.get_method() == "POST"
    headers = {k.lower(): v for k, v in request.header_items()}
    assert headers["authorization"] == f"Bearer {SECRET}"
    assert "python-urllib" not in headers["user-agent"].lower()
    assert seen["timeout"] == 12.5
    body = json.loads(request.data)
    assert body["model"] == "vision-model-x"
    assert body["temperature"] == 0
    parts = body["messages"][0]["content"]
    assert parts[0]["type"] == "text"
    assert parts[1]["image_url"]["url"].startswith("data:image/png;base64,iVBORw0KGgo")


def test_content_given_as_parts_is_joined() -> None:
    def opener(request, timeout):
        payload = {"choices": [{"message": {"content": [{"type": "text", "text": "{\"a\""}, {"type": "text", "text": ": 1}"}]}}]}
        return _Response(json.dumps(payload).encode())

    assert HttpVisionClient(CONFIG, opener=opener).describe_panel(PNG, "image/png") == '{"a": 1}'


@pytest.mark.parametrize(
    ("code", "needle"),
    [(401, "인증"), (403, "거절"), (402, "크레딧"), (413, "너무 커요"), (429, "많아요"), (503, "문제가"), (400, "HTTP 400")],
)
def test_http_errors_become_user_sentences_without_the_key(code, needle) -> None:
    def opener(request, timeout):
        raise urllib.error.HTTPError(request.full_url, code, "err", {}, io.BytesIO(SECRET.encode()))

    with pytest.raises(VisionUnavailable) as info:
        HttpVisionClient(CONFIG, opener=opener).describe_panel(PNG, "image/png")

    assert needle in str(info.value)
    assert info.value.status == code
    assert SECRET not in str(info.value)
    assert info.value.__cause__ is None


@pytest.mark.parametrize(
    "opener",
    [
        lambda request, timeout: (_ for _ in ()).throw(urllib.error.URLError("dns")),
        lambda request, timeout: (_ for _ in ()).throw(TimeoutError()),
        lambda request, timeout: _Response(b"<html>"),
        lambda request, timeout: _Response(json.dumps({"choices": []}).encode()),
        lambda request, timeout: _ok(""),
        lambda request, timeout: _ok(None),
    ],
)
def test_network_and_shape_failures_are_vision_unavailable(opener) -> None:
    with pytest.raises(VisionUnavailable):
        HttpVisionClient(CONFIG, opener=opener).describe_panel(PNG, "image/png")


def test_config_repr_hides_the_key() -> None:
    assert SECRET not in repr(CONFIG)


@pytest.mark.parametrize(
    ("data", "mime"),
    [
        (b"\xff\xd8\xff\xe0" + b"\x00" * 8, "image/jpeg"),
        (PNG, "image/png"),
        (b"RIFF\x10\x00\x00\x00WEBPVP8 ", "image/webp"),
        (b"GIF89a" + b"\x00" * 8, None),
        (b"%PDF-1.7", None),
        (b"", None),
    ],
)
def test_image_type_comes_from_magic_bytes(data, mime) -> None:
    assert sniff_image_mime(data) == mime
