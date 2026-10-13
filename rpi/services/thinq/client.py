"""ThinQ 클라이언트 포트 — 공식 SDK(``thinqconnect`` 1.0.14) 호출의 동기 대역.

| 이 포트              | SDK ``ThinQApi`` (asyncio, aiohttp 세션)                                   |
|----------------------|-----------------------------------------------------------------------------|
| ``list_devices()``   | ``async_get_device_list`` → ``GET devices``                                |
| ``get_profile(id)``  | ``async_get_device_profile`` → ``GET devices/{id}/profile``                |
| ``get_status(id)``   | ``async_get_device_status`` → ``GET devices/{id}/state``                   |
| ``post_control``     | ``async_post_device_control`` → ``POST devices/{id}/control``              |

구현: ``MockThinqClient``(프로세스 안 모의, SDK 없음), ``SdkThinqClient``(``sdk_client.py`` --
공식 SDK를 실제로 부른다. fake_cloud 모드는 저장소 안 모의 클라우드로, real 모드는 실제 클라우드로).
푸시(MQTT)·이벤트 구독은 범위 밖이다 -- 상태 확인은 조회(poll)로만 한다.

포트를 **동기**로 둔 이유: 서비스의 실행 job은 스레드에서 돈다. SDK 클라이언트는 전용 이벤트
루프 스레드에서 SDK 코루틴을 돌리고 결과를 기다린다.
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

    def get_profile(self, device_id: str) -> dict: ...

    def get_status(self, device_id: str): ...

    def post_control(self, device_id: str, payload: dict) -> dict: ...
