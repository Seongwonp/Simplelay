"""여러 가전이 함께 움직이는 **시나리오 정의** (화면 하드코딩이 아니라 데이터).

시나리오 = 트리거 + 질문 문장 + 단계(가전·경로·동작·인자). 정의는 제안을 **만들**
뿐이다. 실행은 언제나 사용자의 승인 뒤이고, 승인은 그 순간 정의로 만든 명령에
묶인다. 정의가 그 사이 바뀌면(예: 풍량 강 → 중) 카드의 승인은 무효이고 재승인한다.

**기본 카탈로그는 v4의 ``cook_done_air`` 하나다(2026-10-13).** v3(2026-10-06)에서 비웠고, 아래 세 개는 v2 시연(공기청정기·선풍기·제습기)의
정의라 v3("한 사람의 하루": 전자레인지·세탁기·인터폰)에서 뺐다. v3의 카드는 사용자 루틴이 만든다.
``SIMPLELAY_V2_SCENARIOS=1``로 명시적으로 켤 때만 다시 실린다(질의응답·회귀 시험용). 메커니즘(승인 결속·
지문 대조·ThinQ 이벤트 트리거)은 그대로다.

v4(2026-10-13, docs/본선-시연-계획-v4.md):

- ``cook_done_air`` 가열 종료 → 공기청정기(취소·문 열림 종료도 같게 잡힌다 — 정책상 허용, '조리 완료가 아닐 수 있음' 표기): RPi4가 보낸 **전자레인지 CT 끝 판정**(``appliance_done``,
  이벤트 ``heat_complete``, 입력에 전력 ``power``)일 때만 "공기청정기 풍량을 강으로 바꿀까요?"를 제안한다. 사용자의
  습관은 단정하지 않는다 — 같은 제안을 승인한 기록이 있을 때만 그 횟수를 근거로 붙인다(3차 평가 M4, 엔진). 버튼 누름
  완료(실행 성공)는 조리 완료가 아니라 트리거가 아니다. 이 카드만 '다음부터도 자동으로'(자동 실행 허용 규칙,
  ``rpi/routines/auto_rules.py``)를 고를 수 있다(``auto_allowed``).

v2 세 개:

- ``cook_then_air`` 조리 확인 → 공기 관리: 전자레인지(물리) 실행이 **가열 확인(L3)**
  으로 끝나면 "공기청정기 강풍으로 바꿀까요?"를 제안한다. 모의 실행은 L3가 없으므로
  ``allow_mock_success``일 때만 **시연 제안**으로 만든다(근거 문장에 모의임을 적는다).
  가열 확인만으로 강풍이 필요하다고 단정하지 않는다 -- 그래서 제안이다.
- ``evening_rest`` 저녁 휴식: 공기청정기 켜기(ThinQ) + 선풍기 약풍(물리, 지금은 모의).
  수동(시연) 트리거로만 만든다. 합성 이력이 근거라는 사실을 숨기지 않는다.
- ``wash_then_dry`` 세탁 완료 → 제습(2026-09-29): ThinQ 세탁기의 ``wash_complete`` 이벤트로
  "세탁이 끝났어요. 제습기를 켤까요?"를 제안한다. 모의 이벤트면 시연 제안이다. 제습기
  (ThinQ)가 등록·준비되지 않았으면(ThinQ off 포함) 카드를 만들지 않는다 -- 에러도 없다.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Mapping
from dataclasses import dataclass

from rpi.commands import Command, ControlRoute


@dataclass(frozen=True)
class ScenarioStep:
    target_id: str
    route: ControlRoute
    action: str = ""
    args: tuple[tuple[str, object], ...] = ()
    buttons: tuple[str, ...] = ()

    def command(self) -> Command:
        if self.route is ControlRoute.PHYSICAL:
            return Command.physical(self.target_id, self.buttons)
        return Command.thinq(self.target_id, self.action, dict(self.args))


@dataclass(frozen=True)
class ScenarioTrigger:
    #: job_completed | thinq_event | appliance_done | air_quality | manual
    kind: str
    appliance_id: str | None = None
    #: thinq_event 트리거의 이벤트 이름(예: wash_complete).
    event: str | None = None
    #: 모의 실행 성공을 트리거로 받을지(시연 제안으로만 만든다).
    allow_mock_success: bool = False


@dataclass(frozen=True)
class ScenarioDefinition:
    scenario_id: str
    name: str
    #: 카드 문장. 제안의 purpose로 쓰인다.
    question: str
    trigger: ScenarioTrigger
    steps: tuple[ScenarioStep, ...]
    #: 트리거 근거가 없을 때(수동) 카드에 적을 근거.
    manual_reason: str = ""
    #: thinq_event 트리거의 근거 문장(없으면 이벤트 이름으로 적는다).
    event_reason: str = ""
    valid_minutes: int = 15
    #: 이 카드에서 '다음부터도 자동으로'(자동 실행 허용 규칙)를 고를 수 있는가(v4 ``cook_done_air``만).
    auto_allowed: bool = False

    def commands(self) -> tuple[Command, ...]:
        return tuple(step.command() for step in self.steps)


COOK_THEN_AIR = ScenarioDefinition(
    scenario_id="cook_then_air",
    name="조리 확인 → 공기 관리",
    question="공기청정기 강풍으로 바꿀까요?",
    trigger=ScenarioTrigger("job_completed", appliance_id="microwave", allow_mock_success=True),
    steps=(
        ScenarioStep("air_purifier", ControlRoute.THINQ, "set_wind_strength",
                     (("wind_strength", "HIGH"),)),
    ),
)

COOK_DONE_AIR = ScenarioDefinition(
    scenario_id="cook_done_air",
    name="가열 종료 → 공기청정기",
    question="공기청정기 풍량을 강으로 바꿀까요?",
    trigger=ScenarioTrigger("appliance_done", appliance_id="microwave", event="heat_complete"),
    steps=(
        ScenarioStep("air_purifier", ControlRoute.THINQ, "set_wind_strength",
                     (("wind_strength", "HIGH"),)),
    ),
    # 2026-10-14(A5): CT 끝 판정은 취소·문 열림으로 가열이 끝난 것과 구분하지 못한다(실측 기록표 §6) —
    # 구분 근거가 생기기 전까지 '조리 완료'라고 말하지 않는다. 3차 평가 M4: 이력을 보지 않은 습관 단정
    # ('식사 뒤 공기청정기를 켜 두시곤 해요')은 뺐다 — 집계 근거는 엔진이 있을 때만 붙인다.
    event_reason="전자레인지 가열 종료를 콘센트 전력(CT)으로 감지했어요(조리 완료가 아닐 수 있어요)",
    auto_allowed=True,
)

AIR_QUALITY_HIGH = ScenarioDefinition(
    scenario_id="air_quality_high",
    name="공기가 나빠요",
    question="공기청정기를 강풍으로 바꿀까요?",
    # 2026-10-15(사용자 요청): 근거는 공기청정기 자체 센서(ThinQ)의 가전 등급뿐 — 판독·재알림은
    # rpi/services/air_quality.py, 판독 스레드는 rpi/api/air_quality_wiring.py. 센서 값이 없으면 만들지 않는다
    # (시연 트리거로도 만들지 않는다 — 엔진 ``trigger_manual``). 근거 문장은 판독이 채운다(예: '공기청정기 센서: 초미세먼지 42 · 나쁨').
    # '다음부터도 자동으로'는 두지 않는다(auto_allowed=False — 자동 실행 허용 규칙의 범위는 cook_done_air 그대로).
    # 트리거 이벤트는 판독 때 전원 상태: 켜져 있을 때(purifier_on)만 이 카드, 꺼져 있으면 아래 켜기 카드.
    trigger=ScenarioTrigger("air_quality", appliance_id="air_purifier", event="purifier_on"),
    steps=(
        ScenarioStep("air_purifier", ControlRoute.THINQ, "set_wind_strength",
                     (("wind_strength", "HIGH"),)),
    ),
    auto_allowed=False,
)

AIR_QUALITY_POWER_ON = ScenarioDefinition(
    scenario_id="air_quality_power_on",
    name="공기가 나빠요",
    question="공기청정기를 켤까요?",
    # 2026-10-15 저녁(사용자 결정): ThinQ 앱 공기질 센서 설정 '항상'이면 꺼진 공기청정기도 센서 값을 보낸다. 꺼져 있을 때
    # 나쁨이면 전원 켜기 **한 단계만** 묻는다 — 꺼진 공기청정기는 전원 밖의 명령을 클라우드가 거절(2304)하므로 풍량은 넣지 않는다.
    # 강풍 카드와 시나리오 ID를 나눠 기록·다시 받지 않기(질문 문장)가 섞이지 않게 했다. 재알림 기억은 판독 쪽에서 함께 쓴다
    # (rpi/services/air_quality.py — 켜기 승인 뒤 여전히 나쁘면 강풍 카드는 다시 준비·쉬는 시간 뒤에야).
    trigger=ScenarioTrigger("air_quality", appliance_id="air_purifier", event="purifier_off"),
    steps=(
        ScenarioStep("air_purifier", ControlRoute.THINQ, "set_power", (("power", "POWER_ON"),)),
    ),
    auto_allowed=False,
)

EVENING_REST = ScenarioDefinition(
    scenario_id="evening_rest",
    name="저녁 휴식",
    question="저녁 휴식 — 공기청정기를 켜고 선풍기를 약풍으로 켤까요?",
    trigger=ScenarioTrigger("manual"),
    steps=(
        ScenarioStep("air_purifier", ControlRoute.THINQ, "set_power", (("power", "POWER_ON"),)),
        ScenarioStep("fan", ControlRoute.PHYSICAL, buttons=("전원", "약풍")),
    ),
    manual_reason="시연: 합성 이력(저녁에 공기청정기와 선풍기를 함께 사용한 예시) — 실제 사용 기록이 아니에요",
)

WASH_THEN_DRY = ScenarioDefinition(
    scenario_id="wash_then_dry",
    name="세탁 완료 → 제습",
    question="세탁이 끝났어요. 실내 건조를 위해 제습기를 켤까요?",
    trigger=ScenarioTrigger("thinq_event", appliance_id="thinq_washer", event="wash_complete"),
    steps=(
        ScenarioStep("dehumidifier", ControlRoute.THINQ, "set_power", (("power", "POWER_ON"),)),
    ),
    event_reason="세탁기가 세탁 완료를 알렸어요 — 빨래를 실내에 널면 습도가 올라가요",
)

#: v2 시연의 시나리오 — v3에서 뺐다. ``SIMPLELAY_V2_SCENARIOS``로만 싣는다.
V2_SCENARIOS = (COOK_THEN_AIR, EVENING_REST, WASH_THEN_DRY)
#: 기본 카탈로그(v4): 가열 종료 감지 → 공기청정기, 그리고 공기청정기 센서 공기질 → 강풍(켜져 있을 때)·켜기(꺼져 있을 때)
#: (2026-10-15). 그 밖의 카드는 사용자 루틴이 만든다. v2 구성(opt-in)에는 공기질 카드를 싣지 않는다.
DEFAULT_SCENARIOS: tuple[ScenarioDefinition, ...] = (COOK_DONE_AIR, AIR_QUALITY_HIGH, AIR_QUALITY_POWER_ON)

V2_SCENARIOS_ENV = "SIMPLELAY_V2_SCENARIOS"


def scenarios_from_env(env: Mapping[str, str] | None = None) -> tuple[ScenarioDefinition, ...]:
    """서버가 실을 시나리오. 기본은 v4(``cook_done_air``), ``SIMPLELAY_V2_SCENARIOS=1``이면 v2 세 개."""
    env = os.environ if env is None else env
    if env.get(V2_SCENARIOS_ENV, "").strip().lower() in {"1", "true", "yes", "on"}:
        return V2_SCENARIOS
    return DEFAULT_SCENARIOS


class ScenarioCatalog:
    def __init__(self, definitions=DEFAULT_SCENARIOS) -> None:
        self._lock = threading.Lock()
        self._defs = {d.scenario_id: d for d in definitions}

    def get(self, scenario_id: str) -> ScenarioDefinition | None:
        with self._lock:
            return self._defs.get(scenario_id)

    def list(self) -> tuple[ScenarioDefinition, ...]:
        with self._lock:
            return tuple(self._defs.values())

    def replace_definition(self, definition: ScenarioDefinition) -> None:
        """정의 교체. 이미 떠 있는 카드의 승인은 다음 승인 시 지문 대조로 무효가 된다."""
        with self._lock:
            self._defs[definition.scenario_id] = definition

    def current_commands(self, scenario_id: str) -> tuple[Command, ...]:
        definition = self.get(scenario_id)
        return definition.commands() if definition is not None else ()


__all__ = [
    "AIR_QUALITY_HIGH",
    "AIR_QUALITY_POWER_ON",
    "COOK_DONE_AIR",
    "COOK_THEN_AIR",
    "DEFAULT_SCENARIOS",
    "EVENING_REST",
    "ScenarioCatalog",
    "ScenarioDefinition",
    "ScenarioStep",
    "ScenarioTrigger",
    "V2_SCENARIOS",
    "V2_SCENARIOS_ENV",
    "WASH_THEN_DRY",
    "scenarios_from_env",
]
