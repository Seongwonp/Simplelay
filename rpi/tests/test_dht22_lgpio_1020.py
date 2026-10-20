"""DHT22를 lgpio 엣지 시각으로 읽기(2026-10-20) — 해석과 '센서만 켜기' 설정.

실측: 같은 배선에서 Adafruit 비트뱅은 'sensor not found', lgpio 엣지 방식은 체크섬까지 맞게 읽혔다.
센서를 GPIO17(원점 스위치 기본 핀)에 꽂은 구성이라, 센서만 켜도 원점 스위치 GPIO는 켜지지 않아야 한다.
"""

from __future__ import annotations

import importlib

from rpi.services.dht22 import Dht22Sensor, decode_high_pulses


def _pulses(data: list[int]) -> list[float]:
    """5바이트 → high 펄스 길이(µs). 앞에 센서 응답 펄스(80 µs) 하나를 붙인다."""
    bits = [int(b) for byte in data for b in f"{byte:08b}"]
    return [80.0] + [70.0 if b else 27.0 for b in bits]


def test_decode_valid_frame():
    # 습도 54.2 % = 542 = 0x021E, 온도 26.5 °C = 265 = 0x0109
    data = [0x02, 0x1E, 0x01, 0x09]
    data.append(sum(data) & 0xFF)
    assert decode_high_pulses(_pulses(data)) == (26.5, 54.2)


def test_decode_negative_temperature():
    data = [0x01, 0xF4, 0x80, 0x32]  # 50.0 %, -5.0 °C
    data.append(sum(data) & 0xFF)
    assert decode_high_pulses(_pulses(data)) == (-5.0, 50.0)


def test_decode_rejects_bad_checksum_and_short_frames():
    data = [0x02, 0x1E, 0x01, 0x09, 0x00]
    assert decode_high_pulses(_pulses(data)) is None
    assert decode_high_pulses([70.0] * 20) is None


def test_disabled_sensor_reads_none():
    assert Dht22Sensor(gpio_bcm=17, enabled=False).read() == (None, None)


def test_dht_only_does_not_enable_home_switch_gpio(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_GPIO_ENABLED", raising=False)
    monkeypatch.setenv("SIMPLELAY_DHT22_ENABLED", "true")
    monkeypatch.setenv("SIMPLELAY_DHT22_GPIO", "17")
    import rpi.api.config as config

    cfg = importlib.reload(config).hardware_config
    try:
        assert cfg.dht22_enabled is True
        assert cfg.gpio_enabled is False  # 원점 스위치(GPIO17·27)는 켜지지 않는다
        assert cfg.dht22_gpio == 17
    finally:
        monkeypatch.delenv("SIMPLELAY_DHT22_ENABLED")
        monkeypatch.delenv("SIMPLELAY_DHT22_GPIO")
        importlib.reload(config)


def test_dht_follows_gpio_enabled_when_not_set(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_DHT22_ENABLED", raising=False)
    monkeypatch.setenv("SIMPLELAY_GPIO_ENABLED", "true")
    import rpi.api.config as config

    cfg = importlib.reload(config).hardware_config
    try:
        assert cfg.dht22_enabled is True
    finally:
        monkeypatch.delenv("SIMPLELAY_GPIO_ENABLED")
        importlib.reload(config)
