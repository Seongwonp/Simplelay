"""RPi5 ↔ RPi4 통신 프레임 탭 — 링 버퍼 + (선택) JSONL 세션 기록.

``ActClient``가 보내고 받는 **모든 줄**(execute·abort·inject_failure·result·error·
progress·alert …)을 방향·시각·sequence_id와 함께 남긴다. UART 모드(실기기)와
시뮬레이터 모드(메모리 파이프)가 같은 ``ActClient``를 쓰므로 두 모드가 이 한 곳에서
기록된다. 실모드 디지털 트윈(``GET /twin``)과 기록 재생(``/twin?replay=``)이 이것을 읽는다.

  SIMPLELAY_SESSION_LOG_PATH       설정하면 JSONL로 이어 쓴다(기본 꺼짐 — 링 버퍼만).
                                   경로에 ``{date}``가 있으면 날짜(YYYYMMDD)로 바꿔
                                   **하루 한 파일**로 나눈다.
  SIMPLELAY_SESSION_LOG_MAX_BYTES  파일 크기 상한(기본 20 MiB). 넘으면 ``.1`` ``.2`` …로 밀어낸다.
  SIMPLELAY_SESSION_LOG_BACKUPS    남길 이전 파일 수(기본 5).

한 줄 = 한 기록::

  {"kind":"frame","n":12,"t_wall":"2026-10-..T..","t_monotonic_ns":...,
   "direction":"hub_to_act"|"act_to_hub","type":"execute","sequence_id":"...",
   "message":{...}}

``direction``은 시뮬레이터 trace와 같은 이름을 쓴다(hub = RPi5, act = RPi4).
파일을 열 때마다 ``{"kind":"session_start", ...}`` 한 줄을 먼저 쓴다.

비밀값: 프로토콜 프레임에는 API 키가 없지만, 키 이름이 key·token·secret·password·
authorization·cookie를 포함하면 값을 ``[redacted]``로 바꾸고, 설정된 API 키·개발자
토큰과 같은 문자열 값도 가린다. 탭 실패(디스크 가득 등)는 로그만 남기고 통신을 막지 않는다.
"""
from __future__ import annotations

import json
import logging
import os
import pathlib
import re
import threading
import time
from collections import deque
from collections.abc import Callable
from datetime import datetime
from typing import Any

log = logging.getLogger(__name__)

PATH_ENV = "SIMPLELAY_SESSION_LOG_PATH"
MAX_BYTES_ENV = "SIMPLELAY_SESSION_LOG_MAX_BYTES"
BACKUPS_ENV = "SIMPLELAY_SESSION_LOG_BACKUPS"
REPLAY_DIR_ENV = "SIMPLELAY_TWIN_REPLAY_DIR"

DEFAULT_MAX_BYTES = 20 * 1024 * 1024
DEFAULT_BACKUPS = 5
DEFAULT_RING = 2000
RAW_LIMIT = 300

HUB_TO_ACT = "hub_to_act"
ACT_TO_HUB = "act_to_hub"

_SECRET_KEY = re.compile(r"(api[_-]?key|token|secret|passw|authorization|cookie)", re.IGNORECASE)
_SECRET_VALUE_ENVS = ("SIMPLELAY_API_KEY", "SIMPLELAY_DEV_TOKEN")
REDACTED = "[redacted]"


def _secret_values() -> set[str]:
    return {v for v in (os.environ.get(n, "").strip() for n in _SECRET_VALUE_ENVS) if len(v) >= 4}


def sanitize(value: Any, secrets: set[str] | None = None) -> Any:
    """비밀값으로 보이는 키·설정된 키 값을 가린 사본."""
    secrets = _secret_values() if secrets is None else secrets
    if isinstance(value, dict):
        return {k: (REDACTED if isinstance(k, str) and _SECRET_KEY.search(k) else sanitize(v, secrets))
                for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(v, secrets) for v in value]
    if isinstance(value, str) and secrets:
        for s in secrets:
            if s in value:
                value = value.replace(s, REDACTED)
    return value


