"""ThinQ 가전 전원 상태 기억 — 키오스크 가전 줄의 '켜짐' 표시용(2026-10-16, 사용자 요청).

**새로 클라우드를 부르지 않는다.** 이미 하는 상태 조회(공기질 판독 스레드·``GET /thinq/status``·실행기의 보내기 전/확인
조회)의 결과에서 전원 칸만 옮겨 적는다. 키오스크가 몇 초마다 물어도 ThinQ 호출 한도를 쓰지 않는다.

- 전원 칸은 대응표(``bindings``)의 ``set_power`` 동작이 쓰는 칸(예: ``operation.airPurifierOperationMode``)을 그대로 읽는다.
  필드 이름을 새로 짓지 않는다. ``set_power``가 없는 가전(세탁기)은 적지 않는다.
- ``POWER_ON`` → ``on``, ``POWER_OFF`` → ``off``. 그 밖의 값·값 없음·조회 실패는 **모름**이라 그 가전의 기억을 지운다
  (지어내지 않는다 — 모르면 표시하지 않는다).
- 명령을 보내기 직전에도 지운다 — 보낸 뒤에는 이전 조회 값이 맞는지 모른다(확인 조회가 다시 적는다).
- 오래된 기억(기본 600초)은 내보내지 않는다.

공기질(2026-10-16, 키오스크 평소 화면 '실내 공기' 한 줄)도 같은 조회에서 옮겨 적는다(:func:`rpi.services.air_quality.air_summary`
— 가전이 매긴 등급만). 센서 칸이 없거나 등급을 모르면 그 가전의 공기질 기억을 지운다. 전원과 같은 규칙으로 지우고 같은
나이 상한으로 내보낸다(``GET /thinq/air``).
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any

from rpi.services.air_quality import air_summary

from .profile import read_state

#: 이보다 오래된 조회 결과는 '켜짐'으로 내보내지 않는다(공기질 판독 주기 기본 120초의 다섯 배).
POWER_STALE_SECONDS = 600.0

_POWER_WORDS = {"POWER_ON": "on", "POWER_OFF": "off"}


def power_of(binding: Any, state: Any) -> str | None:
    """상태 조회 결과에서 전원(``on``·``off``). 대응표에 전원 동작이 없거나 값을 모르면 None."""
    if binding is None or state is None:
        return None
    cap = next((c for c in getattr(binding, "capabilities", ()) if c.action == "set_power"), None)
    if cap is None:
        return None
    for key in cap.keys:
        value = read_state(state, cap.resource, key, location=cap.location)
        if value is not None:
            return _POWER_WORDS.get(value) if isinstance(value, str) else None
    return None


class ThinqPowerCache:
    """가전 ID → (전원, 조회 시각)과 (공기질 요약, 전원, 조회 시각). 스레드 안전. 입출력 없음."""

    def __init__(self, monotonic: Callable[[], float] | None = None) -> None:
        self._monotonic = monotonic or time.monotonic
        self._lock = threading.Lock()
        self._entries: dict[str, tuple[str, float]] = {}
        self._air: dict[str, tuple[dict, str | None, float]] = {}
        self._last_read_at: float | None = None

    def observe(self, appliance_id: str, binding: Any, state: Any) -> None:
        """조회 한 번의 결과를 적는다. 전원·공기질을 모르면 그 가전의 그 기억을 지운다."""
        power = power_of(binding, state)
        air = air_summary(state) if state is not None else None
        with self._lock:
            now = self._monotonic()
            if state is not None:
                self._last_read_at = now
            if power is None:
                self._entries.pop(appliance_id, None)
            else:
                self._entries[appliance_id] = (power, now)
            if air is None:
                self._air.pop(appliance_id, None)
            else:
                self._air[appliance_id] = (air, power, now)

    def forget(self, appliance_id: str) -> None:
        with self._lock:
            self._entries.pop(appliance_id, None)
            self._air.pop(appliance_id, None)

    def clear(self) -> None:
        with self._lock:
            self._entries.clear()
            self._air.clear()
            self._last_read_at = None

    def last_read_age(self) -> float | None:
        """마지막으로 성공한 ThinQ 상태 읽기의 나이. 새 클라우드 호출은 하지 않는다."""
        now = self._monotonic()
        with self._lock:
            read_at = self._last_read_at
        if read_at is None:
            return None
        age = now - read_at
        return age if age >= 0 else None

    def snapshot(self, max_age: float = POWER_STALE_SECONDS) -> list[dict]:
        """오래되지 않은 기억만 — ``[{"appliance_id", "power", "age_s"}]``(가전 ID 순)."""
        now = self._monotonic()
        with self._lock:
            items = sorted(self._entries.items())
        out = []
        for appliance_id, (power, read_at) in items:
            age = now - read_at
            if 0 <= age <= max_age:
                out.append({"appliance_id": appliance_id, "power": power, "age_s": round(age, 1)})
        return out

    def air_snapshot(self, max_age: float = POWER_STALE_SECONDS) -> list[dict]:
        """오래되지 않은 공기질 기억만 — ``[{"appliance_id", "grade", "grade_source", "pm25", "pm25_level", "pm10",
        "pm10_level", "power", "age_s"}]``(가전 ID 순). ``power``는 같은 조회의 전원(``on``·``off``, 모르면 None)."""
        now = self._monotonic()
        with self._lock:
            items = sorted(self._air.items())
        out = []
        for appliance_id, (air, power, read_at) in items:
            age = now - read_at
            if 0 <= age <= max_age:
                out.append({"appliance_id": appliance_id, **air, "power": power, "age_s": round(age, 1)})
        return out
