"""방 밝기 판단(2026-10-26) — 30초 평균·히스테리시스·오래된 파일·꺼짐."""

import os
import time

from rpi.services.room_light import DARK, LIGHT, UNKNOWN, LightSnapshot, RoomLight, read_level


class _Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


def _feed(light, clock, level, n=1, step=2.0):
    out = None
    for _ in range(n):
        clock.t += step
        out = light.observe(level) or out
    return out


def test_hysteresis_keeps_state_between_thresholds():
    clock = _Clock()
    light = RoomLight(dark_below=115, light_above=135, now=clock)
    assert light.snapshot().state == UNKNOWN
    _feed(light, clock, 125, 3)
    assert light.snapshot().state == UNKNOWN, "문턱 사이로 시작하면 아직 정하지 않는다"
    _feed(light, clock, 160, 20)
    assert light.snapshot().state == LIGHT
    _feed(light, clock, 125, 20)  # 평균이 125 — 사이: 밝음 유지
    assert light.snapshot() == LightSnapshot(LIGHT, 125)
    assert _feed(light, clock, 100, 20) == DARK
    _feed(light, clock, 130, 20)
    assert light.snapshot().state == DARK


def test_rolling_mean_damps_a_single_spike():
    clock = _Clock()
    light = RoomLight(now=clock)
    _feed(light, clock, 100, 15)
    assert light.snapshot().state == DARK
    _feed(light, clock, 255, 1)  # 한 장 번쩍(문 열림·화면 빛)
    assert light.snapshot().state == DARK


def test_stale_samples_become_unknown():
    clock = _Clock()
    light = RoomLight(now=clock, stale_s=20)
    _feed(light, clock, 160, 5)
    assert light.snapshot().state == LIGHT
    clock.t += 21
    light.observe(None)
    assert light.snapshot() == LightSnapshot(UNKNOWN, None)


def test_read_level_checks_size_and_age(tmp_path):
    path = tmp_path / "light.raw"
    assert read_level(str(path)) is None
    path.write_bytes(bytes([100]) * 192)
    assert read_level(str(path)) == 100
    path.write_bytes(bytes([100]) * 10)
    assert read_level(str(path)) is None
    path.write_bytes(bytes([100]) * 192)
    old = time.time() - 60
    os.utime(path, (old, old))
    assert read_level(str(path), stale_s=20) is None


def _get_room(monkeypatch):
    from fastapi.testclient import TestClient

    from rpi.main import app

    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    return TestClient(app).get("/presence/room").json()


def test_route_reports_light_unknown_when_off(monkeypatch):
    import rpi.api.room_presence_wiring as wiring

    monkeypatch.delenv("SIMPLELAY_ROOM_LIGHT_FILE", raising=False)
    monkeypatch.delenv("SIMPLELAY_ROOM_PRESENCE_FILE", raising=False)
    wiring.get_room_light.cache_clear()
    wiring.get_room_presence.cache_clear()
    try:
        body = _get_room(monkeypatch)
    finally:
        wiring.get_room_light.cache_clear()
        wiring.get_room_presence.cache_clear()
    assert body["light"] == {"state": "unknown", "level": None}


def test_route_reports_dark_from_the_file_even_without_presence(tmp_path, monkeypatch):
    import rpi.api.room_presence_wiring as wiring

    path = tmp_path / "light.raw"
    path.write_bytes(bytes([90]) * 192)
    monkeypatch.setenv("SIMPLELAY_ROOM_LIGHT_FILE", str(path))
    monkeypatch.delenv("SIMPLELAY_ROOM_PRESENCE_FILE", raising=False)
    wiring.get_room_light.cache_clear()
    wiring.get_room_presence.cache_clear()
    try:
        assert wiring.poll_room_light_once(str(path)) == DARK
        body = _get_room(monkeypatch)
    finally:
        wiring.get_room_light.cache_clear()
        wiring.get_room_presence.cache_clear()
    assert body["enabled"] is False
    assert body["light"] == {"state": "dark", "level": 90}
