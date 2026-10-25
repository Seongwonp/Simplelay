"""온습도 기반 선제 제안 후보.

패턴 제안이 "사용 이력"을 보는 것과 달리, 이건 "지금 공간이 어떤가"(온습도)를 본다.
쾌적 범위를 벗어나면 냉방 제안 후보를 낸다 -- 센서(공간 이해)와 선제 제안(공감지능)을
잇는 자리다. 판단은 설명 가능한 임계값이다(지도교수 방침: AI 고도화가 아니라 배선).

센서 읽기는 주입받는다 -- 테스트는 고정값, 프로덕션은 DHT22(+데모 오버라이드).
둘 다 None(미연결)이면 후보를 내지 않는다.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from math import isfinite

# () -> (temperature_°C | None, humidity_% | None)
SensorRead = Callable[[], "tuple[float | None, float | None]"]


@dataclass(frozen=True)
class ComfortThresholds:
    """이 값 이상이면 '덥다/습하다'로 본다. 데모·현장에서 조정 가능."""

    temperature_c: float = 28.0
    humidity_pct: float = 70.0


@dataclass(frozen=True)
class EnvironmentalCandidate:
    purpose: str
    reason: str  # 사용자에게 보일 근거 -- "지금 30°C · 습도 75% — 더워요"
    # 이 제안이 조작할 가전. 제안과 실행 대상이 어긋나지 않게 끝까지 들고 간다.
    appliance_id: str | None = None
    is_demo: bool = False
    #: '왜 지금' 신호(2026-10-26) — 카드 칩. ``((이름, 맞음), …)``.
    signals: tuple = ()


class EnvironmentalSuggester:
    def __init__(
        self,
        sensor_read: SensorRead,
        thresholds: ComfortThresholds | None = None,
        purpose: str = "에어컨 켜줘",
        appliance_id: str = "aircon",
        demo_read: Callable[[], tuple[float, float] | None] | None = None,
    ) -> None:
        self._demo_read = demo_read
        self._read = sensor_read
        self._th = thresholds or ComfortThresholds()
        self._purpose = purpose
        self._appliance_id = appliance_id

    def candidate(self) -> EnvironmentalCandidate | None:
        forced = self._demo_read() if self._demo_read else None
        temp, hum = forced if forced is not None else self._read()
        # Invalid sensor values cannot justify a physical suggestion.
        def finite(value):
            return isinstance(value, (int, float)) and not isinstance(value, bool) and isfinite(value)
        temp = temp if finite(temp) else None
        hum = hum if finite(hum) and 0 <= hum <= 100 else None
        hot = temp is not None and temp >= self._th.temperature_c
        humid = hum is not None and hum >= self._th.humidity_pct
        if not (hot or humid):
            return None
        bits: list[str] = []
        if hot:
            bits.append(f"{temp:.0f}°C")
        if humid:
            bits.append(f"습도 {hum:.0f}%")
        return EnvironmentalCandidate(
            self._purpose,
            ("시연 데이터 · " if forced is not None else "") + "지금 " + " · ".join(bits) + (" — 더워요" if hot else " — 습해요"),
            appliance_id=self._appliance_id,
            is_demo=forced is not None,
            signals=tuple((label, True) for label in (
                ([f"실내 {temp:.0f}°C"] if hot else []) + ([f"습도 {hum:.0f}%"] if humid else []))),
        )
