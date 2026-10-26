"""개발자 기록이 '보낸 명령과 보드 답'을 보이고, 보드 범위 거절(ERROR_LIMIT)이 바로 돌아온다(2026-10-26).

- RPi4: Touch Bridge 보드의 ``ERROR_LIMIT``은 기한을 기다리지 않고 ``soft_limit``·``board_state``로 답한다.
  조그 답에 보낸 절대 목표(``target_x_mm``·``target_y_mm``)와 성공 시 ``error_mm``을 싣는다.
- RPi4: 원점 반올림(-0.1 mm 이상 0 미만) 목표는 0으로 보낸다. 더 음수면 그대로 보내 보드 거절을 받는다.
- RPi5: ``GET /dev/log``에 ``command``·``code``·``board``가 실리고, 거절 응답 ``detail.board_state``가 실린다.

모의 보드·가짜 링크로만 확인한다 — 실물 확인이 아니다.
"""

from __future__ import annotations

import time

import pytest

from rpi.tests.test_dev_real_motion import _code, rig  # noqa: F401 - pytest fixture
from rpi4.models.act_messages import DevMotionMsg
from rpi4.services.dev_motion import DevMotionService, clamp_near_zero

# ── RPi4: 모의 Touch Bridge 보드 ────────────────────────────────────────────


@pytest.fixture()
def tb_rig():
    pytest.importorskip("serial")
    from rpi.tests.test_touchbridge_sim import Rig

    r = Rig()
    yield r
    if r.client is not None:
        r.client.close()


def test_board_error_limit_comes_back_at_once_with_the_board_state(tb_rig):
    client = tb_rig.open(move_timeout_s=3.0)
    client.connect()
    dev = DevMotionService(client)
    assert dev.run(DevMotionMsg(request_id="h", op="home"))["ok"] is True
    started = time.monotonic()
    out = dev.run(DevMotionMsg(request_id="j", op="jog", axis="y", delta_mm=-1.0))
    assert time.monotonic() - started < 1.0  # 이동 기한(3 s)을 기다리지 않는다
    assert out["ok"] is False and out["moved"] is False
    assert out["reason"] == "soft_limit" and out["board_state"] == "ERROR_LIMIT"
    assert (out["target_x_mm"], out["target_y_mm"]) == (0.0, -1.0)


def test_jog_reply_carries_the_target_and_the_error(tb_rig):
    client = tb_rig.open()
    client.connect()
    dev = DevMotionService(client)
    dev.run(DevMotionMsg(request_id="h", op="home"))
    out = dev.run(DevMotionMsg(request_id="j", op="jog", axis="x", delta_mm=2.0))
    assert out["ok"] is True, out
    assert (out["target_x_mm"], out["target_y_mm"]) == (2.0, 0.0)
    assert 0 <= out["error_mm"] < 1.0


# ── RPi4: 원점 반올림 0으로 ─────────────────────────────────────────────────


class _OffsetClient:
    """원점을 잡은 뒤 보드가 -0.04를 보고하는 모션 클라이언트(목표만 기록, 움직이지 않음)."""

    homed = True
    ready_info: dict = {}

    def __init__(self, x: float, y: float) -> None:
        self.xy = (x, y)
        self.targets: list[tuple[float, float]] = []

    def status(self):
        return None

    def position_xy(self, _status=None):
        return self.xy

    def reset_stop(self) -> None:
        pass

    def move_to(self, x: float, y: float) -> None:
        self.targets.append((x, y))
        self.xy = (x, y)

    @property
    def last_position(self):
        return {"x_mm": self.xy[0], "y_mm": self.xy[1]}


@pytest.mark.parametrize(("value", "expected"), [
    (-0.04, 0.0), (-0.1, 0.0), (0.0, 0.0), (0.3, 0.3), (-0.11, -0.11), (-1.0, -1.0),
])
def test_clamp_near_zero(value, expected):
    assert clamp_near_zero(value) == expected


def test_origin_rounding_on_the_other_axis_is_sent_as_zero():
    client = _OffsetClient(-0.04, -0.04)
    out = DevMotionService(client).run(DevMotionMsg(request_id="j", op="jog", axis="x", delta_mm=2.0))
    assert client.targets == [(1.96, 0.0)]
    assert out["ok"] is True and out["target_y_mm"] == 0.0


