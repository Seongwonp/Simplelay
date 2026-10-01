"""Explicit active measurements; no automatic home or privilege escalation."""
import json
import math
import subprocess
import time
from urllib.parse import urlsplit

from .core import http_get
from . import core


def recovery_check(cfg, action):
    matches = [c for c in cfg.get("checks", []) if c["id"] == action.get("check_id")]
    if len(matches) != 1 or matches[0].get("safe_read_only") is not True:
        raise ValueError("restart requires a unique safe_read_only check_id")
    check = matches[0]
    kind = check["kind"]
    has_call = (kind == "http" or kind == "executable" and "args" in check
                or kind.startswith("dbus_") and bool(check.get("call"))
                or kind == "python_module" and check.get("call") == "import"
                or kind == "device_node" and check.get("call") == "open_read")
    if not has_call:
        raise ValueError("restart target requires a configured minimal call")
    timeout = float(action.get("recovery_timeout_s", 30))
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("recovery_timeout_s must be finite and positive")
    return check, timeout


def wait_for_recovery(cfg, check, timeout):
    deadline = time.monotonic() + timeout
    last_error = "target minimal call not attempted"
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"recovery_failed: {last_error}")
        try:
            result = core.run_check(check, cfg["app_account"], timeout_s=min(15, remaining))
            if result["call_attempted"] and result["min_call_ok"] is True:
                if time.monotonic() <= deadline:
                    return
                last_error = "target minimal call exceeded recovery timeout"
            else:
                last_error = "; ".join(result["error"]) or "target minimal call did not succeed"
        except Exception as exc:
            last_error = str(exc) or type(exc).__name__
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))


def idle(url, get=http_get):
    if urlsplit(url).path != "/status":
        raise ValueError("/status 주소가 필요합니다")
    if json.loads(get(url)).get("running") is not False:
        raise RuntimeError("실행 중이거나 실행 상태를 확인할 수 없습니다")


def run_active(cfg, acknowledged, get=http_get):
    if not acknowledged:
        raise ValueError("--i-understand-active가 필요합니다")
    idle(cfg["status_url"], get)
    results = []
    for action in cfg.get("active", []):
        idle(cfg["status_url"], get)
        r = {"kind": action["kind"], "ok": False, "recovery_ms": None,
             "recovery_failed": False, "error": None}
        start = time.perf_counter()
        try:
            if action["kind"] == "restart":
                check, timeout = recovery_check(cfg, action)
                subprocess.run(["systemctl", "restart", "--", action["unit"]], check=True, capture_output=True, timeout=15)
                wait_for_recovery(cfg, check, timeout)
            elif action["kind"] == "jog":
                tiny_move(action)
            else:
                raise ValueError("지원하지 않는 active 작업")
            r["ok"] = True
            r["recovery_ms"] = round((time.perf_counter() - start) * 1000, 3)
        except Exception as exc:
            r["recovery_failed"] = action["kind"] == "restart"
            r["error"] = str(exc) or type(exc).__name__
        r["elapsed_ms"] = round((time.perf_counter() - start) * 1000, 3)
        results.append(r)
        if not r["ok"]:
            break
    return results


def tiny_move(action):
    from rpi.controller.serial_motion import MotionConfig, PySerialLineTransport, SerialMotionClient
    from rpi.controller.kinematics import motor_counts_to_xy
    dx, dy = float(action["dx_mm"]), float(action["dy_mm"])
    if not math.isfinite(dx + dy) or not 0 < math.hypot(dx, dy) <= 0.5:
        raise ValueError("조그는 0 초과 0.5 mm 이하만 허용합니다")
    config = MotionConfig.from_env()
    transport = PySerialLineTransport(action["port"], int(action["baud"]))
    client = SerialMotionClient(transport, config)
    try:
        state = client.connect()
        if state.state != "idle" or not state.homed or state.alarm:
            raise RuntimeError("이미 원점이 확인된 유휴 MCU만 점검할 수 있습니다")
        if state.a_counts is None or state.b_counts is None:
            raise RuntimeError("현재 위치 미확인")
        x, y = motor_counts_to_xy(state.a_counts, state.b_counts, config.kinematics)
        client.move_to(x + dx, y + dy)
        client.move_to(x, y)
        if client.status().state != "idle":
            raise RuntimeError("이동 후 유휴 복귀 미확인")
    finally:
        try:
            client.request_stop()
        finally:
            transport._serial.close()
