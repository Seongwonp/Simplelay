"""날씨 캐시 — 마지막으로 받은 예보를 쥐고, 호출자에게는 절대 예외를 올리지 않는다.

- 새 발표(3시간마다)가 나왔을 때만 다시 받는다. 실패하면 ``retry_minutes``
  동안은 다시 두드리지 않는다(키오스크 폴링이 포털 호출 한도를 태우지 않게).
- 받은 예보는 메모리에, DB가 있으면 settings 한 칸에도 남긴다 -- 재시작 직후
  인터넷이 없어도 오래되지 않은 예보는 쓴다.
- ``stale_hours``보다 오래된 예보는 '없음'과 같게 다룬다(안내하지 않는다).
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable

from . import kma
from .config import WeatherConfig

log = logging.getLogger(__name__)

CACHE_SETTING_KEY = "weather_forecast_cache"


@dataclass(frozen=True)
class WeatherSnapshot:
    #: "kma" | "mock" | "none"
    source: str
    forecast: kma.Forecast | None = None
    fetched_at: datetime | None = None
    stale: bool = False
    #: 마지막 받기 실패 종류 network | api | parse (성공하면 None). 사용자 문구가 아니다.
    last_error: str | None = None

    @property
    def usable(self) -> bool:
        return self.forecast is not None and not self.stale


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class WeatherService:
    def __init__(
        self,
        config: WeatherConfig,
        *,
        store=None,
        clock: Callable[[], datetime] = _utc_now,
        fetch: Callable[..., kma.Forecast] = kma.fetch_forecast,
    ) -> None:
        self._config = config
        self._store = store
        self._clock = clock
        self._fetch = fetch
        self._lock = threading.Lock()
        self._refresh_lock = threading.Lock()
        self._cache: kma.Forecast | None = None
        self._last_attempt: datetime | None = None
        self._last_error: str | None = None
        if config.mode == "real":
            self._cache = self._load_persisted()

    @property
    def config(self) -> WeatherConfig:
        return self._config

    @property
    def last_error(self) -> str | None:
        """마지막 받기 실패 종류(network | api | parse) -- 받으러 가지 않고 읽기만."""
        with self._lock:
            return self._last_error

    # ── 영속 ────────────────────────────────────────────────────────────────

    def _load_persisted(self) -> kma.Forecast | None:
        loader = getattr(self._store, "load_setting", None)
        if loader is None:
            return None
        try:
            raw = loader(CACHE_SETTING_KEY)
            return kma.Forecast.from_json(raw) if raw else None
        except Exception:  # noqa: BLE001 - 손상된 캐시는 없는 것으로
            log.warning("ignoring unreadable weather cache")
            return None

    def _persist(self, forecast: kma.Forecast) -> None:
        saver = getattr(self._store, "save_setting", None)
        if saver is None:
            return
        try:
            saver(CACHE_SETTING_KEY, forecast.to_json())
        except Exception:  # noqa: BLE001 - 저장 실패가 조회를 막지 않는다
            log.warning("could not persist weather cache")

    # ── 조회 ────────────────────────────────────────────────────────────────

    def snapshot(self, now: datetime | None = None) -> WeatherSnapshot:
        """지금 쓸 수 있는 예보. 네트워크·포털 오류에도 예외 없이 돌아온다."""
        now = now or self._clock()
        mode = self._config.mode
        if mode == "mock":
            forecast = kma.mock_forecast(now)
            return WeatherSnapshot("mock", forecast, forecast.fetched_at, False)
        if mode != "real":
            return WeatherSnapshot("none")
        try:
            self._maybe_refresh(now)
        except Exception:  # noqa: BLE001 - 어떤 경우에도 호출자에게 올리지 않는다
            log.exception("weather refresh failed unexpectedly")
        with self._lock:
            cache, error = self._cache, self._last_error
        if cache is None:
            return WeatherSnapshot("none", last_error=error)
        stale = now - cache.fetched_at > timedelta(hours=self._config.stale_hours)
        return WeatherSnapshot(cache.source, cache, cache.fetched_at, stale, error)

    def _needs_refresh(self, now: datetime) -> bool:
        with self._lock:
            cache, last = self._cache, self._last_attempt
        wanted_base = kma.base_datetime(now).strftime("%Y%m%d%H%M")
        if cache is not None and cache.base == wanted_base:
            return False
        if last is not None and now - last < timedelta(minutes=self._config.retry_minutes):
            return False
        return True

    def _maybe_refresh(self, now: datetime) -> None:
        if not self._needs_refresh(now):
            return
        # 동시에 들어온 요청은 받는 중인 쪽을 기다리지 않고 캐시로 답한다.
        if not self._refresh_lock.acquire(blocking=False):
            return
        try:
            if not self._needs_refresh(now):
                return
            with self._lock:
                self._last_attempt = now
            cfg = self._config
            try:
                forecast = self._fetch(
                    cfg.service_key, cfg.nx, cfg.ny, now, timeout=cfg.timeout_seconds
                )
            except kma.KmaError as exc:
                log.warning("weather fetch failed: kind=%s code=%s", exc.kind, exc.code)
                with self._lock:
                    self._last_error = exc.kind
                return
            with self._lock:
                self._cache = forecast
                self._last_error = None
            self._persist(forecast)
        finally:
            self._refresh_lock.release()
