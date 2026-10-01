"""Explicit active measurements; no automatic home or privilege escalation."""
import json
import math
import subprocess
import time
from urllib.parse import urlsplit

from .core import http_get


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
        r = {"kind": action["kind"], "ok": False, "recovery_ms": None, "error": None}
        start = time.perf_counter()
        try:
            if action["kind"] == "restart":
                subprocess.run(["systemctl", "restart", "--", action["unit"]], check=True, capture_output=True, timeout=15)
                deadline = time.monotonic() + 30
                while True:
                    try:
                        idle(action["reconnect_status_url"], get)
                        break
                    except Exception:
                        if time.monotonic() >= deadline:
                            raise TimeoutError("재연결 시간 초과")
                        time.sleep(0.2)
            elif action["kind"] == "jog":
                tiny_move(action)
            else:
                raise ValueError("지원하지 않는 active 작업")
            r["ok"] = True
            r["recovery_ms"] = round((time.perf_counter() - start) * 1000, 3)
        except Exception as exc:
            r["error"] = str(exc)
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
