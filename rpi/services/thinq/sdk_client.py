"""공식 SDK 클라이언트 — ``thinqconnect`` 1.0.14의 ``ThinQApi``를 실제로 부른다.

2026-10-13 SDK 소스(설치본 ``thinqconnect/thinq_api.py``)에서 확인한 것:

- 생성자 ``ThinQApi(session, access_token, country_code, client_id, mock_response=False)``.
  ``session``은 aiohttp ``ClientSession``이고 SDK는 ``session.request(method=, url=, ...)``만 부른다.
- 주소는 ``https://api-{지역}.lgthinq.com/{endpoint}``로 **고정**(지역은 국가 코드에서). 기준 주소를
  바꾸는 설정은 없다. 그래서 fake_cloud 모드는 세션 자리에 주소만 바꾸는 얇은 감싸개를 넘긴다.
- 머리글: ``Authorization: Bearer <PAT>``, ``x-country``, ``x-message-id``(요청마다 새로),
  ``x-client-id``, ``x-api-key``(SDK 상수), ``x-service-phase: OP``. 제어는 ``x-conditional-control: true``.
- ``async_get_device_list`` → GET ``devices``, ``async_get_device_profile`` → GET ``devices/{id}/profile``,
  ``async_get_device_status`` → GET ``devices/{id}/state``, ``async_post_device_control`` →
  POST ``devices/{id}/control``(JSON 본문 그대로). 모두 ``timeout=`` 인자를 받는다.
- 성공이면 응답 JSON의 ``response``만 돌려주고, 실패면 ``ThinQAPIException(code, message, headers)``.
  **이 예외는 요청 머리글(PAT 포함)을 속성으로 든다** -- 우리 오류로 바꾸고 원인 연결을 끊는다.
- 기기 목록 항목은 ``{"deviceId", "deviceInfo": {"deviceType", "modelName", "alias", "reportable"}}``
  (SDK의 Home Assistant 연동 코드가 같은 키로 읽는다). **온라인 여부는 목록에 없다.**

포트는 동기다(서비스 실행 job이 스레드에서 돈다). 전용 이벤트 루프 스레드에서 SDK 코루틴을
돌리고 결과를 기다린다. PAT는 SDK 객체 안에만 있고 이 클래스의 속성·repr·로그에는 없다.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from typing import Any
from urllib.parse import urlsplit

from rpi.controller.models import ExecutionMode

from .client import (
    ThinqClientError,
    ThinqDeviceInfo,
    ThinqOfflineError,
    ThinqRateLimited,
    ThinqTransportError,
)
from .config import is_loopback_url
from .errors import error_from_api

INSTALL_HINT = 'pip install -e ".[thinq]"  (공식 SDK thinqconnect==1.0.14)'
_SDK_HOST_SUFFIX = ".lgthinq.com"


class ThinqSdkMissing(RuntimeError):
    """공식 SDK가 설치돼 있지 않다 -- SDK가 필요한 모드는 기동하지 않는다."""


def _import_sdk():
    try:
        from thinqconnect import ThinQApi, ThinQAPIException  # noqa: PLC0415
    except ImportError:
        raise ThinqSdkMissing(
            f"ThinQ 공식 SDK가 없어 SDK 모드를 켤 수 없어요 — {INSTALL_HINT}") from None
    return ThinQApi, ThinQAPIException


class _RebasedSession:
    """SDK가 만든 ``https://api-<지역>.lgthinq.com/<경로>``의 **주소만** 모의 클라우드로 바꾼다.

    경로·쿼리·머리글·본문은 SDK가 만든 그대로 넘긴다. 다른 주소는 거절한다.
    """

    def __init__(self, session, base_url: str) -> None:
        self._session = session
        self._base = base_url.rstrip("/")

    async def request(self, method: str, url, **kwargs):
        parts = urlsplit(str(url))
        host = parts.hostname or ""
        if parts.scheme != "https" or not (host.startswith("api-") and host.endswith(_SDK_HOST_SUFFIX)):
            raise ValueError("unexpected SDK url")
        target = f"{self._base}{parts.path}" + (f"?{parts.query}" if parts.query else "")
        return await self._session.request(method, target, **kwargs)


class SdkThinqClient:
    def __init__(
        self,
        *,
        access_token: str,
        country: str,
        client_id: str,
        execution_mode: ExecutionMode,
        base_url: str | None = None,
        max_calls_per_minute: int = 30,
        timeout: float = 10.0,
        list_cache_seconds: float = 15.0,
        monotonic: Callable[[], float] | None = None,
    ) -> None:
        if base_url is not None and not is_loopback_url(base_url):
            raise ValueError("SDK 주소는 이 기기 안 모의 클라우드(127.0.0.1)로만 바꿀 수 있어요")
        thinq_api_cls, self._api_exception = _import_sdk()
        import aiohttp  # noqa: PLC0415 -- SDK 의존성

        self._aiohttp = aiohttp
        self.execution_mode = execution_mode
        self.country = country
        self.redirected = base_url is not None
        self._timeout = timeout
        self._max_calls = max_calls_per_minute
        self._calls: deque[float] = deque()
        self._monotonic = monotonic or time.monotonic
        self._list_cache_seconds = list_cache_seconds
        self._lock = threading.Lock()
        self._profiles: dict[str, dict] = {}
        self._list_cache: tuple[float, tuple[ThinqDeviceInfo, ...]] | None = None
        self._status_cache: dict[str, tuple[float, Any]] = {}
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, name="thinq-sdk", daemon=True)
        self._thread.start()

        async def _open():
            session = aiohttp.ClientSession()
            transport = _RebasedSession(session, base_url) if base_url else session
            return session, thinq_api_cls(transport, access_token, country, client_id)

        self._session, self._api = self._wait(_open(), timeout)

    def __repr__(self) -> str:
        return (f"SdkThinqClient(execution_mode={self.execution_mode.value}, country={self.country}, "
                f"redirected={self.redirected})")

    # ── 루프 ──────────────────────────────────────────────────────────────
    def _wait(self, coro, timeout: float):
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        return future.result(timeout + 5.0)

    def close(self) -> None:
        if not self._loop.is_running():
            return
        try:
            self._wait(self._session.close(), 5.0)
        except Exception:  # noqa: BLE001
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(5.0)

    # ── 호출 상한 ──────────────────────────────────────────────────────────
    def _take_slot(self) -> None:
        now = self._monotonic()
        with self._lock:
            while self._calls and now - self._calls[0] >= 60.0:
                self._calls.popleft()
            if len(self._calls) >= self._max_calls:
                reason = (f"ThinQ 호출 상한(분당 {self._max_calls}회)에 걸려 보내지 않았어요 — "
                          "잠시 뒤 다시 시도해 주세요")
                raise ThinqRateLimited(reason, reason=reason)
            self._calls.append(now)

    def calls_last_minute(self) -> int:
        now = self._monotonic()
        with self._lock:
            return sum(1 for t in self._calls if now - t < 60.0)

    # ── SDK 호출 ──────────────────────────────────────────────────────────
    def _call(self, method: str, *args, control: bool = False):
        self._take_slot()
        api_method = getattr(self._api, method)
        aiohttp = self._aiohttp
        failure: ThinqClientError | None = None
        try:
            return self._wait(api_method(*args, timeout=self._timeout), self._timeout)
        except self._api_exception as exc:
            # 머리글(PAT)을 든 SDK 예외는 여기서 버린다 -- 코드와 이름만 꺼낸다.
            code, name = getattr(exc, "code", None), getattr(exc, "error_name", None)
            failure = error_from_api(code, name)
        except aiohttp.ClientConnectorError:
            failure = ThinqOfflineError(
                "ThinQ 클라우드에 연결하지 못했어요",
                reason="ThinQ 클라우드에 연결하지 못했어요 — 인터넷 연결을 확인해 주세요(보내지 않았어요)")
        except (asyncio.TimeoutError, concurrent.futures.TimeoutError, aiohttp.ClientError,
                ValueError, AttributeError, TypeError):
            reason = ("응답을 받지 못했어요 — 가전이 받았는지 몰라요. 자동으로 다시 보내지 않아요"
                      if control else "ThinQ 클라우드 응답을 읽지 못했어요")
            failure = ThinqTransportError(reason, reason=reason)
        raise failure

    def list_devices(self) -> tuple[ThinqDeviceInfo, ...]:
        with self._lock:
            cached = self._list_cache
        if cached is not None and self._monotonic() - cached[0] < self._list_cache_seconds:
            return cached[1]
        raw = self._call("async_get_device_list")
        devices = tuple(_device_info(item) for item in (raw or []) if isinstance(item, Mapping)
                        and item.get("deviceId"))
        with self._lock:
            self._list_cache = (self._monotonic(), devices)
        return devices

    def get_profile(self, device_id: str) -> dict:
        with self._lock:
            if device_id in self._profiles:
                return self._profiles[device_id]
        profile = self._call("async_get_device_profile", device_id)
        profile = profile if isinstance(profile, dict) else {}
        with self._lock:
            self._profiles[device_id] = profile
        return profile

    def forget_profile(self, device_id: str | None = None) -> None:
        with self._lock:
            if device_id is None:
                self._profiles.clear()
            else:
                self._profiles.pop(device_id, None)

    def get_status(self, device_id: str):
        status = self._call("async_get_device_status", device_id)
        with self._lock:
            self._status_cache[device_id] = (self._monotonic(), status)
        return status

    def cached_status(self, device_id: str, max_age: float = 15.0):
        """준비 상태 판정용 -- 최근 조회 결과가 있으면 다시 부르지 않는다(호출 한도 아끼기)."""
        with self._lock:
            hit = self._status_cache.get(device_id)
        if hit is not None and self._monotonic() - hit[0] < max_age:
            return hit[1]
        return self.get_status(device_id)

    def probe_online(self, device_id: str) -> bool:
        """목록에 온라인 여부가 없어 상태 조회로 본다. 연결 안 됨이면 False, 그 밖의 실패는 올린다."""
        try:
            self.cached_status(device_id)
        except ThinqOfflineError as exc:
            if isinstance(exc, ThinqRateLimited):
                raise
            return False
        return True

    def post_control(self, device_id: str, payload: dict) -> dict:
        response = self._call("async_post_device_control", device_id, payload, control=True)
        with self._lock:
            self._status_cache.pop(device_id, None)
        return response if isinstance(response, dict) else {}


def _device_info(item: Mapping) -> ThinqDeviceInfo:
    info = item.get("deviceInfo") if isinstance(item.get("deviceInfo"), Mapping) else {}
    return ThinqDeviceInfo(
        device_id=str(item["deviceId"]),
        device_type=str(info.get("deviceType") or ""),
        alias=str(info.get("alias") or ""),
        model_name=str(info.get("modelName") or ""),
        # 목록 API는 온라인 여부를 주지 않는다 -- 준비 상태는 probe_online(상태 조회)으로 본다.
        online=True,
    )
