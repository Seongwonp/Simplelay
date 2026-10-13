"""날씨(기상청 단기예보)와 키오스크 평소 화면 안내 — 설계는 docs/devlog/devlog_2026-09-30-ambient-api.md."""

from .ambient import AttentionItem, build_ambient, greeting, hourly_strip, weather_tip
from .config import WeatherConfig
from .grid import latlon_to_grid
from .kma import Forecast, HourlyForecast, KmaError, base_params, fetch_forecast, mock_forecast
from .service import WeatherService, WeatherSnapshot

__all__ = [
    "AttentionItem",
    "Forecast",
    "HourlyForecast",
    "KmaError",
    "WeatherConfig",
    "WeatherService",
    "WeatherSnapshot",
    "base_params",
    "build_ambient",
    "fetch_forecast",
    "greeting",
    "hourly_strip",
    "latlon_to_grid",
    "mock_forecast",
    "weather_tip",
]
