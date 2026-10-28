"""플랫폼 AI 에이전트와 시스템 D-Bus로 주고받기(2026-10-26) — 덤 기능, 안 돼도 아무것도 안 깨진다.

- **보내는 것:** 방 안 사람 **수만**(정수 하나). 이름·사진·사람 목록은 보내지 않는다.
- **읽는 것:** 에이전트가 가진 날씨(a{sv})와 제안 한 줄(s). 오류 문장처럼 보이는 제안은 버린다.
- **켜기:** ``SIMPLELAY_PLATFORM_AGENT=1`` + ``SIMPLELAY_PLATFORM_AGENT_BUS``(버스 이름 — 기기의 성질이라
  코드에 적지 않는다, 오브젝트 경로·인터페이스는 버스 이름에서 관례대로 만든다). 둘 중 하나라도 없거나
  dbus-fast가 없으면 꺼진 채로 조용히 있는다.
- **실패:** 호출은 2초 제한, 호출부로 예외를 올리지 않는다. 처음 실패만 경고 한 줄, 그 뒤엔 잠시 쉬었다(back-off)
  다시 붙어 본다. 에이전트에게 요청을 시작시키는 메서드는 부르지 않는다 — 속성 읽기·쓰기만.

dbus-fast는 비동기라 전용 스레드 하나에 이벤트 루프를 두고 동기 함수로 감싼다(요청 스레드·감지 스레드 어디서
불러도 같다). 테스트는 ``adapter``에 가짜를 넣어 버스 없이 돈다.
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
import time
from collections.abc import Callable
from functools import lru_cache
from typing import Any, Protocol

log = logging.getLogger(__name__)

ENV_ENABLED = "SIMPLELAY_PLATFORM_AGENT"
ENV_BUS = "SIMPLELAY_PLATFORM_AGENT_BUS"

CALL_TIMEOUT_S = 2.0
BACKOFF_S = 60.0  # 실패 뒤 다시 붙어 보기까지
MIN_SEND_GAP_S = 10.0  # 사람 수는 바뀔 때만, 그래도 10초에 한 번까지
SNAPSHOT_TTL_S = 30.0  # 키오스크가 자주 물어도 버스는 30초에 한 번만

_PROP_PEOPLE = "NumberOfDetectedUser"
_PROP_WEATHER = "WeatherInfo"
_PROP_SUGGESTION = "SuggestionMessage"

# 제안 칸에 오류 문장이 들어오는 일이 있다(예: 일정 확인 실패 안내) — 이런 건 '없음'으로 본다.
_ERROR_HINTS = (
    "error", "could not", "couldn't", "cannot", "can't", "failed", "failure", "unable",
    "exception", "invalid", "not be validated", "timeout", "timed out", "unavailable",
    "오류", "실패", "에러",
)
_SUGGESTION_MAX = 200


class AgentAdapter(Protocol):
    """속성 읽기·쓰기 두 가지만. 실패하면 아무 예외나 올려도 된다 — 감싸는 쪽이 삼킨다."""

    def set_property(self, name: str, signature: str, value: Any) -> None: ...

    def get_property(self, name: str) -> Any: ...


def _unwrap(value: Any) -> Any:
    """dbus-fast Variant를 벗긴다(중첩 dict·list까지)."""
    if hasattr(value, "signature") and hasattr(value, "value"):
        value = value.value
    if isinstance(value, dict):
        return {str(k): _unwrap(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_unwrap(v) for v in value]
    return value


def clean_suggestion(raw: Any) -> str | None:
    """제안 한 줄을 쓸 수 있으면 돌려주고, 비었거나 오류처럼 보이면 None."""
    if not isinstance(raw, str):
        return None
    text = " ".join(raw.split())
    if not text:
        return None
    lowered = text.lower()
    if any(hint in lowered for hint in _ERROR_HINTS):
        return None
    return text[:_SUGGESTION_MAX]


def clean_weather(raw: Any) -> dict | None:
    value = _unwrap(raw)
    return value if isinstance(value, dict) and value else None


def weather_summary(weather: dict | None) -> str | None:
    """날씨 dict에서 짧은 한 줄을 고른다. 키 모양이 확정되지 않아 흔한 이름만 본다(없으면 None)."""
    if not weather:
        return None
    lowered = {k.lower(): v for k, v in weather.items()}
    text = next(
        (str(lowered[k]).strip() for k in ("summary", "description", "condition", "weather", "text", "status")
         if isinstance(lowered.get(k), str) and lowered[k].strip()),
        None,
    )
    temp = next((lowered[k] for k in ("temperature", "temp", "currenttemperature") if k in lowered), None)
    if isinstance(temp, (int, float)) and not isinstance(temp, bool):
        temp_text = f"{temp:g}°"
        text = f"{text} {temp_text}" if text else temp_text
    return text[:80] if text else None


class PlatformAgent:
    """동기 감싸개. 모든 공개 메서드는 예외를 올리지 않는다."""

    def __init__(
        self,
        adapter: AgentAdapter | None,
        *,
        now: Callable[[], float] = time.monotonic,
        min_send_gap_s: float = MIN_SEND_GAP_S,
        backoff_s: float = BACKOFF_S,
        snapshot_ttl_s: float = SNAPSHOT_TTL_S,
    ) -> None:
        self._adapter = adapter
        self._now = now
        self._gap = min_send_gap_s
        self._backoff = backoff_s
        self._ttl = snapshot_ttl_s
        self._lock = threading.Lock()
        self._last_sent: int | None = None
        self._last_sent_at: float | None = None
        self._retry_at = 0.0
        self._failing = False
        self._cached: dict | None = None
        self._cached_at: float | None = None

    @property
    def enabled(self) -> bool:
        return self._adapter is not None

    # 실패 처리: 처음 한 번만 경고, 그 뒤엔 쉬었다가

    def _blocked(self) -> bool:
        return self._now() < self._retry_at

    def _fail(self, what: str, exc: BaseException) -> None:
        self._retry_at = self._now() + self._backoff
        if not self._failing:
            log.warning("플랫폼 AI 에이전트 %s 실패 — %.0f초 뒤 다시 시도(이후 같은 실패는 조용히): %s",
                        what, self._backoff, exc)
        self._failing = True

    def _ok(self) -> None:
        if self._failing:
            log.info("플랫폼 AI 에이전트 다시 연결됨")
        self._failing = False

    # 보내기

    def set_people_count(self, n: int) -> bool:
        """사람 수를 보낸다 — 바뀔 때만, 10초에 한 번까지. 보냈으면 True(안 보냈거나 실패하면 False)."""
        if self._adapter is None:
            return False
        try:
            n = max(0, int(n))
        except (TypeError, ValueError):
            return False
        with self._lock:
            now = self._now()
            if n == self._last_sent or self._blocked():
                return False
            if self._last_sent_at is not None and now - self._last_sent_at < self._gap:
                return False  # 다음 주기에 다시 온다 — 바뀐 값이 남아 있으면 그때 보낸다
            try:
                self._adapter.set_property(_PROP_PEOPLE, "u", n)
            except Exception as exc:  # noqa: BLE001 — 덤 기능, 어떤 오류든 삼킨다
                self._fail("사람 수 보내기", exc)
                return False
            self._ok()
            self._last_sent, self._last_sent_at = n, now
            return True

    # 읽기

    def snapshot(self) -> dict:
        """{weather: dict|None, suggestion: str|None, available: bool} — 30초 동안은 지난 값을 준다."""
        empty = {"weather": None, "suggestion": None, "available": False}
        if self._adapter is None:
            return empty
        with self._lock:
            now = self._now()
            if self._cached is not None and self._cached_at is not None and now - self._cached_at < self._ttl:
                return dict(self._cached)
            if self._blocked():
                return empty
            try:
                weather = clean_weather(self._adapter.get_property(_PROP_WEATHER))
                suggestion = clean_suggestion(_unwrap(self._adapter.get_property(_PROP_SUGGESTION)))
            except Exception as exc:  # noqa: BLE001
                self._fail("읽기", exc)
                self._cached = None
                return empty
            self._ok()
            self._cached = {"weather": weather, "suggestion": suggestion, "available": True}
            self._cached_at = now
            return dict(self._cached)

    def view(self) -> dict:
        """API에 내보낼 모양 — {available, suggestion, weather_summary}."""
        snap = self.snapshot()
        return {
            "available": snap["available"],
            "suggestion": snap["suggestion"],
            "weather_summary": weather_summary(snap["weather"]),
        }


class DbusFastAdapter:
    """dbus-fast로 시스템 버스의 표준 Properties 인터페이스를 부른다(introspect 없이 Get·Set만).

    전용 스레드에 이벤트 루프를 하나 띄우고 연결을 재사용한다. 실패하면 연결을 버리고 다음 호출에서 새로 붙는다.
    """

    def __init__(self, bus_name: str, timeout_s: float = CALL_TIMEOUT_S) -> None:
        self._name = bus_name
        self._path = "/" + bus_name.replace(".", "/")
        self._iface = bus_name
        self._timeout = timeout_s
        self._loop = asyncio.new_event_loop()
        self._bus = None
        threading.Thread(target=self._loop.run_forever, daemon=True, name="simplelay-platform-agent").start()

    def _run(self, coro):
        future = asyncio.run_coroutine_threadsafe(asyncio.wait_for(coro, self._timeout), self._loop)
        try:
            return future.result(self._timeout + 0.5)
        except BaseException:
            future.cancel()
            asyncio.run_coroutine_threadsafe(self._drop(), self._loop)
            raise

    async def _drop(self) -> None:
        bus, self._bus = self._bus, None
        if bus is not None:
            try:
                bus.disconnect()
            except Exception:  # noqa: BLE001
                pass

    async def _call(self, member: str, signature: str, body: list) -> Any:
        from dbus_fast import Message, MessageType  # noqa: PLC0415 — 켰을 때만 필요
        from dbus_fast.aio import MessageBus  # noqa: PLC0415
        from dbus_fast.constants import BusType  # noqa: PLC0415

        if self._bus is None:
            self._bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        reply = await self._bus.call(Message(
            destination=self._name, path=self._path, interface="org.freedesktop.DBus.Properties",
            member=member, signature=signature, body=body,
        ))
        if reply is None or reply.message_type == MessageType.ERROR:
            detail = None if reply is None else (reply.error_name, reply.body)
            raise RuntimeError(f"D-Bus {member} 오류: {detail}")
        return reply.body[0] if reply.body else None

    def set_property(self, name: str, signature: str, value: Any) -> None:
        from dbus_fast import Variant  # noqa: PLC0415

        self._run(self._call("Set", "ssv", [self._iface, name, Variant(signature, value)]))

    def get_property(self, name: str) -> Any:
        return self._run(self._call("Get", "ss", [self._iface, name]))


def _default_adapter() -> AgentAdapter | None:
    if os.environ.get(ENV_ENABLED, "").strip() != "1":
        return None
    bus_name = os.environ.get(ENV_BUS, "").strip()
    if not bus_name:
        log.warning("%s=1 인데 %s가 비어 있다 — 플랫폼 AI 에이전트 연결 꺼짐", ENV_ENABLED, ENV_BUS)
        return None
    try:
        import dbus_fast  # noqa: F401, PLC0415
    except ImportError:
        log.warning("dbus-fast가 없다 — 플랫폼 AI 에이전트 연결 꺼짐")
        return None
    return DbusFastAdapter(bus_name)


@lru_cache(maxsize=1)
def get_platform_agent() -> PlatformAgent:
    """켜지지 않았으면 adapter 없는(늘 꺼진) 감싸개를 준다 — 호출부가 None을 따지지 않게."""
    try:
        return PlatformAgent(_default_adapter())
    except Exception:  # noqa: BLE001
        log.exception("플랫폼 AI 에이전트 준비 실패 — 꺼짐")
        return PlatformAgent(None)
