"""지연된 ADC 읽기의 세대 격리 — 가짜 읽기만 사용한다."""

import threading

import pytest

from rpi.verifier.config import CurrentSensorConfig
from rpi.verifier.current_sensor import CurrentSensor


@pytest.mark.parametrize("late_error", [False, True])
def test_retired_reader_cannot_publish_into_new_window(late_error):
    entered = threading.Event()
    release = threading.Event()
    fresh = threading.Event()
    old_thread = None

    class Reader:
        def read_voltage(self):
            if threading.current_thread().name == "current-window":
                if not entered.is_set():
                    entered.set()
                    assert release.wait(10)
                    if late_error:
                        raise OSError("late old read")
                    return 2.685
                fresh.set()
            return 2.5

    sensor = CurrentSensor(Reader(), CurrentSensorConfig(window_size=1))
    try:
        sensor.open_window()
        assert entered.wait(2)
        old_thread = sensor._thread
        sensor.cancel_window()  # 실제 join 2초 제한을 넘긴다.
        assert old_thread.is_alive()
        sensor.open_window()
        assert fresh.wait(2)
        release.set()
        old_thread.join(1)
        assert not old_thread.is_alive(), "이전 세대가 새 창에서 계속 수집함"
        result = sensor.close_window()
        assert result.peak_delta_a == 0
        assert not result.pressed
    finally:
        release.set()
        sensor.cancel_window()
        if old_thread is not None:
            old_thread.join(2)
