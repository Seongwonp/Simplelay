"""조작부 사진 → 인식 서비스 응답 문자열. OpenAI 호환 Chat Completions 호출만 맡는다.

- 사진은 저장하지도, 로그에 남기지도 않는다.
- 키는 오류 메시지·repr에 싣지 않는다.
- 앞단 방화벽이 파이썬 기본 User-Agent를 봇으로 막는 게이트웨이가 있어 명시한다.
"""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Protocol

ALLOWED_IMAGE_MIME = ("image/jpeg", "image/png", "image/webp")

USER_AGENT = "SimpleLay/0.1 (+panel-scan)"

#: 응답 본문 상한(바이트). 버튼 목록 JSON은 수 KB면 충분하다. 게이트웨이가 폭주해
#: 거대한 본문을 보내도 통째로 메모리에 올리지 않고, 상한을 넘으면 오류로 끝낸다.
MAX_RESPONSE_BYTES = 1_000_000

PANEL_PROMPT = (
    "This is a photo of a home appliance control panel. "
    "List every physical button and dial you can see. "
    'Respond with JSON only: {"buttons": '
    '[{"label": "<text printed on or next to the control, original language>", '
    '"kind": "button" | "dial", "box": [x_min, y_min, x_max, y_max]}]}. '
    "Box coordinates are numbers normalized to 0-1000 relative to the image width "
    "(x) and height (y), in exactly that order. "
    "If a control has no readable label, use an empty string. Do not invent controls."
)


class VisionUnavailable(RuntimeError):
    """인식 서비스를 쓸 수 없다(연결·인증·한도·응답 형식). 메시지는 사용자에게 보여줄 문장."""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class VisionClient(Protocol):
    @property
    def model(self) -> str: ...

    def describe_panel(self, image: bytes, mime: str) -> str: ...


def sniff_image_mime(data: bytes) -> str | None:
    """파일 머리 바이트로 형식을 가린다. 확장자·클라이언트가 밝힌 형식은 믿지 않는다."""
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


@dataclass(frozen=True)
class HttpVisionClientConfig:
    base_url: str
    api_key: str = field(repr=False)
    model: str
    timeout_seconds: float = 60.0
    chat_path: str = "/chat/completions/"


_STATUS_MESSAGES = {
    401: "인식 서비스 인증에 실패했어요 — 서버의 키 설정을 확인해 주세요",
    403: "인식 서비스가 요청을 거절했어요 — 서버의 키·모델 권한을 확인해 주세요",
    402: "인식 서비스 크레딧이 부족해요 — 한도가 다시 채워진 뒤 시도해 주세요",
    413: "사진이 너무 커요 — 해상도를 낮춰 다시 찍어 주세요",
    429: "인식 요청이 많아요 — 잠시 후 다시 시도해 주세요",
}


def _read_capped(response, limit: int) -> bytes:
    """본문을 끝까지 읽되, 누적이 ``limit``을 넘는 순간 멈춘다.

    ``read(n)``은 '최대 n바이트'라 한 번에 다 온다는 보장이 없다(청크 전송·부분
    읽기). 한 번만 읽으면 정상 크기 응답이 잘려 JSON 해석에 실패한다.
    넘었는지 알 수 있게 상한보다 1바이트까지 더 읽는다.
    """
    chunks: list[bytes] = []
    total = 0
    while total <= limit:
        chunk = response.read(min(65536, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


class HttpVisionClient:
    def __init__(
        self,
        config: HttpVisionClientConfig,
        opener: Callable[..., object] | None = None,
    ) -> None:
        self._config = config
        self._opener = opener or urllib.request.urlopen

    @property
    def model(self) -> str:
        return self._config.model

    def describe_panel(self, image: bytes, mime: str) -> str:
        encoded = base64.b64encode(image).decode("ascii")
        body = json.dumps(
            {
                "model": self._config.model,
                "temperature": 0,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": PANEL_PROMPT},
                            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{encoded}"}},
                        ],
                    }
                ],
            }
        ).encode("utf-8")
        url = self._config.base_url.rstrip("/") + "/" + self._config.chat_path.lstrip("/")
        request = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self._config.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with self._opener(request, timeout=self._config.timeout_seconds) as response:
                raw = _read_capped(response, MAX_RESPONSE_BYTES)
            if len(raw) > MAX_RESPONSE_BYTES:
                raise VisionUnavailable(
                    "인식 서비스 응답이 너무 커요 — 서비스 상태를 확인해 주세요", status=502
                )
            payload = json.loads(raw.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            message = _STATUS_MESSAGES.get(exc.code)
            if message is None:
                message = (
                    "인식 서비스에 문제가 있어요 — 잠시 후 다시 시도해 주세요"
                    if exc.code >= 500
                    else f"인식 요청이 거절되었어요 (HTTP {exc.code})"
                )
            raise VisionUnavailable(message, status=exc.code) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise VisionUnavailable("인식 서비스에 연결하지 못했어요 — 네트워크를 확인해 주세요") from None
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise VisionUnavailable("인식 서비스 응답을 읽을 수 없어요") from None

        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            raise VisionUnavailable("인식 서비스 응답 형식이 예상과 달라요") from None
        if isinstance(content, list):
            content = "".join(
                part.get("text", "") for part in content if isinstance(part, dict)
            )
        if not isinstance(content, str) or not content.strip():
            raise VisionUnavailable("인식 결과가 비어 있어요 — 다시 시도해 주세요")
        return content
