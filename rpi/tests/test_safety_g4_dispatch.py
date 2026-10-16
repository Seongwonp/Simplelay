"""G4: 실제 어댑터 쓰기 경계, 메모리 시리얼과 가짜 MCU. 물리 정지 시험 아님."""
import json
import threading

import pytest

from rpi.controller import PressCommand
from rpi.controller.serial_motion import InMemoryLinePipe, MotionStopped
from rpi.tests.test_serial_motion import _homed_client
from rpi.tools.fake_mcu import FakeMcu


class PausedLock:
    """동작 스레드만 잠금 획득 직전에 멈춘다. 정지 쓰기는 통과한다."""

    def __init__(self, lock, entered, resume):
        self.lock, self.entered, self.resume = lock, entered, resume

    def __enter__(self):
        if threading.current_thread().name == "g4-operation":
            self.entered.set()
            assert self.resume.wait(3), "시험 동작 해제 누락"
        self.lock.acquire()
        return self

    def __exit__(self, *args):
        self.lock.release()


@pytest.mark.parametrize("operation", ["home", "move", "press"])
@pytest.mark.parametrize("boundary", ["operation_lock", "before_send", "write_lock"])
def test_stop_completed_before_dispatch_sends_no_motion(monkeypatch, operation, boundary):
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    client = _homed_client(pipe)
    sent, errors = [], []
    entered, resume = threading.Event(), threading.Event()
    write = pipe.host.write_line

    def record(line):
        sent.append(json.loads(line)["cmd"])
        write(line)

    monkeypatch.setattr(pipe.host, "write_line", record)
    if boundary == "before_send":
        send = client._send_request

        def pause(body):
            entered.set()
            assert resume.wait(3)
            return send(body)

        monkeypatch.setattr(client, "_send_request", pause)
    else:
        attr = "_op_lock" if boundary == "operation_lock" else "_write_lock"
        monkeypatch.setattr(client, attr, PausedLock(getattr(client, attr), entered, resume))

    def run():
        try:
            if operation == "home":
                client.home()
            elif operation == "move":
                client.move_to(1, 1)
            else:
                client.press(PressCommand("시작", x_mm=1, y_mm=1))
        except BaseException as exc:
            errors.append(exc)

    worker = threading.Thread(target=run, name="g4-operation")
    try:
        worker.start()
        assert entered.wait(3)
        assert client.request_stop()
        resume.set()
        worker.join(3)
        assert not worker.is_alive()
        assert sent == ["stop"], sent
        assert len(errors) == 1 and isinstance(errors[0], MotionStopped), errors
    finally:
        resume.set()
        worker.join(3)
        mcu.close()


def test_stop_still_allows_status_and_next_explicit_run():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    try:
        client = _homed_client(pipe)
        assert client.request_stop()
        client.status()
        client.reset_stop()
        client.home()
        client.move_to(1, 1)
        assert mcu.cmds().count("move") == 1
    finally:
        mcu.close()


def test_stop_after_final_press_check_blocks_z_write(monkeypatch):
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    try:
        client = _homed_client(pipe)
        sent = []
        write = pipe.host.write_line
        def record(line):
            sent.append(json.loads(line)["cmd"])
            write(line)
        monkeypatch.setattr(pipe.host, "write_line", record)
        send = client._send_request
        def stop_before_z(body):
            if body["cmd"] == "press":
                assert client.request_stop()
            return send(body)
        monkeypatch.setattr(client, "_send_request", stop_before_z)
        with pytest.raises(MotionStopped):
            client.press(PressCommand("시작", x_mm=1, y_mm=1))
        assert sent == ["move", "stop"]
    finally:
        mcu.close()