class LinkFrameTap:
    """스레드 안전 링 버퍼 + 선택적 JSONL 파일 기록."""

    def __init__(
        self,
        path: str | os.PathLike | None = None,
        *,
        max_bytes: int = DEFAULT_MAX_BYTES,
        backups: int = DEFAULT_BACKUPS,
        ring_size: int = DEFAULT_RING,
        clock_ns: Callable[[], int] = time.monotonic_ns,
        wall: Callable[[], datetime] = datetime.now,
        transport: str | None = None,
    ) -> None:
        if max_bytes < 1024:
            raise ValueError("session log max_bytes must be at least 1024")
        if backups < 0:
            raise ValueError("session log backups must not be negative")
        self._template = str(path) if path else None
        self._max_bytes = max_bytes
        self._backups = backups
        self._ring: deque[dict] = deque(maxlen=ring_size)
        self._clock_ns = clock_ns
        self._wall = wall
        self._lock = threading.Lock()
        self._n = 0
        self._stream = None
        self._open_path: pathlib.Path | None = None
        self._last_execute: dict | None = None
        self.transport = transport
        self.write_errors = 0

    # 조회

    @property
    def enabled(self) -> bool:
        return self._template is not None

    @property
    def template(self) -> str | None:
        return self._template

    def current_path(self) -> pathlib.Path | None:
        if self._template is None:
            return None
        return pathlib.Path(self._template.replace("{date}", self._wall().strftime("%Y%m%d")))

    def frames(self) -> list[dict]:
        with self._lock:
            return list(self._ring)

    def last_execute(self) -> dict | None:
        """링에서 밀려나도 마지막 execute 프레임은 따로 쥔다(시뮬레이터 trace와 같은 이유)."""
        with self._lock:
            return self._last_execute

    # 기록

    def record(self, direction: str, message: dict | None, raw: str | None = None) -> dict | None:
        """프레임 하나를 남긴다. 어떤 예외도 호출자(통신 경로)로 올리지 않는다."""
        try:
            return self._record(direction, message, raw)
        except Exception:  # noqa: BLE001 - 기록 고장이 통신을 막지 않는다
            log.exception("link tap record failed")
            return None

    def _record(self, direction: str, message: dict | None, raw: str | None) -> dict:
        msg = sanitize(message) if isinstance(message, dict) else None
        entry: dict[str, Any] = {
            "kind": "frame",
            "t_wall": self._wall().isoformat(timespec="microseconds"),
            "t_monotonic_ns": self._clock_ns(),
            "direction": direction,
            "type": msg.get("type") if msg else None,
            "sequence_id": msg.get("sequence_id") if msg else None,
            "message": msg,
        }
        if msg is None and raw is not None:
            entry["raw"] = sanitize(raw[:RAW_LIMIT])
        with self._lock:
            self._n += 1
            entry["n"] = self._n
            self._ring.append(entry)
            if direction == HUB_TO_ACT and entry["type"] == "execute":
                self._last_execute = entry
            if self._template is not None:
                self._write_locked(entry)
        return entry

    def _write_locked(self, entry: dict) -> None:
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        data = line.encode("utf-8")
        try:
            path = self.current_path()
            assert path is not None
            if self._open_path != path:
                self._close_locked()
            if path.exists() and path.stat().st_size + len(data) > self._max_bytes:
                self._close_locked()
                self._rotate(path)
            if self._stream is None:
                path.parent.mkdir(parents=True, exist_ok=True)
                self._stream = open(path, "a", encoding="utf-8")
                self._open_path = path
                header = {
                    "kind": "session_start",
                    "t_wall": entry["t_wall"],
                    "t_monotonic_ns": entry["t_monotonic_ns"],
                    "pid": os.getpid(),
                    "transport": self.transport,
                }
                self._stream.write(json.dumps(header, ensure_ascii=False) + "\n")
            self._stream.write(line)
            self._stream.flush()
        except OSError:
            self.write_errors += 1
            if self.write_errors in (1, 10, 100):
                log.exception("session log write failed (%d times)", self.write_errors)
            self._close_locked()

    def _rotate(self, path: pathlib.Path) -> None:
        if self._backups == 0:
            path.unlink(missing_ok=True)
            return
        oldest = path.with_name(f"{path.name}.{self._backups}")
        oldest.unlink(missing_ok=True)
        for i in range(self._backups - 1, 0, -1):
            src = path.with_name(f"{path.name}.{i}")
            if src.exists():
                src.replace(path.with_name(f"{path.name}.{i + 1}"))
        path.replace(path.with_name(f"{path.name}.1"))

    def _close_locked(self) -> None:
        if self._stream is not None:
            try:
                self._stream.close()
            finally:
                self._stream = None
                self._open_path = None

    def close(self) -> None:
        with self._lock:
            self._close_locked()

    # 환경 변수

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None, **kwargs: Any) -> "LinkFrameTap":
        source = os.environ if env is None else env
        path = source.get(PATH_ENV, "").strip() or None

        def _int(name: str, fallback: int) -> int:
            raw = source.get(name, "").strip()
            if not raw:
                return fallback
            try:
                return int(raw)
            except ValueError as exc:
                raise ValueError(f"{name} must be an integer: {raw!r}") from exc

        return cls(path, max_bytes=_int(MAX_BYTES_ENV, DEFAULT_MAX_BYTES),
                   backups=_int(BACKUPS_ENV, DEFAULT_BACKUPS), **kwargs)


_default: LinkFrameTap | None = None
_default_lock = threading.Lock()


def get_link_tap() -> LinkFrameTap:
    """프로세스 공용 탭. 처음 부를 때 환경 변수로 만들고 켜짐/꺼짐을 로그에 남긴다."""
    global _default
    with _default_lock:
        if _default is None:
            _default = LinkFrameTap.from_env()
            if _default.enabled:
                log.warning("session log ON -> %s (RPi5↔RPi4 frames, JSONL, max %d bytes × %d backups)",
                         _default.template, _default._max_bytes, _default._backups)
            else:
                log.warning("session log off (set %s to append RPi5↔RPi4 frames as JSONL; "
                         "ring buffer only)", PATH_ENV)
        return _default


def reset_link_tap_for_tests() -> None:
    global _default
    with _default_lock:
        if _default is not None:
            _default.close()
        _default = None


def replay_dir(env: dict[str, str] | None = None) -> pathlib.Path | None:
    """기록 재생 파일을 찾는 폴더. SIMPLELAY_TWIN_REPLAY_DIR, 없으면 세션 기록 폴더."""
    source = os.environ if env is None else env
    explicit = source.get(REPLAY_DIR_ENV, "").strip()
    if explicit:
        return pathlib.Path(explicit)
    path = source.get(PATH_ENV, "").strip()
    return pathlib.Path(path).parent if path else None
