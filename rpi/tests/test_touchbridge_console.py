from __future__ import annotations

import io
import queue
import threading

import pytest

from rpi.tools.touchbridge_console import Console, command_line


class Port:
    def __init__(self):
        self.rx = queue.Queue()
        self.writes = []
        self.closed = False
        self.seen = threading.Event()

    def write(self, data):
        self.writes.append(data)
        return len(data)

    def readline(self):
        try:
            item = self.rx.get(timeout=0.02)
        except queue.Empty:
            return b""
        if isinstance(item, Exception):
            raise item
        if item == b"PRESSED\n":
            self.seen.set()
        return item

    def close(self):
        self.closed = True


def test_open_does_not_home_stop_or_move_and_reader_keeps_async_events():
    port = Port()
    out, log = io.StringIO(), io.StringIO()
    console = Console(port, out=out, log=log)
    console.start()
    assert port.writes == []
    console.send("P")
    for line in [b"OK\n", b"DONE 20.00 0.00\n", b"PRESSED\n"]:
        port.rx.put(line)
    assert port.seen.wait(1)
    console.close()
    assert port.writes == [b"P\n"]
    assert "DONE 20.00 0.00" in out.getvalue()
    assert "PRESSED" in log.getvalue()
    assert port.closed


def test_reader_failure_is_visible_instead_of_silently_hanging():
    port = Port()
    out = io.StringIO()
    console = Console(port, out=out)
    console.start()
    port.rx.put(OSError("unplugged"))
    assert console.failed.wait(1)
    console.close()
    assert "unplugged" in out.getvalue()


@pytest.mark.parametrize("text", ["", " ", "P\nM 1 1 500", "P\r", "P\0", "a" * 256, "가" * 86])
def test_invalid_command_does_not_reach_the_serial_port(text):
    port = Port()
    with pytest.raises(ValueError):
        Console(port, out=io.StringIO()).send(text)
    assert port.writes == []


def test_full_length_line_and_original_pwm_are_unchanged():
    assert len(command_line("a" * 255)) == 256
    assert command_line("M 0.5 0.5 300") == b"M 0.5 0.5 300\n"
