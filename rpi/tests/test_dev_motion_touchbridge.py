"""앱 개발자 모드(원점·조그·누름)가 HW 담당 원본 규약(touchbridge-v2) 보드에서도 된다(2026-10-25).

모의 보드(rpi/tools/touchbridge_sim.py)로 확인한다 — 실물 확인이 아니다.
"""

from __future__ import annotations

import pytest

from rpi.tests.test_touchbridge_sim import Rig
from rpi4.models.act_messages import DevMotionMsg
from rpi4.services.dev_motion import DevMotionService

pytest.importorskip("serial")


@pytest.fixture()
def rig():
    r = Rig()
    yield r
    if r.client is not None:
        r.client.close()


def test_touchbridge_client_counts_as_real_serial_motion(rig):
    from rpi4.act_main import _is_serial_motion

    assert _is_serial_motion(rig.open())


def test_dev_home_jog_and_press_on_touchbridge(rig):
    client = rig.open()
    client.connect()
    dev = DevMotionService(client)
    home = dev.run(DevMotionMsg(request_id="r1", op="home"))
    assert home["ok"] is True, home
    jog = dev.run(DevMotionMsg(request_id="r2", op="jog", axis="x", delta_mm=5.0))
    assert jog["ok"] is True, jog
    press = dev.run(DevMotionMsg(request_id="r3", op="press", label="30s"))
    assert press["ok"] is True, press


def test_dev_jog_before_home_is_refused(rig):
    client = rig.open()
    client.connect()
    out = DevMotionService(client).run(DevMotionMsg(request_id="r1", op="jog", axis="y", delta_mm=2.0))
    assert out["ok"] is False and out["reason"] == "not_homed"
