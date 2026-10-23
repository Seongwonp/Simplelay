"""Standalone USB console for the received Touch Bridge firmware.

Opening the console sends nothing. Commands are entered verbatim; one reader
keeps printing asynchronous motion/Bot events after an initial OK response.
Only pyserial is needed on the device (no SimpleLay server or RPi5).
"""

from __future__ import annotations

import argparse
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import TextIO


def command_line(value: str) -> bytes:
    """The sketch's 256-byte buffer has room for 255 bytes plus a terminator."""
    if not value.strip() or any(c in value for c in ("\r", "\n", "\0")):
        raise ValueError("한 번에 명령 한 줄을 입력해 주세요")
    data = value.encode("utf-8")
    if len(data) > 255:
        raise ValueError("ESP32 명령은 UTF-8 255바이트 이하여야 해요")
    return data + b"\n"


class Console:
    def __init__(self, serial_port, *, out: TextIO, log: TextIO | None = None) -> None:
        self.port = serial_port
        self.out = out
        self.log = log
        self._closed = threading.Event()
        self.failed = threading.Event()
        self._write_lock = threading.Lock()
        self._print_lock = threading.Lock()
        self._reader: threading.Thread | None = None

    def note(self, direction: str, text: str) -> None:
        stamp = datetime.now().isoformat(timespec="milliseconds")
        line = f"{stamp} mono_ns={time.monotonic_ns()} {direction} {text}"
        with self._print_lock:
            print(line, file=self.out, flush=True)
            if self.log is not None:
                print(line, file=self.log, flush=True)

    def start(self) -> None:
        self._reader = threading.Thread(target=self._read, daemon=True, name="touchbridge-console")
        self._reader.start()

    def send(self, text: str) -> None:
        data = command_line(text)
        with self._write_lock:
            written = self.port.write(data)
            if written != len(data):
                raise OSError("시리얼 명령을 끝까지 쓰지 못했어요")
            self.note(">>", text)

    def _read(self) -> None:
        try:
            while not self._closed.is_set():
                line = self.port.readline()
                if line:
                    self.note("<<", line.decode("utf-8", errors="replace").rstrip("\r\n"))
        except (OSError, RuntimeError, TypeError) as exc:
            if not self._closed.is_set():
                self.note("!!", f"시리얼 읽기 종료: {exc}")
                self.failed.set()

    def close(self) -> None:
        self._closed.set()
        if self._reader is not None:
            self._reader.join(timeout=1)
        self.port.close()
        if self._reader is not None and self._reader.is_alive():
            self._reader.join(timeout=1)


HELP = """명령을 그대로 입력하세요 (열기만 하면 아무 명령도 보내지 않아요).
  ? / P              도움말 / 현재 상태·엔코더 읽기
  M a b ms           원본 모터 PWM 명령 (예: M 0.5 0.5 300)
  Z                  현재 자리를 좌표 기준으로 지정
  G x y [f]          원본 절대 좌표 이동
  T / GT x y         Bot 누름 / 이동 뒤 누름
  S                  원본 중단 명령
  :help / :quit      도구 도움말 / 종료
OK는 접수 응답이에요. 뒤이어 오는 DONE·FAULT·PRESSED 등도 확인하세요.
Ctrl+C는 S를 한 번 보내고 도구를 종료해요."""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--command", action="append", default=[])
    parser.add_argument("--wait", type=float, default=2, help="one-shot command output wait (seconds)")
    parser.add_argument("--startup-wait", type=float, default=2, help="USB reset boot wait before one-shot commands")
    args = parser.parse_args(argv)
    if args.baud <= 0 or not (0 < args.wait <= 300) or not (0 <= args.startup_wait <= 30):
        parser.error("baud는 양수, wait는 0초 초과 300초 이하여야 해요")
    for command in args.command:
        command_line(command)
    import serial  # device-only optional dependency

    log = None
    console = None
    port = None
    try:
        if args.log:
            args.log.parent.mkdir(parents=True, exist_ok=True)
            log = args.log.open("a", encoding="utf-8")
        # Set DTR/RTS before opening; opening some USB bridges can still reset
        # the MCU. Boot output is kept by the reader, never treated as a reply.
        port = serial.Serial(port=None, baudrate=args.baud, timeout=0.1, write_timeout=1)
        port.dtr = False
        port.rts = False
        if sys.platform.startswith("linux"):
            port.exclusive = True
        port.port = args.port
        port.open()
        console = Console(port, out=sys.stdout, log=log)
        console.start()
        if args.command:
            if console.failed.wait(args.startup_wait):
                return 1
            for command in args.command:
                console.send(command)
            console.failed.wait(args.wait)
        else:
            print(HELP, flush=True)
            while not console.failed.is_set():
                try:
                    value = input("tb> ").strip()
                except EOFError:
                    break
                if value == ":quit":
                    break
                if value == ":help":
                    print(HELP, flush=True)
                elif value:
                    try:
                        console.send(value)
                    except ValueError as exc:
                        print(str(exc), file=sys.stderr, flush=True)
        return int(console.failed.is_set())
    except KeyboardInterrupt:
        if console is not None:
            console.send("S")
            console.failed.wait(0.3)
        return 130
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"연결 오류: {exc}", file=sys.stderr)
        return 1
    finally:
        if console is not None:
            console.close()
        elif port is not None:
            port.close()
        if log is not None:
            log.close()


if __name__ == "__main__":
    raise SystemExit(main())
