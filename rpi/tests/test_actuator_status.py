"""홈 스위치 준비 판정은 읽을 수 없으면 닫힌다 (fail-closed).

GPIO가 켜진 구성에서 초기화 실패·읽기 오류 때 `준비됨(True)`을 돌려주고
있었다. 개발 PC용 폴백이 실기기에서 위험 쪽으로 열린 것이다 — 스위치를
못 읽었는데 갠트리가 홈에 있다고 말한다.

기준: 읽기 오류·타임아웃·잘못된 값은 모두 `준비 안 됨`. 정상 입력의 판정
(NC 스위치, 홈에서 is_pressed=False)과 GPIO를 끈 개발 구성의 동작은 그대로다.

gpiozero는 가짜 모듈로 끼운다 — 실기기 라이브러리 없이 판정 경계만 본다.
"""

import sys
import threading
import time
import types

import pytest

import rpi.services.actuator as actuator_module
from rpi.services.actuator import ActuatorStatus

X, Y, Z = 17, 27, 22


class _Hang:
    """읽기가 돌아오지 않는 핀."""


@pytest.fixture()
def pins(monkeypatch):
    """핀 번호 → 동작. bool은 is_pressed 값, 예외 인스턴스는 읽을 때 던진다."""
    behaviors: dict[int, object] = {X: False, Y: False, Z: False}
    init_errors: set[int] = set()
    release = threading.Event()

    class FakeButton:
        def __init__(self, pin, pull_up=True):  # noqa: ARG002
            if pin in init_errors:
                raise RuntimeError(f"GPIO{pin} busy")
            self._pin = pin
            self.closed = False

        @property
        def is_pressed(self):
            value = behaviors[self._pin]
            if isinstance(value, BaseException):
                raise value
            if isinstance(value, _Hang):
                release.wait(timeout=2.0)
                return False
            return value

        def close(self):
            self.closed = True

    fake = types.ModuleType("gpiozero")
    fake.Button = FakeButton
    monkeypatch.setitem(sys.modules, "gpiozero", fake)
    # 기존 코드에는 이 상수가 없다 — 수정 전 실행에서도 테스트가 돌도록 raising=False
    monkeypatch.setattr(
        actuator_module, "HOME_SWITCH_READ_TIMEOUT_SECONDS", 0.2, raising=False
    )
    yield types.SimpleNamespace(
        behaviors=behaviors, init_errors=init_errors, release=release
    )
    release.set()


def _status(z: bool = False) -> ActuatorStatus:
    return ActuatorStatus(
        home_x_pin=X, home_y_pin=Y, home_z_pin=Z if z else None, enabled=True
    )


# ── 정상 입력은 기존 판정 그대로 ─────────────────────────────────────────


def test_all_axes_at_home_is_ready(pins):
    assert _status().is_ready() is True


@pytest.mark.parametrize("axis", [X, Y])
def test_axis_away_from_home_is_not_ready(pins, axis):
    pins.behaviors[axis] = True  # NC 스위치가 닫힘 = 홈이 아님

    assert _status().is_ready() is False


def test_optional_z_axis_is_included(pins):
    pins.behaviors[Z] = True

    assert _status(z=False).is_ready() is True
    assert _status(z=True).is_ready() is False


def test_gpio_disabled_keeps_development_fallback():
    """GPIO를 끈 개발 구성은 스위치를 읽지 않는 mock이다 — 종전대로 True."""
    assert ActuatorStatus(enabled=False).is_ready() is True


# ── 읽을 수 없으면 닫힌다 ────────────────────────────────────────────────


def test_init_failure_is_not_ready(pins):
    pins.init_errors.add(Y)

    assert _status().is_ready() is False


def test_optional_z_init_failure_is_not_ready(pins):
    pins.init_errors.add(Z)

    assert _status(z=True).is_ready() is False


@pytest.mark.parametrize("axis", [X, Y, Z])
def test_read_error_on_any_axis_is_not_ready(pins, axis):
    pins.behaviors[axis] = OSError("read failed")

    assert _status(z=True).is_ready() is False


@pytest.mark.parametrize("bad", [None, 0, 1, "HIGH"], ids=["none", "zero", "one", "str"])
def test_non_bool_reading_is_not_ready(pins, bad):
    """gpiozero의 is_pressed는 bool이다. 다른 값은 해석하지 않고 닫는다 —
    `not None`이 True가 되어 홈으로 읽히는 일을 막는다."""
    pins.behaviors[X] = bad

    assert _status().is_ready() is False


def test_hanging_read_times_out_as_not_ready(pins):
    pins.behaviors[X] = _Hang()
    status = _status()

    started = time.monotonic()
    ready = status.is_ready()
    elapsed = time.monotonic() - started

    assert ready is False
    assert elapsed < 1.0, f"읽기 대기 {elapsed:.2f}s — 타임아웃 없이 매달림"


def test_recovers_when_readings_become_valid_again(pins):
    """오류로 한 번 닫혔다고 영구히 닫히지 않는다 — 다음 읽기가 정상이면 판정한다."""
    status = _status()
    pins.behaviors[X] = OSError("glitch")
    assert status.is_ready() is False

    pins.behaviors[X] = False
    assert status.is_ready() is True


# ── /health가 같은 판정을 드러낸다 ──────────────────────────────────────


def test_health_reports_unreadable_switch_as_not_ready(pins):
    from fastapi.testclient import TestClient

    from rpi.api.deps import get_actuator_status
    from rpi.main import app

    pins.behaviors[X] = OSError("read failed")
    status = _status()
    app.dependency_overrides[get_actuator_status] = lambda: status
    try:
        body = TestClient(app).get("/health/detail").json()
    finally:
        app.dependency_overrides.pop(get_actuator_status, None)

    assert body["actuator_ready"] is False