def test_a_real_negative_target_is_still_sent_for_the_board_to_refuse():
    client = _OffsetClient(0.0, 0.5)
    DevMotionService(client).run(DevMotionMsg(request_id="j", op="jog", axis="y", delta_mm=-1.0))
    assert client.targets == [(0.0, -0.5)]


# ── RPi5: 개발자 기록·거절 응답 ─────────────────────────────────────────────


def _log(r) -> list[dict]:
    res = r.client.get("/dev/log", headers=r.headers())
    assert res.status_code == 200
    return res.json()


def test_board_limit_refusal_is_recorded_with_what_was_sent(rig) -> None:  # noqa: F811
    r = rig(max_step_mm=5.0)
    sid, secret = r.open_session()
    r.link.replies["jog"] = {"ok": False, "op": "jog", "reason": "soft_limit", "moved": False,
                             "detail": "움직이기 전에 거절되었어요: Touch Bridge ERROR_LIMIT: ",
                             "board_state": "ERROR_LIMIT", "target_x_mm": 0.0, "target_y_mm": 9.96}
    res = r.command(sid, secret, "jog y + 5")
    assert res.status_code == 422 and _code(res) == "soft_limit"
    assert res.json()["detail"]["board_state"] == "ERROR_LIMIT"
    assert "stop" not in r.link.ops()
    entry = next(e for e in _log(r) if e["command"] == "jog y + 5")
    assert entry["event"] == "command_rejected" and entry["code"] == "soft_limit"
    assert entry["board"] == {"board_state": "ERROR_LIMIT", "target_x_mm": 0.0, "target_y_mm": 9.96}


def test_arrival_is_recorded_with_target_position_and_error(rig) -> None:  # noqa: F811
    r = rig(max_step_mm=5.0)
    sid, secret = r.open_session()
    r.link.replies["jog"] = {"ok": True, "op": "jog", "homed": True, "x_mm": 2.06, "y_mm": 0.0,
                             "reached": True, "target_x_mm": 2.0, "target_y_mm": 0.0, "error_mm": 0.06}
    res = r.command(sid, secret, "jog x + 2")
    assert res.status_code == 200
    # 화면 응답의 sensor는 종전 모양 — 목표·오차는 기록으로만 간다.
    assert set(res.json()["sensor"]) == {"x_mm", "y_mm", "reached"}
    entry = next(e for e in _log(r) if e["command"] == "jog x + 2")
    assert entry["event"] == "command_accepted"
    assert entry["board"] == {"target_x_mm": 2.0, "target_y_mm": 0.0, "x_mm": 2.06, "y_mm": 0.0,
                              "error_mm": 0.06, "reached": True}


def test_alarm_after_moving_is_recorded_before_the_safety_stop(rig) -> None:  # noqa: F811
    r = rig()
    sid, secret = r.open_session()
    r.link.replies["jog"] = {"ok": False, "op": "jog", "reason": "motion_alarm", "moved": None,
                             "detail": "Touch Bridge ERROR_STALL: ", "board_state": "ERROR_STALL",
                             "target_x_mm": 1.0, "target_y_mm": 0.0}
    res = r.command(sid, secret, "jog x + 1")
    assert res.status_code == 502 and _code(res) == "command_error"
    assert res.json()["detail"]["board_state"] == "ERROR_STALL"
    events = [e["event"] for e in reversed(_log(r))]  # /dev/log는 최신 먼저
    assert events.index("command_failed") < events.index("stopped")
    failed = next(e for e in _log(r) if e["event"] == "command_failed")
    assert failed["command"] == "jog x + 1" and failed["code"] == "motion_alarm"
    assert failed["board"]["board_state"] == "ERROR_STALL"


def test_hub_side_refusal_names_the_command_it_did_not_send(rig) -> None:  # noqa: F811
    r = rig()
    sid, secret = r.open_session()
    res = r.command(sid, secret, "jog x + 3")
    assert _code(res) == "step_too_large"
    entry = next(e for e in _log(r) if e["command"] == "jog x + 3")
    assert entry["code"] == "step_too_large" and entry["board"] is None
    assert "jog" not in r.link.ops()


def test_log_has_no_secrets(rig) -> None:  # noqa: F811
    r = rig()
    sid, secret = r.open_session()
    r.command(sid, secret, "jog x + 1")
    text = r.client.get("/dev/log", headers=r.headers()).text
    assert secret not in text and "dev-token" not in text
