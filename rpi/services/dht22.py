"""DHT22 온습도 센서 래퍼.

RPi5에서는 lgpio로 데이터선의 엣지 시각(µs)을 받아 40비트를 풀어 읽는다(2026-10-20).
Adafruit DHT 라이브러리의 파이썬 비트뱅은 RPi5에서 'sensor not found'만 냈고, 같은 배선에서
lgpio 엣지 시각 방식은 체크섬까지 맞게 읽혔다(실측 26.5 °C·54 %, 6회 연속).

미연결 / 라이브러리 미설치 / 꺼짐(SIMPLELAY_DHT22_ENABLED·SIMPLELAY_GPIO_ENABLED) 시 (None, None).
호출자(router)는 None이면 mock 값과 mocked=True로 답한다 — 화면은 실측일 때만 온습도를 보인다.

DHT22는 읽기 실패가 잦다 — 몇 번 다시 읽고, 마지막 정상 값을 짧게(10 s) 재사용한다.
같은 센서를 2 s보다 자주 읽으면 오래된 값이 나오므로 그 안의 요청은 캐시로 답한다.
"""

from __future__ import annotations

import logging
import threading
import time

_log = logging.getLogger(__name__)
_lock = threading.Lock()  # DHT22는 동시 읽기 비지원 — 직렬화 필수

_MIN_INTERVAL_S = 2.0  # 센서 사양: 2 s보다 자주 읽지 않는다
_CACHE_S = 10.0  # 마지막 정상 값을 이만큼 재사용(읽기 실패가 잦아서)
_ATTEMPTS = 3


def decode_high_pulses(high_us: list[float]) -> tuple[float, float] | None:
    """High 펄스 길이(µs) 목록 → (온도 °C, 습도 %). 40비트가 안 되거나 체크섬이 틀리면 None.

    DHT22 비트: 0 ≈ 26–28 µs, 1 ≈ 70 µs high. 앞쪽 응답 펄스(80 µs)는 마지막 40개만 써서 버린다.
    """
    if len(high_us) < 40:
        return None
    bits = [1 if w > 50 else 0 for w in high_us[-40:]]
    data = [int("".join(map(str, bits[i * 8 : i * 8 + 8])), 2) for i in range(5)]
    if (sum(data[:4]) & 0xFF) != data[4]:
        return None
    humidity = ((data[0] << 8) | data[1]) / 10
    raw_t = ((data[2] & 0x7F) << 8) | data[3]
    temperature = -raw_t / 10 if data[2] & 0x80 else raw_t / 10
    if not (0 <= humidity <= 100 and -40 <= temperature <= 80):
        return None
    return temperature, humidity


class Dht22Sensor:
    """꺼짐 또는 lgpio 미설치·장치 없음이면 안전하게 None을 돌려준다."""

    def __init__(self, gpio_bcm: int = 4, enabled: bool = False, chip: int = 0) -> None:
        self._pin = gpio_bcm
        self._chip = chip
        self._handle = None
        self._lgpio = None
        self._last: tuple[float, float] | None = None
        self._last_at = 0.0
        self._last_try = 0.0

        if not enabled:
            _log.info("DHT22 꺼짐 (SIMPLELAY_DHT22_ENABLED/SIMPLELAY_GPIO_ENABLED)")
            return
        try:
            import lgpio  # noqa: PLC0415

            self._lgpio = lgpio
            self._handle = lgpio.gpiochip_open(chip)
            _log.info("DHT22 준비 (gpiochip%d, BCM %d)", chip, gpio_bcm)
        except Exception as exc:
            _log.warning("DHT22 초기화 실패 — 실측 없이 동작: %s", exc)
            self._handle = None

    def _read_once(self) -> tuple[float, float] | None:
        lg, h, pin = self._lgpio, self._handle, self._pin
        edges: list[tuple[int, int]] = []

        def _cb(_chip, _gpio, level, tick):
            edges.append((level, tick))

        # 시작 신호: 2 ms LOW 뒤 놓고(풀업), 센서 응답의 엣지 시각을 모은다.
        lg.gpio_claim_output(h, pin, 0)
        time.sleep(0.002)
        lg.gpio_free(h, pin)
        lg.gpio_claim_alert(h, pin, lg.BOTH_EDGES, lg.SET_PULL_UP)
        cb = lg.callback(h, pin, lg.BOTH_EDGES, _cb)
        try:
            time.sleep(0.05)
        finally:
            cb.cancel()
            lg.gpio_free(h, pin)
        highs = [
            (edges[i + 1][1] - edges[i][1]) / 1000
            for i in range(len(edges) - 1)
            if edges[i][0] == 1 and edges[i + 1][0] == 0
        ]
        return decode_high_pulses(highs)

    def read(self) -> tuple[float | None, float | None]:
        """(temperature_°C, humidity_%) — 실패·미연결 시 (None, None)."""
        if self._handle is None:
            return None, None
        with _lock:
            now = time.monotonic()
            if self._last and now - self._last_try < _MIN_INTERVAL_S:
                return self._last
            for attempt in range(_ATTEMPTS):
                if attempt:
                    time.sleep(_MIN_INTERVAL_S)
                self._last_try = time.monotonic()
                try:
                    got = self._read_once()
                except Exception as exc:  # noqa: BLE001
                    _log.warning("DHT22 읽기 실패: %s", exc)
                    got = None
                if got is not None:
                    self._last, self._last_at = got, time.monotonic()
                    return got
            if self._last and time.monotonic() - self._last_at < _CACHE_S:
                return self._last
            return None, None

    def cleanup(self) -> None:
        if self._handle is not None and self._lgpio is not None:
            try:
                self._lgpio.gpiochip_close(self._handle)
            except Exception:
                pass
