"""외부 검토 2026-10-19 (8): 내장 가전 보정 좌표와 정지·보관 위치를 따로따로(두 번의 저장) 적었다.

정지·보관 저장 뒤 보정 좌표 저장이 실패하면 DB에는 새 정지·보관 + 옛 보정이 남아, 다음 기동이 서로 다른 보정에서 나온
위치를 함께 썼다(메모리는 그대로라 지금 프로세스에서는 보이지 않는다). 이제 한 번의 저장(한 트랜잭션)으로 적는다.
"""

from __future__ import annotations

import sqlite3

import pytest

from rpi.services.appliance_registry import ApplianceRegistry, _calibration_key, _stop_park_key
from rpi.services.persistence import SimpleLayDb

STOP_PARK = {"stop_button": "BT-06", "stop_presses": 2, "park_xy": (10.0, 190.0)}


class _FailOnCalibration:
    """보정 좌표 칸을 쓰는 순간 실패하는 연결(그 밖은 그대로 넘긴다)."""

    def __init__(self, conn):
        self._conn = conn

    def execute(self, sql, params=()):
        if any(p == _calibration_key("microwave") for p in params):
            raise sqlite3.OperationalError("disk I/O error")
        return self._conn.execute(sql, params)

    def __enter__(self):
        return self._conn.__enter__()

    def __exit__(self, *exc):
        return self._conn.__exit__(*exc)

    def __getattr__(self, name):
        return getattr(self._conn, name)


def test_failed_calibration_write_leaves_no_half_saved_stop_park(tmp_path):
    db = SimpleLayDb(str(tmp_path / "s.db"))
    reg = ApplianceRegistry(store=db)
    real = db._conn
    db._conn = _FailOnCalibration(real)
    with pytest.raises(sqlite3.OperationalError):
        reg.apply_calibration("microwave", version="v1", coords={"BT-06": (120.0, 80.0)}, stop_park=STOP_PARK)
    db._conn = real
    again = SimpleLayDb(str(tmp_path / "s.db"))
    assert again.load_setting(_stop_park_key("microwave")) is None
    assert again.load_setting(_calibration_key("microwave")) is None
    assert ApplianceRegistry(store=again).get("microwave").stop_button is None


def test_both_are_saved_together(tmp_path):
    reg = ApplianceRegistry(store=SimpleLayDb(str(tmp_path / "s.db")))
    reg.apply_calibration("microwave", version="v1", coords={"BT-06": (120.0, 80.0)}, stop_park=STOP_PARK)
    again = ApplianceRegistry(store=SimpleLayDb(str(tmp_path / "s.db"))).get("microwave")
    assert again.stop_button == "BT-06" and again.calibration_version == "v1" and again.revision == 1
