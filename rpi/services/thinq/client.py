"""ThinQ 클라이언트 포트 — 공식 SDK의 동기 대역 (U1-c).

모델로 삼은 것: **pythinqconnect 1.0.14** (``pip`` 이름 ``thinqconnect``,
github.com/thinq-connect/pythinqconnect, 2026-09-28 소스 확인, **설치하지 않음**).

| 이 포트            | SDK ``ThinQApi`` (asyncio, aiohttp 세션)                                |
|--------------------|--------------------------------------------------------------------------|
| ``list_devices()`` | ``async_get_device_list(timeout=15)`` → ``GET devices``                  |
| ``get_status(id)`` | ``async_get_device_status(device_id, timeout=15)`` → ``GET devices/{id}/state`` |
| ``post_control``   | ``async_post_device_control(device_id, payload, timeout=15)`` → ``POST devices/{id}/control`` |

SDK 생성자: ``ThinQApi(session, access_token, country_code, client_id)``. 오류는
``ThinQAPIException``(code·message)이고 코드 표는 ``ThinQAPIErrorCodes``다.
푸시(MQTT)·이벤트 구독(``async_post_event_subscribe``)은 이번 범위 밖이다 -- 상태
확인은 조회(poll)로만 한다.

포트를 **동기**로 둔 이유: 서비스의 실행 job은 스레드에서 돈다. 실제 어댑터는
전용 이벤트 루프 스레드에서 SDK 코루틴을 돌리고 결과를 기다리는 식으로 붙인다
(기존 ``ActClientController``와 같은 방식). 그 연결은 PAT·보유 기기 확인 뒤(U2).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from rpi.controller.models import ExecutionMode


class ThinqClientError(Exception):
    """ThinQ 호출 실패의 공통 부모. 메시지에 토큰을 넣지 않는다.

    ``reason``은 사람이 읽을 이유(화면·기록용), ``code``·``name``은 클라우드 오류 코드와
    그 이름(공식 SDK ``ThinQAPIErrorCodes``)이다. 클라우드 오류가 아니면 둘 다 None.
    """

    def __init__(self, message: str = "", *, reason: str | None = None,
                 code: str | None = None, name: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason or message
        self.code = code
        self.name = name


class ThinqOfflineError(ThinqClientError):
    """클라우드·기기에 닿지 않는다. **보내기 전에** 알았다(전송 안 됨)."""


class ThinqRateLimited(ThinqOfflineError):
    """우리 쪽 호출 상한에 걸려 **보내지 않았다**(클라우드 한도를 넘기 전에 멈춤)."""


class ThinqTransportError(ThinqClientError):
    """보내는 중·응답 대기 중 끊겼다. 받았는지 **모른다** -- 다시 보내지 않는다."""


class ThinqCommandRejected(ThinqClientError):
    """클라우드가 응답으로 거절했다(지원 안 함·모드 불일치·인증 등). 실행되지 않았다."""

    def __init__(self, code: str, message: str, *, name: str | None = None,
                 reason: str | None = None) -> None:
        super().__init__(f"{code}: {message}", reason=reason or message, code=code, name=name)


@dataclass(frozen=True)
class ThinqDeviceInfo:
    device_id: str
    device_type: str
    alias: str
    model_name: str
    online: bool


class ThinqClientPort(Protocol):
    #: 이 클라이언트가 실제 클라우드·가전에 닿는가. 스스로 밝힌다(F4).
    execution_mode: ExecutionMode

    def list_devices(self) -> tuple[ThinqDeviceInfo, ...]: ...

    def get_status(self, device_id: str) -> dict: ...

    def post_control(self, device_id: str, payload: dict) -> dict: ...


NOT_IMPLEMENTED_MESSAGE = (
    "ThinQ 실물 연동은 아직 구현하지 않았어요 — SIMPLELAY_THINQ_PAT 필요, 실물 미구현. "
    "보유 가전 모델명·PAT 확인 뒤 U2에서 연결합니다"
)


class RealThinqClient:
    """실물 클라이언트 자리. **호출하면 항상 NotImplementedError.**

    ``execution_mode``는 REAL이다 -- 이 클래스가 성공을 돌려줄 날이 오면 그것은
    실제 가전 제어이므로, 모의 통계에 섞이지 않게 처음부터 REAL로 선언한다.
    PAT는 속성으로 보관하지 않는다(repr·로그·예외에 섞일 자리를 만들지 않는다).
    """

    execution_mode = ExecutionMode.REAL

    def __init__(self, *, has_pat: bool, country: str) -> None:
        self.has_pat = has_pat
        self.country = country

    def _fail(self):
        raise NotImplementedError(NOT_IMPLEMENTED_MESSAGE)

    def list_devices(self) -> tuple[ThinqDeviceInfo, ...]:
        self._fail()

    def get_status(self, device_id: str) -> dict:
        self._fail()

    def post_control(self, device_id: str, payload: dict) -> dict:
        self._fail()
