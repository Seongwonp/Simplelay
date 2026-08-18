"""액추에이터 준비 상태 — CoreXY + Z축 홈 스위치 GPIO 기반 placeholder.

하드웨어 미연결 또는 SIMPLELAY_GPIO_ENABLED=false 시 True(ready) 반환.
실기기에서는 gpiozero + lgpio 백엔드로 홈 스위치 상태를 읽는다.

배선 가정 (NC 엔드스톱 + 내부 풀업):
  - 비홈 상태: 스위치 닫힘 → 핀 LOW → gpiozero Button.is_pressed=True
  - 홈 위치  : 스위치 열림 → 풀업 → 핀 HIGH → gpiozero Button.is_pressed=False
  → is_ready() = (X not pressed) AND (Y not pressed)
  즉, 두 축 모두 HIGH(홈 스위치 열림)이면 ready.

gpiozero 백엔드 설정 (systemd 서비스에 추가):
  Environment=GPIOZERO_PIN_FACTORY=lgpio   # RPi5 필수
"""

from __future__ import annotations

import logging

_log = logging.getLogger(__name__)


class ActuatorStatus:
    """홈 스위치 두 축(+ 선택적 Z축)이 모두 홈 위치일 때 ready."""

    def __init__(
        self,
        home_x_pin: int = 17,
        home_y_pin: int = 27,
        home_z_pin: int | None = None,
        enabled: bool = False,
    ) -> None:
        self._enabled = enabled
        self._sw_x = None
        self._sw_y = None
        self._sw_z = None

        if not enabled:
            _log.info("actuator_ready mock 모드 (SIMPLELAY_GPIO_ENABLED=false)")
            return

        try:
            from gpiozero import Button  # noqa: PLC0415

            # NC 스위치: 홈 위치에서 스위치가 열려 핀이 HIGH → is_pressed=False
            self._sw_x = Button(home_x_pin, pull_up=True)
            self._sw_y = Button(home_y_pin, pull_up=True)
            if home_z_pin is not None:
                self._sw_z = Button(home_z_pin, pull_up=True)
            _log.info(
                "홈 스위치 초기화 (X=BCM%d, Y=BCM%d, Z=%s)",
                home_x_pin,
                home_y_pin,
                f"BCM{home_z_pin}" if home_z_pin else "없음",
            )
        except Exception as exc:
            _log.warning("홈 스위치 GPIO 초기화 실패 — True 반환: %s", exc)

    def is_ready(self) -> bool:
        """모든 홈 스위치가 열림(HIGH) 상태 = 홈 위치 = ready.
        GPIO 미설정 또는 오류 시 True(개발 환경 fallback).
        """
        if not self._enabled or self._sw_x is None:
            return True
        try:
            # NC 스위치: 홈 위치에서 is_pressed=False (핀 HIGH)
            x_home = not self._sw_x.is_pressed
            y_home = not self._sw_y.is_pressed
            if self._sw_z is not None:
                z_home = not self._sw_z.is_pressed
                return x_home and y_home and z_home
            return x_home and y_home
        except Exception as exc:
            _log.warning("홈 스위치 읽기 실패 — True 반환: %s", exc)
            return True

    def cleanup(self) -> None:
        for sw in (self._sw_x, self._sw_y, self._sw_z):
            if sw is not None:
                try:
                    sw.close()
                except Exception:
                    pass
