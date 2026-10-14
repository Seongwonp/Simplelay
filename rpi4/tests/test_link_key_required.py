"""링크 키 필수(2026-10-14 보안 1차 점검 HIGH) — 실제 운영 진입점에서 확인한다.

전에는 ``SIMPLELAY_LINK_KEY``가 없으면 경고만 남기고 RPi4 실행기·RPi5 링크가 인증 없이 돌았다(같은 Wi-Fi의 누구나
TCP 7000으로 execute를 보낼 수 있었다). 고친 뒤 기대:

- 키 없음 → RPi4 ``act_main._run``·RPi5 ``open_uart_act_controller``·RPi5 기동(lifespan, ``SIMPLELAY_ACT_MODE=uart``)이
  링크를 열기 전에 거절한다. 시리얼·소켓을 한 번도 열지 않고, 모터 누름 0회.
- ``SIMPLELAY_LINK_AUTH=off_for_mock``(명시 모의 설정)이라도 실물 경로가 하나라도 켜져 있으면 거절한다
  (RPi4: 모션 serial·실물 콘센트 모듈·L3 real·실센서, RPi5: 개발자 실물 조작).
- 모의 구성 + off_for_mock만 인증 없이 연다(경고 한 번). 키가 있으면 키가 이긴다.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import types

import pytest

from rpi.services.link_auth import LinkAuthRequiredError, LinkKeyError, link_key_from_env

KEY = "pairing-key-for-tests-0123"

_ENV = (
    "SIMPLELAY_LINK_KEY", "SIMPLELAY_LINK_AUTH", "SIMPLELAY_MOTION_MODE", "SIMPLELAY_OUTLET_PORT",
    "SIMPLELAY_L3_MODE", "SIMPLELAY_SENSORS_ENABLED", "SIMPLELAY_DEV_REAL_MOTION", "SIMPLELAY_ACT_MODE",
)


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _ENV:
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def opened(monkeypatch):
    """가짜 serial_asyncio — 링크를 열려고 하면 기록하고 실패시킨다(거절 경로는 이것이 비어 있어야 한다)."""
    calls: list[str] = []

    async def open_serial_connection(url, baudrate):
        calls.append(url)
        raise ConnectionRefusedError("test: link must not be opened")

    fake = types.ModuleType("serial_asyncio")
    fake.open_serial_connection = open_serial_connection  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "serial_asyncio", fake)
    return calls


@pytest.fixture
def presses(monkeypatch):
    """RPi4 실행기가 만드는 모의 모터의 누름 기록."""
    import rpi4.act_main as act_main
    from rpi.controller.mock import MockGrblClient

    made: list[MockGrblClient] = []

    def make(*a, **k):
        grbl = MockGrblClient()
        made.append(grbl)
        return grbl

    monkeypatch.setattr(act_main, "MockGrblClient", make)
    return lambda: [c.button for g in made for c in g.commands]


# ── RPi4 실행기 진입점 ─────────────────────────────────────────────────────────


def test_rpi4_without_key_refuses_before_opening_the_link(opened, presses):
    import rpi4.act_main as act_main

    with pytest.raises(LinkAuthRequiredError) as err:
        asyncio.run(act_main._run())
    assert "SIMPLELAY_LINK_KEY" in str(err.value)
    assert opened == [] and presses() == []


@pytest.mark.parametrize("env", [
    {"SIMPLELAY_MOTION_MODE": "serial"},
    {"SIMPLELAY_OUTLET_PORT": "/dev/ttyACM9"},
    {"SIMPLELAY_L3_MODE": "real"},
    {"SIMPLELAY_SENSORS_ENABLED": "true"},
], ids=["motion_serial", "real_outlet", "l3_real", "sensors"])
def test_rpi4_mock_only_flag_with_a_real_path_refuses(monkeypatch, opened, presses, env):
    """모의 허용 플래그 하나로 실물 장치까지 무인증이 되면 안 된다."""
    import rpi4.act_main as act_main

    monkeypatch.setenv("SIMPLELAY_LINK_AUTH", "off_for_mock")
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    with pytest.raises(LinkAuthRequiredError) as err:
        asyncio.run(act_main._run())
    assert next(iter(env)) in str(err.value)
    assert opened == [] and presses() == []


def test_rpi4_mock_only_flag_in_a_mock_configuration_opens_unauthenticated(monkeypatch, opened, caplog):
    import rpi4.act_main as act_main

    monkeypatch.setenv("SIMPLELAY_LINK_AUTH", "off_for_mock")
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "fake")  # 가짜 콘센트 출력은 모의다
    with caplog.at_level(logging.WARNING), pytest.raises(ConnectionRefusedError):
        asyncio.run(act_main._run())
    assert opened == [act_main.SERIAL_PORT]  # 키 검사를 지나 링크를 열려고 했다
    assert any("off_for_mock" in r.getMessage() for r in caplog.records)


def test_other_values_of_the_flag_do_not_open(monkeypatch, opened):
    import rpi4.act_main as act_main

    for value in ("off", "1", "true", "OFF_FOR_MOCKS"):
        monkeypatch.setenv("SIMPLELAY_LINK_AUTH", value)
        with pytest.raises(LinkAuthRequiredError):
            asyncio.run(act_main._run())
    assert opened == []


# ── RPi5 진입점 ─────────────────────────────────────────────────────────────


def test_rpi5_factory_without_key_refuses_before_opening_the_link(opened):
    from rpi.services import act_client_controller as acc

    with pytest.raises(LinkAuthRequiredError):
        acc.open_uart_act_controller("socket://rpi4:7000", 115200)
    assert opened == []


def test_rpi5_mock_only_flag_with_dev_real_motion_refuses(monkeypatch, opened):
    from rpi.services import act_client_controller as acc

    monkeypatch.setenv("SIMPLELAY_LINK_AUTH", "off_for_mock")
    monkeypatch.setenv("SIMPLELAY_DEV_REAL_MOTION", "1")
    with pytest.raises(LinkAuthRequiredError) as err:
        acc.open_uart_act_controller("socket://rpi4:7000", 115200)
    assert "SIMPLELAY_DEV_REAL_MOTION" in str(err.value)
    assert opened == []


def test_rpi5_backend_startup_refuses_uart_mode_without_key(monkeypatch, opened):
    """기동 거절 — 첫 요청 때가 아니라 띄울 때(lifespan). 실행 요청은 한 번도 처리되지 않는다."""
    from fastapi.testclient import TestClient

    from rpi.main import app

    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    with pytest.raises(LinkAuthRequiredError):
        with TestClient(app):
            pass
    assert opened == []


def test_key_wins_over_the_mock_only_flag():
    env = {"SIMPLELAY_LINK_KEY": KEY, "SIMPLELAY_LINK_AUTH": "off_for_mock"}
    assert link_key_from_env(env, real_paths=["SIMPLELAY_MOTION_MODE=serial"]) == KEY.encode()


def test_short_key_is_still_a_key_error():
    with pytest.raises(LinkKeyError):
        link_key_from_env({"SIMPLELAY_LINK_KEY": "short"})
