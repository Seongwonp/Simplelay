"""하드웨어 핀 구성 — 환경변수로 주입, 기본값은 개발(mock) 모드.

실기기(RPi5)에서는 systemd 서비스 파일에 Environment=... 를 추가하면 된다.
핀 번호 바꿀 때도 서비스 파일만 수정하면 코드 변경 없이 반영된다.
"""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class HardwareConfig:
    # ── DHT22 온습도 센서 ─────────────────────────────────────────────────
    # 데이터 핀 BCM 번호 (기본: GPIO 4)
    dht22_gpio: int = 4

    # ── CoreXY 홈 스위치 ─────────────────────────────────────────────────
    # NC(Normally Closed) 엔드스톱 가정:
    #   비홈 상태 → 스위치 닫힘 → 핀 LOW
    #   홈 위치   → 스위치 열림 → 내부 풀업이 핀을 HIGH로 유지
    # 배선 확정 후 환경변수로 교체
    home_switch_x_gpio: int = 17
    home_switch_y_gpio: int = 27
    # Z축 홈 스위치 — None이면 Z축 미확인(Z 없이도 ready 가능)
    home_switch_z_gpio: int | None = None

    # ── 실 GPIO 사용 여부 ─────────────────────────────────────────────────
    # False(기본) → GPIO 코드 실행 안 하고 mock 값 반환 (개발 PC, 센서 미연결)
    # True → adafruit_dht / gpiozero 실제 호출 (RPi5 실기기)
    gpio_enabled: bool = False

    # ── 온습도 센서만 따로 켜기(2026-10-20) ──────────────────────────────
    # SIMPLELAY_DHT22_ENABLED가 없으면 gpio_enabled를 따른다. 센서만 켜면 원점 스위치
    # GPIO(기본 17·27)는 건드리지 않는다 — 센서를 GPIO17에 꽂은 구성에서 서로 잡지 않게.
    dht22_enabled: bool = False
    # RPi5 40핀 헤더의 gpiochip 번호(커널 6.6.45+ 에서는 0, 그 전에는 4).
    gpio_chip: int = 0


def _load() -> HardwareConfig:
    def _int(key: str, default: int) -> int:
        raw = os.environ.get(key, "").strip()
        return int(raw) if raw.isdigit() else default

    def _int_or_none(key: str) -> int | None:
        raw = os.environ.get(key, "").strip()
        return int(raw) if raw.isdigit() else None

    gpio_enabled = os.environ.get("SIMPLELAY_GPIO_ENABLED", "false").strip().lower() == "true"
    dht_raw = os.environ.get("SIMPLELAY_DHT22_ENABLED", "").strip().lower()
    return HardwareConfig(
        dht22_gpio=_int("SIMPLELAY_DHT22_GPIO", 4),
        home_switch_x_gpio=_int("SIMPLELAY_HOME_X_GPIO", 17),
        home_switch_y_gpio=_int("SIMPLELAY_HOME_Y_GPIO", 27),
        home_switch_z_gpio=_int_or_none("SIMPLELAY_HOME_Z_GPIO"),
        gpio_enabled=gpio_enabled,
        dht22_enabled=(dht_raw == "true") if dht_raw else gpio_enabled,
        gpio_chip=_int("SIMPLELAY_GPIO_CHIP", 0),
    )


hardware_config = _load()
