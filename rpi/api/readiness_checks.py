"""시연 전 준비 상태 — 빠른 읽기 전용 점검만 모은다."""

from __future__ import annotations

import json
import os
import socket
import ssl
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime


def internet_probe(timeout: float = 1.5) -> tuple[bool, str, datetime | None]:
    """공개 호스트 DNS·TCP와 HTTPS 날짜를 짧게 확인한다."""
    host = "one.one.one.one"
    try:
        # IPv6 주소가 먼저 오면 4칸 튜플이라 create_connection이 ValueError를 낸다(10/27 보드) — 이름으로 맡긴다.
        with socket.create_connection((host, 443), timeout=timeout) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as conn:
                conn.settimeout(timeout)
                conn.sendall(b"HEAD / HTTP/1.1\r\nHost: one.one.one.one\r\nConnection: close\r\n\r\n")
                header = conn.recv(2048).decode("ascii", "ignore")
        date_line = next((line[5:].strip() for line in header.splitlines() if line.lower().startswith("date:")), None)
        try:
            remote = parsedate_to_datetime(date_line).astimezone(timezone.utc) if date_line else None
        except (TypeError, ValueError):  # 날짜 줄이 이상해도 연결 자체는 됐다
            remote = None
        return True, "DNS와 외부 연결이 돼요", remote
    except Exception as exc:  # noqa: BLE001 -- 진단 한 칸의 실패일 뿐이다
        return False, f"외부 연결을 확인하지 못했어요 ({type(exc).__name__})", None


def thinq_check() -> tuple[bool, str]:
    from rpi.api.thinq_wiring import get_power_cache, get_thinq_config  # noqa: PLC0415

    mode = get_thinq_config().mode.value
    age = get_power_cache().last_read_age()
    if mode == "off":
        return False, "ThinQ가 꺼져 있어요"
    if age is None:
        return False, f"ThinQ {mode} · 성공한 상태 읽기가 아직 없어요"
    return age <= 600, f"ThinQ {mode} · 마지막 성공 읽기 {age:.0f}초 전"


def actuator_link_check(service) -> tuple[bool, str]:
    state = service.actuator_link_up()
    if state is True:
        return True, "누름 장치 링크가 연결됐어요"
    if state is False:
        return False, "누름 장치 링크가 끊겼어요"
    return True, "로컬 누름 장치를 사용해요"


def motion_homed_check(service, actuator) -> tuple[bool, str]:
    controller = getattr(service, "_controller", None)
    status = getattr(controller, "kit_status", None)
    report = status() if callable(status) else None
    cached = report.get("motion_homed") if isinstance(report, dict) else None
    if isinstance(cached, bool):
        return cached, "모션 보드가 원점에 있어요" if cached else "모션 보드 원점 복귀가 필요해요"
    # 로컬 GPIO 구성은 홈 스위치의 읽기 결과가 곧 허브가 아는 마지막 준비 상태다.
    if os.environ.get("SIMPLELAY_ACT_MODE", "local").strip().lower() != "uart":
        homed = bool(actuator.is_ready())
        return homed, "홈 스위치가 원점을 확인했어요" if homed else "홈 스위치가 원점을 확인하지 못했어요"
    return False, "모션 보드의 마지막 원점 상태를 아직 받지 못했어요"


def camera_check(now: float | None = None) -> tuple[bool, str]:
    import time  # noqa: PLC0415
    from rpi.api.room_presence_wiring import camera_enabled, room_presence_path  # noqa: PLC0415

    path = room_presence_path()
    if path is None:
        return False, "방 카메라 감지 파일이 설정되지 않았어요"
    if not camera_enabled():
        return False, "방 카메라가 꺼져 있어요"
    try:
        age = (time.time() if now is None else now) - os.stat(path).st_mtime
    except OSError:
        return False, "방 카메라 감지 파일을 읽지 못했어요"
    return 0 <= age <= 10, f"마지막 사람 감지 파일 {max(0, age):.0f}초 전"


def clock_check(remote: datetime | None) -> tuple[bool, str]:
    now = datetime.now().astimezone()
    if now.year < 2026:
        return False, f"시계 연도가 맞지 않아요 ({now.year})"
    if remote is None:
        return True, "시계 연도는 정상이에요 · 인터넷 시각은 확인하지 못했어요"
    drift = abs((now.astimezone(timezone.utc) - remote).total_seconds())
    return drift <= 300, f"인터넷 시각과 {drift:.0f}초 차이예요"


def daily_cap_check(service) -> tuple[bool, str]:
    used = service.asked_today()
    limit = getattr(service, "_daily_ask_limit", None)
    if limit is None:
        return True, f"오늘 {used}번 물었어요 · 상한 없음"
    remaining = max(0, limit - used)
    return remaining > 0, f"오늘 {used}/{limit}번 · {remaining}번 남았어요"


def auto_rule_check() -> tuple[bool, str]:
    from rpi.api.deps import get_db  # noqa: PLC0415
    from rpi.routines import wiring  # noqa: PLC0415

    engine = getattr(wiring, "_auto_engine", None)
    if engine is not None:
        count = sum(1 for item in engine.list_payloads() if item.get("enabled") is True)
    else:
        db = get_db()
        raw = db.load_setting(wiring.AUTO_RULES_SETTING) if db else None
        values = json.loads(raw) if raw else []
        count = sum(1 for item in values if isinstance(item, dict) and item.get("enabled") is True)
    return True, f"켜진 자동 실행 규칙 {count}개"


def quiet_check() -> tuple[bool, str]:
    from rpi.api.deps import quiet_status  # noqa: PLC0415

    status = quiet_status()
    active = status.get("active") is True
    reason = status.get("reason")
    return not active, "조용한 시간이 꺼져 있어요" if not active else f"조용한 시간이 켜져 있어요 ({reason or '설정'})"
