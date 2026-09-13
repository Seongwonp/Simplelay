"""액추에이터 준비 상태 — CoreXY + Z축 홈 스위치 GPIO 기반 placeholder.

SIMPLELAY_GPIO_ENABLED=false(개발 구성, 스위치를 읽지 않는 mock)면 True.
GPIO를 켠 구성에서는 gpiozero + lgpio 백엔드로 홈 스위치 상태를 읽고,
**읽을 수 없으면 준비 안 됨으로 닫는다(fail-closed).** 초기화 실패·읽기
오류·타임아웃·bool이 아닌 값이 모두 여기에 해당한다. 예전에는 이 경우에도
True를 돌려줘, 스위치를 못 읽었는데 홈에 있다고 말했다.

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
import threading

_log = logging.getLogger(__name__)

# 홈 스위치 한 번 읽기의 기한. GPIO 판독은 보통 즉시 끝나므로 이 안에 못 끝나면
# 백엔드·드라이버 이상으로 보고 준비 안 됨으로 닫는다.
HOME_SWITCH_READ_TIMEOUT_SECONDS = 0.2


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
        self._init_failed = False
        # 끝나지 않은 읽기가 있으면 새 읽기 스레드를 띄우지 않는다 — 판독이
        # 매달린 동안 폴링마다 스레드가 쌓이지 않게 한다.
        self._read_in_flight = threading.Event()

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
            _log.warning("홈 스위치 GPIO 초기화 실패 — 준비 안 됨으로 닫는다: %s", exc)
            self._init_failed = True
            self.cleanup()  # 일부 축만 열렸다면 그 핀을 돌려준다
            self._sw_x = self._sw_y = self._sw_z = None

    def is_ready(self) -> bool:
        """모든 홈 스위치가 열림(HIGH) 상태 = 홈 위치 = ready.

        - GPIO 끔(개발 구성): True — 스위치를 읽지 않는 mock.
        - GPIO 켬: 모든 축의 판독이 bool이고 전부 홈일 때만 True.
          초기화 실패·읽기 오류·타임아웃·bool이 아닌 값은 False(fail-closed).
        """
        if not self._enabled:
            return True
        if self._init_failed or self._sw_x is None or self._sw_y is None:
            return False
        switches = [sw for sw in (self._sw_x, self._sw_y, self._sw_z) if sw is not None]

        readings = self._read_with_deadline(switches)
        if readings is None:
            return False
        if any(not isinstance(value, bool) for value in readings):
            _log.warning("홈 스위치 값이 bool이 아니다 — 준비 안 됨: %r", readings)
            return False
        # NC 스위치: 홈 위치에서 is_pressed=False (핀 HIGH)
        return not any(readings)

    def _read_with_deadline(self, switches: list) -> list[object] | None:
        """모든 축을 기한 안에 읽는다. 오류·기한 초과·이전 읽기 미완료면 None."""
        if self._read_in_flight.is_set():
            _log.warning("홈 스위치 이전 읽기가 끝나지 않았다 — 준비 안 됨")
            return None

        outcome: dict[str, object] = {}
        done = threading.Event()

        def _read() -> None:
            try:
                outcome["readings"] = [sw.is_pressed for sw in switches]
            except Exception as exc:  # noqa: BLE001 -- 원인은 로그로, 판정은 닫힘
                outcome["error"] = exc
            finally:
                self._read_in_flight.clear()
                done.set()

        self._read_in_flight.set()
        # 데몬 스레드: 판독이 영영 돌아오지 않아도 프로세스 종료를 붙잡지 않는다
        threading.Thread(target=_read, name="home-switch-read", daemon=True).start()
        if not done.wait(timeout=HOME_SWITCH_READ_TIMEOUT_SECONDS):
            _log.warning(
                "홈 스위치 읽기 %.2fs 초과 — 준비 안 됨", HOME_SWITCH_READ_TIMEOUT_SECONDS
            )
            return None
        if "error" in outcome:
            _log.warning("홈 스위치 읽기 실패 — 준비 안 됨: %s", outcome["error"])
            return None
        return outcome["readings"]  # type: ignore[return-value]

    def cleanup(self) -> None:
        for sw in (self._sw_x, self._sw_y, self._sw_z):
            if sw is not None:
                try:
                    sw.close()
                except Exception:
                    pass
