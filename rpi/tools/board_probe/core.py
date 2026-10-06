"""Generic probes. Targets and raw replies belong outside the checkout."""
from __future__ import annotations

import asyncio
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timezone
from urllib.request import Request, urlopen

from . import VERSION

ROOT = Path(__file__).resolve().parents[3]
LABELS = {"dbus_service": "기능 서비스", "dbus_method": "서비스 최소 호출",
          "device_node": "주변기기 장치", "python_module": "파이썬 모듈",
          "executable": "실행 도구", "http": "웹 서비스", "serial_port": "주변기기 UART"}


def outside(path):
    path = Path(path).expanduser().resolve()
    if path == ROOT or ROOT in path.parents:
        raise ValueError("설정과 결과는 저장소 밖 경로만 허용합니다")
    return path


def load_config(path):
    path = outside(path)
    with path.open("rb") as stream:
        cfg = tomllib.load(stream) if path.suffix == ".toml" else json.load(stream)
    ids = set()
    for c in cfg["checks"]:
        if c["kind"] not in LABELS or c["id"] in ids:
            raise ValueError("잘못된 종류 또는 중복 점검 ID")
        ids.add(c["id"])
        if c.get("safe_read_only") is not True:
            raise ValueError("각 최소 호출의 읽기 전용 검토가 필요합니다")
    return cfg


def account():
    if not hasattr(os, "geteuid"):
        return {"name": None, "uid": "unsupported", "root_only": False,
                "effective_uid": "unsupported", "effective_name": None,
                "real_uid": "unsupported", "real_name": None}
    import pwd
    def name(uid):
        try:
            return pwd.getpwuid(uid).pw_name
        except KeyError:
            return None
    effective, real = os.geteuid(), os.getuid()
    effective_name = name(effective)
    return {"name": effective_name, "uid": effective, "root_only": effective == 0,
            "effective_uid": effective, "effective_name": effective_name,
            "real_uid": real, "real_name": name(real)}


def metadata():
    def read(path):
        try:
            return Path(path).read_text().strip("\x00\n")
        except OSError:
            return None
    now = datetime.now(timezone.utc)
    return {"tool_version": VERSION, "timestamp_utc": now.isoformat(),
            "timestamp_local": now.astimezone().isoformat(), "account": account(),
            "board_model": read("/proc/device-tree/model") or platform.machine(),
            "os_image": read("/etc/os-release") or platform.platform(),
            "kernel": platform.release()}


def http_get(url, timeout=5):
    # No arbitrary request bodies or mutating HTTP verbs. Local config is trusted.
    with urlopen(Request(url, headers={"X-API-Key": os.getenv("SIMPLELAY_API_KEY", "")}), timeout=timeout) as r:
        return r.read(65536).decode("utf-8")


