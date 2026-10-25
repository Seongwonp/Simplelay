"""온습도 기반 선제 제안 후보.

패턴 제안이 "사용 이력"을 보는 것과 달리, 이건 "지금 공간이 어떤가"(온습도)를 본다.
쾌적 범위를 벗어나면 **등록돼 있고 지금 실행할 수 있는 가전**에 맞는 카드 후보를 낸다 -- 센서(공간 이해)와
선제 제안(공감지능)을 잇는 자리다. 판단은 설명 가능한 임계값이다(지도교수 방침: AI 고도화가 아니라 배선).

가전 고르기(2026-10-26 — 예전에는 습해도 늘 '에어컨 켜줘'를 ``aircon``에 냈다. 에어컨이 없는 집에서도):

- 더움 → 냉방 기능이 있는 에어컨(``에어컨 켜줘`` 또는 이름에 '냉방'이 든 기능) — "에어컨을 켤까요?"
- 습함 → 제습기(ThinQ 제습기 '제습기 켜줘') — "제습기를 켤까요?", 없으면 제습 기능이 있는 에어컨(이름에 '제습'이 든 기능)
  — "에어컨을 제습 모드로 켤까요?"
- 맞는 가전이 없으면 카드를 내지 않는다(기기 없는 조언 — 환기 — 은 환경 제안 판정이 따로 한다).

센서 읽기와 가전 목록은 주입받는다 -- 테스트는 고정값, 프로덕션은 DHT22(+데모 오버라이드)와 가전 목록·준비 판정.
``targets``를 주지 않으면(옛 단위 시험) 종전처럼 고정 대상(``aircon``)을 쓴다. 센서가 둘 다 None(미연결)이면 후보를 내지 않는다.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from math import isfinite

# () -> (temperature_°C | None, humidity_% | None)
SensorRead = Callable[[], "tuple[float | None, float | None]"]

#: ThinQ 제습기 기기 종류(``rpi.services.thinq.bindings.DEHUMIDIFIER_DEVICE_TYPE``와 같은 값 — 가져오지 않고 값만 맞춘다).
DEHUMIDIFIER_DEVICE_TYPE = "DEVICE_DEHUMIDIFIER"
DEHUMIDIFIER_ON = "제습기 켜줘"
AIRCON_ON = "에어컨 켜줘"

QUESTION_DEHUMIDIFIER = "제습기를 켤까요?"
QUESTION_AIRCON_DRY = "에어컨을 제습 모드로 켤까요?"
QUESTION_AIRCON_COOL = "에어컨을 켤까요?"


@dataclass(frozen=True)
class ComfortThresholds:
    """이 값 이상이면 '덥다/습하다'로 본다. 데모·현장에서 조정 가능."""

    temperature_c: float = 28.0
    humidity_pct: float = 70.0


@dataclass(frozen=True)
class EnvironmentalCandidate:
    purpose: str
    reason: str  # 사용자에게 보일 근거 문장 -- "지금 실내 온도가 30도로 꽤 더워요."
    # 이 제안이 조작할 가전. 제안과 실행 대상이 어긋나지 않게 끝까지 들고 간다.
    appliance_id: str | None = None
    is_demo: bool = False
    #: '왜 지금' 신호(2026-10-26) — 카드 칩. ``((이름, 맞음), …)``.
    signals: tuple = ()
    #: 화면·소리로 묻는 말(2026-10-26) — "제습기를 켤까요?". 없으면 화면이 목적 문장에서 만든다.
    question: str | None = None


@dataclass(frozen=True)
class EnvironmentTarget:
    """가전 하나 — 고르기에 필요한 것만. ``functions``는 등록한 기능 이름(물리)·목적 문장(ThinQ)."""

    appliance_id: str
    category: str = "other"
    functions: tuple[str, ...] = ()
    thinq_device_type: str | None = None
    can_execute: bool = False


def _finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and isfinite(value)


def reason_sentence(temp: float | None, hum: float | None, hot: bool, humid: bool) -> str:
    """근거 문장(해요체, 느낌표·줄표 없음). 더우면 더위가 먼저, 습도는 덧붙인다."""
    if hot:
        text = f"지금 실내 온도가 {temp:.0f}도로 꽤 더워요."
        if humid:
            text += f" 습도도 {hum:.0f}%로 높아요."
        return text
    return f"지금 실내 습도가 {hum:.0f}%로 꽤 습해요."


def _cool_function(target: EnvironmentTarget) -> str | None:
    if AIRCON_ON in target.functions:
        return AIRCON_ON
    return next((name for name in target.functions if "냉방" in name), None)


def _dry_function(target: EnvironmentTarget) -> str | None:
    return next((name for name in target.functions if "제습" in name), None)


def pick_target(targets: Sequence[EnvironmentTarget], hot: bool, humid: bool):
    """(가전 ID, 목적, 질문) 또는 None. 지금 실행할 수 있는 가전만 본다."""
    ready = [t for t in targets if t.can_execute]
    aircons = [t for t in ready if t.category == "air_conditioner"]
    if hot:
        for t in aircons:
            purpose = _cool_function(t)
            if purpose is not None:
                return t.appliance_id, purpose, QUESTION_AIRCON_COOL
    if humid:
        for t in ready:
            if t.thinq_device_type == DEHUMIDIFIER_DEVICE_TYPE and DEHUMIDIFIER_ON in t.functions:
                return t.appliance_id, DEHUMIDIFIER_ON, QUESTION_DEHUMIDIFIER
        for t in aircons:
            purpose = _dry_function(t)
            if purpose is not None:
                return t.appliance_id, purpose, QUESTION_AIRCON_DRY
    return None


class EnvironmentalSuggester:
    def __init__(
        self,
        sensor_read: SensorRead,
        thresholds: ComfortThresholds | None = None,
        purpose: str = AIRCON_ON,
        appliance_id: str = "aircon",
        demo_read: Callable[[], tuple[float, float] | None] | None = None,
        targets: Callable[[], Sequence[EnvironmentTarget]] | None = None,
    ) -> None:
        self._demo_read = demo_read
        self._read = sensor_read
        self._th = thresholds or ComfortThresholds()
        self._purpose = purpose
        self._appliance_id = appliance_id
        #: 등록된 가전과 지금 실행 가능 여부. None이면 고정 대상(옛 단위 시험).
        self._targets = targets

    def reading(self) -> tuple[float | None, float | None]:
        """지금 실내 온습도(시연 값이 있으면 그것) — 틀린 값은 None."""
        forced = self._demo_read() if self._demo_read else None
        temp, hum = forced if forced is not None else self._read()
        temp = temp if _finite(temp) else None
        hum = hum if _finite(hum) and 0 <= hum <= 100 else None
        return temp, hum

    def candidate(self) -> EnvironmentalCandidate | None:
        forced = self._demo_read() if self._demo_read else None
        temp, hum = self.reading()
        hot = temp is not None and temp >= self._th.temperature_c
        humid = hum is not None and hum >= self._th.humidity_pct
        if not (hot or humid):
            return None
        if self._targets is None:
            appliance_id, purpose = self._appliance_id, self._purpose
            question = QUESTION_AIRCON_COOL if purpose == AIRCON_ON else None
        else:
            picked = pick_target(tuple(self._targets() or ()), hot, humid)
            if picked is None:
                return None
            appliance_id, purpose, question = picked
            # 고른 가전이 다루지 않는 조건은 근거에 넣지 않는다(제습기 카드에 '더워요'를 말하지 않게).
            if question != QUESTION_AIRCON_COOL:
                hot = False
        return EnvironmentalCandidate(
            purpose,
            ("시연 데이터예요. " if forced is not None else "") + reason_sentence(temp, hum, hot, humid),
            appliance_id=appliance_id,
            is_demo=forced is not None,
            signals=tuple((label, True) for label in (
                ([f"실내 {temp:.0f}°C"] if hot else []) + ([f"습도 {hum:.0f}%"] if humid else []))),
            question=question,
        )
