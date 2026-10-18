"""키오스크 앱 부팅 자동 실행·감시 (RPi5 플랫폼 기기용).

루트 파일시스템이 읽기 전용이라 시스템 서비스를 추가할 수 없다. 대신 이 스크립트를
restart=always 컨테이너로 돌린다 — 도커가 부팅 때 컨테이너를 다시 올리고, 스크립트는
플랫폼 앱 관리자에게 키오스크 앱 상태를 묻고 꺼져 있으면 시작한다. 창 관리자의 가장자리
스와이프로 앱이 닫혀도 다시 켜진다(키오스크 모드).

플랫폼 버스 이름·경로·앱 ID는 저장소에 넣지 않는다(기기 env 파일에 둔다):
  SIMPLELAY_KIOSK_BUS_NAME    앱 관리자 D-Bus 서비스 이름
  SIMPLELAY_KIOSK_BUS_PATH    객체 경로
  SIMPLELAY_KIOSK_BUS_IFACE   인터페이스 이름
  SIMPLELAY_KIOSK_APP_ID      키오스크 앱 ID
  SIMPLELAY_KIOSK_CHECK_S     확인 간격(초, 기본 10)
  SIMPLELAY_KIOSK_START_DELAY_S  부팅 뒤 첫 시작 전 대기(초, 기본 15 — 홈 앱·창 관리자가 먼저 뜨도록)

실행: docker run ... -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket simplelay-backend \
      python /watchdog/kiosk_watchdog.py
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

log = logging.getLogger("kiosk_watchdog")


def _env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        log.error("%s 가 비어 있어요 — 기기 env 파일을 확인하세요", name)
        sys.exit(2)
    return value


async def _state(iface, app_id: str) -> str:
    status = await iface.call_get_status(app_id)
    raw = status.get("state")
    return getattr(raw, "value", raw) or "unknown"


async def main() -> None:
    from dbus_fast.aio import MessageBus  # noqa: PLC0415
    from dbus_fast.constants import BusType  # noqa: PLC0415

    bus_name = _env("SIMPLELAY_KIOSK_BUS_NAME")
    bus_path = _env("SIMPLELAY_KIOSK_BUS_PATH")
    iface_name = _env("SIMPLELAY_KIOSK_BUS_IFACE")
    app_id = _env("SIMPLELAY_KIOSK_APP_ID")
    interval = float(os.environ.get("SIMPLELAY_KIOSK_CHECK_S", "10") or 10)
    first_delay = float(os.environ.get("SIMPLELAY_KIOSK_START_DELAY_S", "15") or 15)

    await asyncio.sleep(first_delay)
    while True:
        try:
            bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
            introspection = await bus.introspect(bus_name, bus_path)
            obj = bus.get_proxy_object(bus_name, bus_path, introspection)
            iface = obj.get_interface(iface_name)
            log.info("앱 관리자 연결됨 — %s 감시 시작(%.0f초 간격)", app_id, interval)
            while True:
                state = await _state(iface, app_id)
                if state != "Running":
                    log.info("키오스크 상태 %s → 시작", state)
                    await iface.call_start(app_id)
                await asyncio.sleep(interval)
        except Exception as exc:  # noqa: BLE001 -- 앱 관리자가 아직 안 떴거나 재시작 중
            log.warning("앱 관리자 호출 실패(%s) — %.0f초 뒤 다시", exc, interval)
            await asyncio.sleep(interval)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    asyncio.run(main())