async def dbus_probe(c, r):
    from dbus_fast import BusType, Message, MessageFlag, MessageType
    from dbus_fast.aio import MessageBus
    bus = await MessageBus(bus_type=BusType.SESSION if c.get("bus") == "session" else BusType.SYSTEM).connect()
    async def call(destination, path, interface, member, signature="", body=None, raw=False):
        reply = await bus.call(Message(destination=destination, path=path, interface=interface,
                                       member=member, signature=signature, body=body or [],
                                       flags=MessageFlag.NO_AUTOSTART))
        if reply.message_type == MessageType.ERROR:
            raise RuntimeError(f"{reply.error_name}: {reply.body}")
        if raw:
            r["reply_signature"] = getattr(reply, "signature", None)
        return reply.body
    try:
        r["present"] = bool((await call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus", "NameHasOwner", "s", [c["target"]]))[0])
        if not r["present"]:
            return
        # Keep introspection failure separate from the minimal call result.
        try:
            r["signatures"] = await call(c["target"], c["path"], "org.freedesktop.DBus.Introspectable", "Introspect")
            r["introspect_ok"] = True
        except Exception as exc:
            r["introspect_ok"] = False
            r["error"].append(str(exc))
        if c.get("call"):
            q = c["call"]
            r["call_attempted"] = True
            t = time.perf_counter()
            try:
                r["reply"] = await call(c["target"], c["path"], q["interface"], q["member"], q.get("signature", ""), q.get("args", []), raw=True)
                r["min_call_ok"] = True
            finally:
                r["latency_ms"] = round((time.perf_counter() - t) * 1000, 3)
    finally:
        bus.disconnect()


def run_check(c, app_account, identity=None, dbus_runner=None, timeout_s=15):
    who = identity or account()
    r = {"id": c["id"], "kind": c["kind"], "target": c["target"],
         "present": None, "introspect_ok": None, "app_permission": None,
         "min_call_ok": None, "latency_ms": None, "error": [],
         "call_attempted": False, "run_account": who, "root_only": who["root_only"]}
    t = time.perf_counter()
    deadline = time.monotonic() + timeout_s
    def remaining(limit=5):
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise TimeoutError("minimal call timed out")
        return min(limit, seconds)
    try:
        kind, target = c["kind"], c["target"]
        if kind.startswith("dbus_"):
            if dbus_runner:
                dbus_runner(c, r)
            else:
                asyncio.run(asyncio.wait_for(dbus_probe(c, r), timeout=remaining(15)))
        elif kind == "python_module":
            # find_spec for dotted names may import parent packages: isolate it.
            result = subprocess.run([sys.executable, "-c", "import importlib.util,sys;sys.exit(0 if importlib.util.find_spec(sys.argv[1]) else 1)", target], capture_output=True, timeout=remaining())
            r["present"] = result.returncode == 0
            r["error"].append(result.stderr.decode(errors="replace")) if result.stderr else None
            if r["present"] and c.get("call") == "import":
                r["call_attempted"] = True
                subprocess.run([sys.executable, "-c", "import importlib,sys;importlib.import_module(sys.argv[1])", target], capture_output=True, timeout=remaining(), check=True)
                r["min_call_ok"] = True
        elif kind == "executable":
            r["present"] = shutil.which(target) is not None
            if r["present"] and "args" in c:
                r["call_attempted"] = True
                result = subprocess.run([target, *c["args"]], capture_output=True, timeout=remaining(), check=True)
                r["reply"] = result.stdout.decode(errors="replace")
                r["min_call_ok"] = True
        elif kind == "http":
            r["call_attempted"] = True
            r["reply"] = http_get(target, timeout=remaining())
            r["present"] = r["min_call_ok"] = True
        else:
            r["present"] = Path(target).exists()
            # Serial opening can reset the MCU via DTR; discovery only in read-only mode.
            if kind == "device_node" and c.get("call") == "open_read" and r["present"]:
                r["call_attempted"] = True
                fd = os.open(target, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
                os.close(fd)
                r["min_call_ok"] = True
    except Exception as exc:
        r["error"].append(str(exc) or type(exc).__name__)
        if r["call_attempted"]:
            r["min_call_ok"] = False
    if r["call_attempted"]:
        if r["latency_ms"] is None:
            r["latency_ms"] = round((time.perf_counter() - t) * 1000, 3)
        r["app_permission"] = bool(r["min_call_ok"] and isinstance(who["uid"], int)
                                   and who["uid"] != 0 and not who["root_only"]
                                   and who["name"] and who["name"] == app_account)
    return r


def summary(report):
    # Allowlist projection: never interpolate IDs, labels, targets, errors or raw replies.
    stamp = datetime.fromisoformat(report["timestamp_utc"]).isoformat()
    lines = [f"# 이전 점검 기록({stamp})", "", "저장 기록은 현재 실행 준비 상태가 아닙니다.", "",
             "| 항목 | 존재 | introspection | 앱 권한 | 최소 호출 |", "|---|---|---|---|---|"]
    def cell(v):
        return "성공" if v is True else "실패" if v is False else "미측정"
    for c in report["checks"]:
        lines.append("| " + " | ".join([LABELS.get(c["kind"], "기타 점검"), *[cell(c.get(k)) for k in ("present", "introspect_ok", "app_permission", "min_call_ok")]]) + " |")
    return "\n".join(lines) + "\n"


def raw_json(value):
    """Preserve wire Variants and Python types without losing an entire record.

    dbus-fast represents paths/signatures as str and arrays/structs as list;
    reply_signature and Variant.signature retain their wire-level distinctions.
    """
    try:
        from dbus_fast import Variant
    except ImportError:
        Variant = ()
    ancestors = set()

    def fallback(item):
        try:
            representation = repr(item)
        except Exception:
            representation = "<repr unavailable>"
        return {"__dbus__": "repr", "type": f"{type(item).__module__}.{type(item).__qualname__}",
                "repr": representation}

    def convert(item):
        if item is None or type(item) in (bool, int, str):
            return item
        if type(item) is float and math.isfinite(item):
            return item
        if id(item) in ancestors:
            return fallback(item)
        ancestors.add(id(item))
        try:
            if isinstance(item, Variant):
                return {"__dbus__": "variant", "signature": str(item.signature),
                        "value": convert(item.value)}
            if type(item) in (bytes, bytearray, memoryview):
                return {"__dbus__": type(item).__name__, "value": list(bytes(item))}
            if type(item) is list:
                return [convert(v) for v in item]
            if type(item) is tuple:
                return {"__dbus__": "tuple", "value": [convert(v) for v in item]}
            if type(item) is dict:
                if all(type(k) is str for k in item):
                    return {k: convert(v) for k, v in item.items()}
                return {"__dbus__": "dict", "value": [[convert(k), convert(v)] for k, v in item.items()]}
            return fallback(item)
        except Exception:
            return fallback(item)
        finally:
            ancestors.remove(id(item))
    return convert(value)


def save(report, directory):
    directory = outside(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    stem = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    for name, content in ((stem + ".json", json.dumps(raw_json(report), ensure_ascii=False, indent=2)),
                          (stem + ".md", summary(report))):
        fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
    return directory / (stem + ".json")
