"""집 모형 상태 — 무장한 동안만 사람 감지를 따르고, 무장 전·만료 뒤에는 모두 꺼진다."""

from __future__ import annotations

import pytest

import rpi.api.model_house_router as mh


@pytest.fixture(autouse=True)
def _reset(monkeypatch):
    monkeypatch.setattr(mh, "_armed_until", 0.0)
    yield


def test_unarmed_model_stays_off_even_when_someone_is_present(monkeypatch):
    monkeypatch.setattr(mh, "_presence_state", lambda: "present")
    s = mh.model_state(now=100.0)
    assert not s.armed and not (s.light or s.fan or s.ceiling_fan)
    assert s.lcd2 == "Standby"


def test_armed_model_follows_presence_and_expires(monkeypatch):
    state = {"v": "present"}
    monkeypatch.setattr(mh, "_presence_state", lambda: state["v"])
    monkeypatch.setattr(mh.time, "monotonic", lambda: 100.0)
    mh.arm(mh.ArmRequest(seconds=60))
    on = mh.model_state(now=110.0)
    assert on.armed and on.light and on.fan and on.ceiling_fan and on.lcd1 == "Welcome home!"
    state["v"] = "away"
    off = mh.model_state(now=120.0)
    assert off.armed and not (off.light or off.fan or off.ceiling_fan)
    assert not mh.model_state(now=161.0).armed


def test_lcd_lines_are_ascii_and_fit_16_columns(monkeypatch):
    assert mh._ascii("공기청정기 ON please now ok") == "      ON please "[:16]
    assert len(mh._ascii("x" * 40)) == 16
