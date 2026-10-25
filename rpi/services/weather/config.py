"""날씨 설정 — 전부 환경 변수. 키는 코드·저장소에 두지 않는다.

| 변수 | 뜻 | 기본 |
|---|---|---|
| ``SIMPLELAY_WEATHER_MODE`` | ``off`` · ``mock``(리허설용 고정 예보) · ``real``(기상청) | ``off`` |
| ``SIMPLELAY_KMA_SERVICE_KEY`` | 공공데이터포털 일반 인증키. Decoding 키 권장, Encoding 키도 받는다 | 없음 → real이어도 꺼짐 |
| ``SIMPLELAY_WEATHER_NX`` / ``_NY`` | 기상청 격자 좌표 | 없음 |
| ``SIMPLELAY_WEATHER_LAT`` / ``_LON`` | 위경도(°). NX/NY가 없을 때 격자로 바꾼다 | 없음 |
| ``SIMPLELAY_WEATHER_STALE_HOURS`` | 마지막 예보가 이보다 오래되면 안내하지 않는다 | 6 |
| ``SIMPLELAY_WEATHER_RETRY_MINUTES`` | 실패 뒤 다시 받기까지 기다리는 시간 | 10 |
| ``SIMPLELAY_WEATHER_TIMEOUT_SECONDS`` | 한 번 요청의 상한 | 5 |
| ``SIMPLELAY_WEATHER_HEAT_C`` | 이 기온 이상이면 더위 안내 | 33 |
| ``SIMPLELAY_WEATHER_COLD_C`` | 이 기온 이하면 추위 안내 | -5 |
| ``SIMPLELAY_WEATHER_RAIN_POP`` | 강수형태가 없어도 이 강수확률(%) 이상이면 비 안내 | 60 |
| ``SIMPLELAY_WEATHER_TIP_HOURS`` | 비·더위·추위를 살펴볼 앞으로의 시간 | 12 |
| ``SIMPLELAY_WEATHER_WARN_AREAS`` | 기상특보 구역코드(쉼표로 여럿, 앞부분도 됨). 비우면 허브 위치(폰 앱 '현재 위치로 설정' 또는 LAT/LON)로 정한다. 기상특보 조회서비스 활용 신청이 따로 필요 | 없음 → 위치로 |
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from .grid import latlon_to_grid

log = logging.getLogger(__name__)

MODES = ("off", "mock", "real")


@dataclass(frozen=True)
class WeatherConfig:
    mode: str = "off"
    service_key: str | None = None
    nx: int | None = None
    ny: int | None = None
    stale_hours: float = 6.0
    retry_minutes: float = 10.0
    timeout_seconds: float = 5.0
    heat_c: float = 33.0
    cold_c: float = -5.0
    rain_pop: int = 60
    tip_hours: int = 12
    #: 기상특보 구역코드(10/25). 비면 [lat]/[lon]으로 정한다(warnings.zones_for_location).
    warn_areas: tuple[str, ...] = ()
    lat: float | None = None
    lon: float | None = None
    #: mode가 real인데 키·격자가 없어 끈 이유(로그·개발자 확인용). 사용자 문구가 아니다.
    disabled_reason: str | None = None

    @property
    def enabled(self) -> bool:
        return self.mode in ("mock", "real")

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "WeatherConfig":
        src = os.environ if env is None else env

        def _float(name: str, default: float) -> float:
            raw = (src.get(name) or "").strip()
            if not raw:
                return default
            try:
                return float(raw)
            except ValueError:
                log.warning("%s=%r is not a number; using %s", name, raw, default)
                return default

        def _int(name: str) -> int | None:
            raw = (src.get(name) or "").strip()
            if not raw:
                return None
            try:
                return int(raw)
            except ValueError:
                log.warning("%s=%r is not an integer; ignored", name, raw)
                return None

        mode = (src.get("SIMPLELAY_WEATHER_MODE") or "off").strip().lower() or "off"
        if mode not in MODES:
            log.warning("unknown SIMPLELAY_WEATHER_MODE=%r; weather off", mode)
            mode = "off"
        key = (src.get("SIMPLELAY_KMA_SERVICE_KEY") or "").strip() or None

        lat = lon = None
        try:
            lat = float((src.get("SIMPLELAY_WEATHER_LAT") or "").strip())
            lon = float((src.get("SIMPLELAY_WEATHER_LON") or "").strip())
        except ValueError:
            lat = lon = None
        nx, ny = _int("SIMPLELAY_WEATHER_NX"), _int("SIMPLELAY_WEATHER_NY")
        if nx is None or ny is None:
            lat_raw = (src.get("SIMPLELAY_WEATHER_LAT") or "").strip()
            lon_raw = (src.get("SIMPLELAY_WEATHER_LON") or "").strip()
            if lat_raw and lon_raw:
                try:
                    nx, ny = latlon_to_grid(float(lat_raw), float(lon_raw))
                except ValueError:
                    log.warning("SIMPLELAY_WEATHER_LAT/LON invalid; ignored")
                    nx = ny = None

        reason = None
        if mode == "real":
            if key is None:
                reason = "SIMPLELAY_KMA_SERVICE_KEY not set"
            elif nx is None or ny is None:
                reason = "SIMPLELAY_WEATHER_NX/NY or LAT/LON not set"
            if reason:
                log.warning("weather real mode disabled: %s", reason)
                mode = "off"

        return cls(
            mode=mode,
            service_key=key,
            nx=nx,
            ny=ny,
            stale_hours=_float("SIMPLELAY_WEATHER_STALE_HOURS", 6.0),
            retry_minutes=_float("SIMPLELAY_WEATHER_RETRY_MINUTES", 10.0),
            timeout_seconds=_float("SIMPLELAY_WEATHER_TIMEOUT_SECONDS", 5.0),
            heat_c=_float("SIMPLELAY_WEATHER_HEAT_C", 33.0),
            cold_c=_float("SIMPLELAY_WEATHER_COLD_C", -5.0),
            rain_pop=int(_float("SIMPLELAY_WEATHER_RAIN_POP", 60)),
            tip_hours=max(3, int(_float("SIMPLELAY_WEATHER_TIP_HOURS", 12))),
            warn_areas=tuple(
                p.strip().upper() for p in (src.get("SIMPLELAY_WEATHER_WARN_AREAS") or "").split(",") if p.strip()
            ),
            lat=lat,
            lon=lon,
            disabled_reason=reason,
        )

    def __repr__(self) -> str:  # 키가 로그·예외에 새지 않게
        return (
            f"WeatherConfig(mode={self.mode!r}, key={'set' if self.service_key else 'unset'}, "
            f"nx={self.nx}, ny={self.ny})"
        )
