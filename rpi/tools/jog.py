"""홈·조그 CLI — 하드웨어 도착 첫날용. **실물 미검증.**

`SerialMotionClient`(rpi/controller/serial_motion.py)를 사람이 한 줄씩 부리는 도구다.
어댑터의 거절(홈 전 이동, 소프트 리밋 밖, 기구·기한 값 미설정)을 **그대로** 따른다 —
이 도구가 따로 우회하지 않는다. 거절 메시지는 가공 없이 출력해 하드웨어 담당이
어떤 환경 변수를 채워야 하는지 바로 보이게 한다.

사용:
    python -m rpi.tools.jog --fake-mcu --rehearsal-config          # 하드웨어 없이 리허설
    python -m rpi.tools.jog --port /dev/ttyUSB0 --baud 115200 --log data/bench/jog.log
    python -m rpi.tools.jog -c status -c home -c "jog 5 0"          # 한 번에 실행하고 끝
포트·보드레이트는 ``--port``/``--baud``가 없으면 ``SIMPLELAY_MOTION_PORT``/``SIMPLELAY_MOTION_BAUD``.
기구·누름·기한 값은 act_main과 같은 ``SIMPLELAY_MOTION_*`` 환경 변수에서 읽는다.

명령(REPL·``-c`` 공통):
    status                      MCU 상태 조회(움직이지 않음)
    limits                      X·Y·Z 리밋 입력 판독(즉시값·디바운스, 움직이지 않음) — 첫날 배선 확인
    home                        원점 복귀 — **시작 시 자동으로 하지 않는다**
    jog DX DY                   현재 위치(MCU 보고 카운트 → mm)에서 상대 이동(mm)
    goto X Y                    절대 좌표(mm)로 이동
    press [--depth N | --duration MS] [--dwell MS]
                                현재 위치에서 누름. 깊이(Z 카운트)·구동 시간 덮어쓰기는
                                이번 한 번만, 설정의 상한 검사는 그대로 적용
    stop                        정지 명령 전송(물리 E-STOP이 최종 권한)
    reset                       정지 표시 해제(정지로 끊겼다면 다시 home 필요)
    raw JSON                    한 줄을 그대로 보내고 응답을 출력(move/press/home은 거절)
    help, quit
명령 실행 중 Ctrl+C → 정지 명령을 보낸다.

``--log``를 주면 보낸 줄(``>>``)·받은 줄(``<<``)·입력한 명령(``##``)을 시각과 함께 남긴다.
원시 기록은 저장소에 올리지 않는다(``data/``는 .gitignore 대상).
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import json
import os
import shlex
import sys
import threading
import time
from collections.abc import Iterator, Sequence
from datetime import datetime
from pathlib import Path
from typing import TextIO

from rpi.controller.kinematics import (
    KinematicsNotConfigured,
    SoftLimitExceeded,
    motor_counts_to_xy,
)
from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import (
    LIMIT_INPUTS,
    LineTransport,
    MotionConfig,
    MotionError,
    SerialMotionClient,
    heartbeat_off_warning,
)

PROMPT = "jog> "
RAW_MOTION_CMDS = frozenset({"move", "press", "home"})
_RAW_ID_BASE = 900_000  # 어댑터 요청 id와 겹치지 않게 떨어뜨린다

HELP = """명령:
  status | home | jog DX DY | goto X Y | limits
  press [--depth N | --duration MS] [--dwell MS]
  stop | reset | raw JSON | help | quit"""


# ── 줄 기록 ──────────────────────────────────────────────────────────────────


class LineLog:
    """보낸/받은 줄을 시각과 함께 남긴다. 파일이 없으면 아무것도 하지 않는다."""

    def __init__(self, stream: TextIO | None, *, monotonic: bool = False) -> None:
        """``monotonic=True``(RPi4 act_main의 SIMPLELAY_MOTION_LOG_PATH): 두 번째 칸을
        시작 기준 상대 초 대신 ``mono_ns=<time.monotonic_ns()>``로 쓴다. 원시 기록기
        (``t_monotonic_ns``)·progress 프레임(``t_monotonic_ns``)과 같은 시각축이라 바로
        맞춰 볼 수 있다. 칸 수(시각 · 시각 · 태그 · 본문)는 같다."""
        self._stream = stream
        self._t0 = time.perf_counter()
        self._lock = threading.Lock()
        self._monotonic = monotonic

    def write(self, tag: str, text: str) -> None:
        if self._stream is None:
            return
        wall = datetime.now().isoformat(timespec="microseconds")
        if self._monotonic:
            second = f"mono_ns={time.monotonic_ns()}"
        else:
            second = f"+{time.perf_counter() - self._t0:.6f}s"
        with self._lock:
            self._stream.write(f"{wall} {second} {tag} {text}\n")
            self._stream.flush()


class LoggingTransport:
    """`LineTransport`를 감싸 모든 줄을 `LineLog`에 남긴다."""

    def __init__(self, inner: LineTransport, line_log: LineLog) -> None:
        self._inner = inner
        self._log = line_log

    def write_line(self, line: str) -> None:
        self._log.write(">>", line)
        self._inner.write_line(line)

    def read_line(self, timeout_s: float) -> str | None:
        line = self._inner.read_line(timeout_s)
        if line is not None:
            self._log.write("<<", line)
        return line

    def close(self) -> None:
        close = getattr(self._inner, "close", None)
        if callable(close):
            close()


# ── 클라이언트 ────────────────────────────────────────────────────────────────


class JogMotionClient(SerialMotionClient):
    """누름 깊이·시간을 한 번만 덮어쓸 수 있게 한 어댑터. 나머지 검사는 부모 그대로."""

    @contextlib.contextmanager
    def press_override(self, **fields: object) -> Iterator[None]:
        if not fields:
            yield
            return
        original = self._config
        # dataclasses.replace는 __post_init__ 검사를 다시 돈다 — 잘못된 값은 여기서 거절된다.
        self._config = dataclasses.replace(original, **fields)
        try:
            yield
        finally:
            self._config = original


# ── 세션 ─────────────────────────────────────────────────────────────────────


class JogSession:
    def __init__(
        self,
        client: JogMotionClient,
        transport: LineTransport,
        out: TextIO,
        line_log: LineLog,
        raw_timeout_s: float = 2.0,
    ) -> None:
        self.client = client
        self._transport = transport
        self._out = out
        self._log = line_log
        self._raw_timeout_s = raw_timeout_s
        self._raw_id = _RAW_ID_BASE

    def say(self, text: str) -> None:
        print(text, file=self._out, flush=True)

    def refuse(self, exc: BaseException) -> None:
        # 메시지를 가공하지 않는다 — 어떤 환경 변수를 채워야 하는지가 그대로 보여야 한다.
        # 준비 안 됨(MotionNotReady, 2026-10-14)도 운영자에게는 종전처럼 '거절 MotionRefused'로 보인다.
        from rpi.controller.serial_motion import MotionRefused  # noqa: PLC0415

        name = "MotionRefused" if isinstance(exc, MotionRefused) else type(exc).__name__
        text = f"거절 {name}: {exc}"
        self.say(text)
        self._log.write("!!", text)

    def run_line(self, line: str) -> bool | None:
        """한 줄 실행. 성공 True, 거절·오류 False, 종료 요청 None."""
        line = line.strip()
        if not line or line.startswith("#"):
            return True
        self._log.write("##", line)
        name, _, rest = line.partition(" ")
        name = name.lower()
        if name in ("quit", "exit", "q"):
            return None
        if name in ("help", "?"):
            self.say(HELP)
            return True
        handler = getattr(self, f"_cmd_{name}", None)
        if handler is None:
            self.say(f"알 수 없는 명령: {name} — help")
            return False
        try:
            handler(rest.strip())
        except KeyboardInterrupt:
            self.client.request_stop()
            self.say("중단 — 정지 명령을 보냈습니다. 위치를 믿을 수 없으니 reset 후 home 하세요")
            self._log.write("!!", "keyboard interrupt -> stop sent")
            return False
        except (MotionError, KinematicsNotConfigured, SoftLimitExceeded, ValueError, RuntimeError) as exc:
            self.refuse(exc)
            return False
        return True

    # 명령 -------------------------------------------------------------------

    def _cmd_status(self, rest: str) -> None:
        _no_args("status", rest)
        status = self.client.status()
        pos = ""
        if status.a_counts is not None and status.b_counts is not None:
            try:
                x, y = motor_counts_to_xy(status.a_counts, status.b_counts, self.client.config.kinematics)
                pos = f" x={x:.3f}mm y={y:.3f}mm"
            except KinematicsNotConfigured as exc:
                pos = f" (mm 환산 불가: {exc})"
        self.say(
            f"MCU state={status.state} homed={status.homed} a={status.a_counts} b={status.b_counts} "
            f"z={status.z_counts} alarm={status.alarm} | 어댑터 상태={self.client.state.value}{pos}"
        )

    def _cmd_limits(self, rest: str) -> None:
        _no_args("limits", rest)
        limits = self.client.limits()

        def mark(value: bool | None) -> str:
            return "?" if value is None else ("ON" if value else "off")

        cells = " ".join(
            f"{name}=raw:{mark(limits.raw[name])}/deb:{mark(limits.debounced[name])}"
            for name in LIMIT_INPUTS
        )
        self.say(f"리밋(ON=활성: 눌림·단선) {cells} — 손으로 하나씩 눌러 해당 축만 바뀌는지 보세요")

    def _cmd_home(self, rest: str) -> None:
        _no_args("home", rest)
        self.client.home()
        self.say(f"홈 완료 — 어댑터 상태={self.client.state.value}")

    def _cmd_goto(self, rest: str) -> None:
        x, y = _two_floats("goto", rest)
        self.client.move_to(x, y)
        self.say(f"이동 완료 x={x:g} y={y:g}")

    def _cmd_jog(self, rest: str) -> None:
        dx, dy = _two_floats("jog", rest)
        x0, y0 = self._current_xy("조그")
        x, y = x0 + dx, y0 + dy
        self.client.move_to(x, y)
        self.say(f"조그 완료 ({x0:.3f},{y0:.3f}) → ({x:.3f},{y:.3f})")

    def _cmd_press(self, rest: str) -> None:
        parser = _ArgParser(prog="press", add_help=False)
        group = parser.add_mutually_exclusive_group()
        group.add_argument("--depth", type=int, help="Z 카운트(이번 한 번)")
        group.add_argument("--duration", type=int, help="Z 구동 ms(이번 한 번)")
        parser.add_argument("--dwell", type=int, help="누른 채 유지 ms")
        args = parser.parse_args(shlex.split(rest))
        override: dict[str, object] = {}
        if args.depth is not None:
            override.update(press_mode="depth", press_depth_counts=args.depth)
        if args.duration is not None:
            override.update(press_mode="duration", press_drive_ms=args.duration)
        x, y = self._current_xy("누름")
        command = PressCommand(button="jog", x_mm=x, y_mm=y, press_ms=args.dwell)
        with self.client.press_override(**override):
            self.client.press(command)
        self.say(f"누름 완료 at ({x:.3f},{y:.3f})")

    def _cmd_stop(self, rest: str) -> None:
        _no_args("stop", rest)
        self.client.request_stop()
        self.client.reset_stop()
        self.say(
            f"정지 명령 전송 — 어댑터 상태={self.client.state.value}. "
            "물리 정지는 눈·E-STOP으로 확인하세요"
        )

    def _cmd_reset(self, rest: str) -> None:
        _no_args("reset", rest)
        self.client.reset_stop()
        self.say(f"정지 표시 해제 — 어댑터 상태={self.client.state.value}")

    def _cmd_raw(self, rest: str) -> None:
        if not rest:
            raise ValueError("raw에는 JSON 한 줄이 필요합니다")
        doc = json.loads(rest)
        if not isinstance(doc, dict) or not isinstance(doc.get("cmd"), str):
            raise ValueError('raw는 {"cmd": ...} 객체여야 합니다')
        if doc["cmd"] in RAW_MOTION_CMDS:
            raise ValueError(
                f"raw로 '{doc['cmd']}'는 보내지 않습니다 — 홈·소프트 리밋 확인을 건너뛰기 때문. "
                "home/goto/jog/press 명령을 쓰세요"
            )
        if "id" not in doc:
            self._raw_id += 1
            doc = {"id": self._raw_id, **doc}
        self._transport.write_line(json.dumps(doc, ensure_ascii=False))
        deadline = time.monotonic() + self._raw_timeout_s
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.say(f"응답 없음({self._raw_timeout_s:g}s)")
                return
            line = self._transport.read_line(min(0.05, remaining))
            if line is None:
                continue
            self.say(f"<< {line}")
            try:
                reply = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(reply, dict) and reply.get("id") == doc["id"]:
                return

    # 내부 -------------------------------------------------------------------

    def _current_xy(self, operation: str) -> tuple[float, float]:
        """MCU가 보고한 A·B 카운트를 mm로 바꾼다. 호스트가 위치를 짐작하지 않는다."""
        if not self.client.homed:
            # 조회 전에 어댑터와 같은 문구로 거절한다(움직이는 명령은 어차피 어댑터가 다시 거절).
            self.client._require_homed(operation)  # noqa: SLF001
        status = self.client.status()
        if status.a_counts is None or status.b_counts is None:
            raise ValueError(f"{operation}: MCU가 A·B 카운트를 보고하지 않아 현재 위치를 모릅니다")
        return motor_counts_to_xy(status.a_counts, status.b_counts, self.client.config.kinematics)


class _ArgParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise ValueError(f"{self.prog}: {message}")


def _no_args(name: str, rest: str) -> None:
    if rest:
        raise ValueError(f"{name}는 인자를 받지 않습니다: {rest!r}")


def _two_floats(name: str, rest: str) -> tuple[float, float]:
    parts = rest.split()
    if len(parts) != 2:
        raise ValueError(f"{name}에는 숫자 두 개가 필요합니다 (예: {name} 5 0)")
    try:
        return float(parts[0]), float(parts[1])
    except ValueError as exc:
        raise ValueError(f"{name}: 숫자가 아닙니다 {rest!r}") from exc


# ── 진입점 ───────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m rpi.tools.jog",
        description="모션 MCU 홈·조그 CLI (실물 미검증 어댑터). 시작 시 자동 홈 없음.",
    )
    parser.add_argument("--port", help="시리얼 장치 (기본: SIMPLELAY_MOTION_PORT)")
    parser.add_argument("--baud", type=int, help="보드레이트 (기본: SIMPLELAY_MOTION_BAUD)")
    parser.add_argument("--fake-mcu", action="store_true", help="메모리 가짜 MCU에 붙는다(하드웨어 없이 리허설)")
    parser.add_argument(
        "--rehearsal-config",
        action="store_true",
        help="--fake-mcu 전용: 리허설용 임의 기구·기한 값을 쓴다(실물 값 아님)",
    )
    parser.add_argument("--log", help="보낸/받은 줄을 시각과 함께 남길 파일(이어 쓰기)")
    parser.add_argument("--raw-timeout", type=float, default=2.0, help="raw 응답 대기(초)")
    parser.add_argument(
        "-c", "--cmd", action="append", default=[], help="명령을 순서대로 실행하고 끝낸다(여러 번 가능)"
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    env: dict[str, str] | None = None,
) -> int:
    out = stdout or sys.stdout
    source_env = dict(os.environ) if env is None else env
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.rehearsal_config and not args.fake_mcu:
        parser.error("--rehearsal-config는 --fake-mcu와 함께만 쓴다(임의 값을 실기기에 쓰지 않는다)")
    if args.fake_mcu and (args.port or args.baud):
        parser.error("--fake-mcu와 --port/--baud는 함께 쓰지 않는다")

    def say(text: str) -> None:
        print(text, file=out, flush=True)

    if args.rehearsal_config:
        from rpi.tools.fake_mcu import REHEARSAL_CONFIG  # noqa: PLC0415

        config = REHEARSAL_CONFIG
    else:
        try:
            config = MotionConfig.from_env(source_env)
        except ValueError as exc:
            say(f"설정 오류: {exc}")
            return 2
    if config.auto_home:
        say("SIMPLELAY_MOTION_AUTO_HOME은 이 도구에서 무시합니다 — 홈은 home 명령으로만")
        config = dataclasses.replace(config, auto_home=False)
    heartbeat_warning = heartbeat_off_warning(config)
    if heartbeat_warning:
        say(f"경고: {heartbeat_warning}")

    fake = None
    log_handle: TextIO | None = None
    try:
        if args.log:
            log_path = Path(args.log)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_handle = log_path.open("a", encoding="utf-8")
        line_log = LineLog(log_handle)

        if args.fake_mcu:
            from rpi.controller.serial_motion import InMemoryLinePipe  # noqa: PLC0415
            from rpi.tools.fake_mcu import FakeMcu  # noqa: PLC0415

            pipe = InMemoryLinePipe()
            fake = FakeMcu(pipe)
            inner: LineTransport = pipe.host
            where = "가짜 MCU(메모리, 실물 아님)"
        else:
            port = args.port or source_env.get("SIMPLELAY_MOTION_PORT", "").strip()
            baud = args.baud or source_env.get("SIMPLELAY_MOTION_BAUD", "").strip()
            if not port or not baud:
                say("포트·보드레이트가 없습니다: --port/--baud 또는 SIMPLELAY_MOTION_PORT/SIMPLELAY_MOTION_BAUD (기본값 없음)")
                return 2
            from rpi.controller.serial_motion import PySerialLineTransport  # noqa: PLC0415

            try:
                inner = PySerialLineTransport(port, int(baud))
            except Exception as exc:  # noqa: BLE001 - 포트 열기 실패는 사람에게 그대로 보인다
                say(f"포트를 열 수 없습니다 {port} @ {baud}: {exc}")
                return 2
            where = f"{port} @ {baud} (실물 미검증 어댑터)"

        transport = LoggingTransport(inner, line_log)
        client = JogMotionClient(transport, config)
        session = JogSession(client, transport, out, line_log, raw_timeout_s=args.raw_timeout)
        line_log.write("##", f"session start: {where}")
        say(f"연결: {where}. 시작 시 자동 홈 없음 — 먼저 status, 그다음 home")
        if args.rehearsal_config:
            say("리허설용 임의 기구·기한 값 사용 중 — 실물 값 아님")
        missing = config.missing_for_press()
        if missing:
            say(f"누름에 필요한데 비어 있는 설정: {', '.join(missing)}")

        if args.cmd:
            for line in args.cmd:
                say(f"{PROMPT}{line}")
                result = session.run_line(line)
                if result is None:
                    break
                if result is False:
                    return 1
            return 0

        source = stdin or sys.stdin
        interactive = stdin is None and sys.stdin.isatty()
        failures = 0
        while True:
            if interactive:
                out.write(PROMPT)
                out.flush()
            try:
                line = source.readline()
            except KeyboardInterrupt:
                say("")
                break
            if not line:
                break
            if not interactive:
                say(f"{PROMPT}{line.rstrip()}")
            result = session.run_line(line)
            if result is None:
                break
            if result is False:
                failures += 1
        return 0 if failures == 0 else 1
    finally:
        if fake is not None:
            fake.close()
        if log_handle is not None:
            log_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
