"""DHT22 온습도 센서 래퍼.

RPi5 환경: BLINKA_LGPIO=1 + adafruit-circuitpython-dht 라이브러리 사용.
미연결 / 라이브러리 미설치 / SIMPLELAY_GPIO_ENABLED=false 시 (None, None) 반환.
호출자(router)에서 None이면 mock 값으로 fallback.

DHT22는 읽기 오류가 잦다 — 일시적 RuntimeError는 무시하고 None 반환.
"""

from __future__ import annotations

import logging
import threading

_log = logging.getLogger(__name__)
_lock = threading.Lock()  # DHT22는 동시 읽기 비지원 — 직렬화 필수


class Dht22Sensor:
    """GPIO_ENABLED=False 또는 라이브러리 미설치 시에도 안전하게 None 반환."""

    def __init__(self, gpio_bcm: int = 4, enabled: bool = False) -> None:
        self._device = None
        self._enabled = enabled

        if not enabled:
            _log.info("DHT22 mock 모드 (SIMPLELAY_GPIO_ENABLED=false)")
            return

        try:
            import board  # noqa: PLC0415
            import adafruit_dht  # noqa: PLC0415

            pin = getattr(board, f"D{gpio_bcm}")
            # use_pulseio=False: RPi4/5에서 pulseio 미지원, 반드시 False
            self._device = adafruit_dht.DHT22(pin, use_pulseio=False)
            _log.info("DHT22 초기화 완료 (BCM %d)", gpio_bcm)
        except Exception as exc:
            _log.warning("DHT22 초기화 실패 — mock 모드로 fallback: %s", exc)

    def read(self) -> tuple[float | None, float | None]:
        """(temperature_°C, humidity_%) — 실패·미연결 시 (None, None)."""
        if self._device is None:
            return None, None
        with _lock:
            try:
                return self._device.temperature, self._device.humidity
            except RuntimeError as exc:
                # DHT22 프로토콜 타이밍 오류 — 일시적이고 흔함, 무시
                _log.debug("DHT22 읽기 타이밍 오류 (일시적): %s", exc)
                return None, None
            except Exception as exc:
                _log.warning("DHT22 읽기 실패: %s", exc)
                return None, None

    def cleanup(self) -> None:
        if self._device is not None:
            try:
                self._device.exit()
            except Exception:
                pass
