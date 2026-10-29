"""여러 신호를 함께 보고 '지금' 도울 때를 고르는 환경 제안(2026-10-26).

공감지능의 한 조각이다: 한 신호(공기질 하나·시각 하나)가 아니라 **사람 감지 · 방 밝기 · 공기청정기 상태 · 실내 공기질 ·
기상특보**를 함께 보고, 맞는 때에 **묻기만** 한다. 카드는 보통 시나리오 카드다(``rpi/scenarios/catalog.py``의
``CONTEXT_SCENARIOS``) — 승인 뒤에만 종전 승인·실행 경로로 나간다. **여기서는 아무것도 실행하지 않는다.**

규칙(앞에서부터 보고, 카드 하나를 만들면 그 판독은 끝 — 한 번에 카드 하나):

- A ``lights_off`` 불 끄면 수면 모드: 사람이 있고, 방이 밝음 → 어두움으로 바뀐 지 ``lights_off_hold_s`` 넘게 그대로이고
  (``lights_off_fresh_s`` 안), 지역 시각이 ``night_start_hour``~``night_end_hour``이고, 공기청정기가 켜져 있고 수면 모드가
  아니면 → 수면 모드(``set_job_mode SLEEP``)를 묻는다. 불 끈 한 번에 한 번, 그리고 ``sleep_cooldown_s``.
- B ``arrival`` 돌아왔을 때 공기: 오래 비웠다 돌아온 때(사람 감지의 인사 조건 ``greet``와 같다) ``arrival_window_s`` 안에,
  공기청정기가 꺼져 있고 실내 공기질 등급이 보통 이하(``ARRIVAL_AIR_LEVELS`` — 가전이 매긴 등급, 공기질 제안과 같은 값)
  이거나 황사 특보가 있으면 → 켜기를 묻는다. 돌아온 한 번에 한 번, 그리고 ``arrival_cooldown_s``.
- C ``dust_warning`` 황사 특보: 황사 특보가 새로 걸리고(없음 → 있음), 사람이 있고 공기청정기가 꺼져 있으면 → 켜기를
  묻는다. 특보가 걸린 동안 사람이 없으면 기다렸다가 사람이 있을 때 묻는다. ``dust_cooldown_s``(6시간).

공통:

- 조용한 시간·잠시 쉬기·다시 받지 않기·부재는 제안 서비스가 다른 제안과 똑같이 막는다(막혔으면 None → 기억을 바꾸지
  않고 다음 판독에서 다시 본다). 비상정지 걸림·떠 있는 다른 카드는 여기서 먼저 막는다(``blocked``).
- 켜기 카드(B·C)는 공기질 제안과 **재알림 기억을 함께 쓴다** — 공기질 카드의 쉬는 시간 안이면 묻지 않고, 묻고 나면
  공기질 제안도 쉬는 시간을 지킨다(:meth:`rpi.services.air_quality.AirQualityMonitor.note_external_card`).
- 값이 없으면 지어내지 않는다: 공기청정기 상태가 오래됐거나(``purifier_state_max_age_s``) 칸이 없으면 그 규칙은 넘어간다.
- 습도: 공기청정기 카드(A·B·C)의 근거에는 넣지 않는다(공기청정기와 무관). 습도는 아래 조언 D가 쓴다.
- D ``advice_ventilate`` 환기 조언(2026-10-26, **실행 없음** — '알겠어요'·'괜찮아요'만): 사람이 있고 8~21시, 실내가 습하고
  바깥이 덜 습하거나 실내 온도 기준과 실내외 온도 차를 모두 만족하고, 비가 없고(강수형태 0·강수확률 40% 미만) 황사 특보가 없고 바깥
  미세먼지(에어코리아)가 좋음·보통이면 창문 열기를 권한다. 하루 한 번.
- E ``advice_windows_closed``: D와 같은 '창문 열 만한 때'인데 바깥 미세먼지가 나쁨 이상이면 창문을 닫아 두자고 한다. 하루 한 번.
- 조언도 하루 묻는 상한·무시 물러서기·조용한 시간·잠시 쉬기·부재를 똑같이 따른다(제안 서비스 ``create_advice``).
- 로그에는 규칙 이름과 결과·신호 이름만 쓴다(사람 이름·영상·기기 ID 없음).

값의 근거: 시간 창 21~02시·2분·6시간은 사용자 지시(2026-10-26). 나머지 기본값은 **추측**이다(측정·사용 뒤 조정 필요) —
아래 :class:`ContextRuleConfig` 주석에 표시했다. 전부 환경 변수로 바꿀 수 있다.
"""

from __future__ import annotations

import inspect
import logging
import os
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, fields, replace
from datetime import datetime

from .air_quality import air_summary

log = logging.getLogger(__name__)

PRESENT = "present"  # rpi.services.room_presence.PRESENT 와 같은 값(가져오지 않고 값만 맞춘다)

RULE_SLEEP = "context_sleep_mode"
RULE_ARRIVAL = "context_arrival_air"
RULE_DUST = "context_dust_air"
CONTEXT_SCENARIO_IDS = (RULE_SLEEP, RULE_ARRIVAL, RULE_DUST)
#: 조언 카드(2026-10-26, 실행 없음) — D 환기 권유 · E 바깥 공기가 나쁠 때 창문 닫기.
ADVICE_VENTILATE = "advice_ventilate"
ADVICE_WINDOWS_CLOSED = "advice_windows_closed"
VENTILATE_TITLE = "창문을 열어 환기해 보세요"
WINDOWS_CLOSED_TITLE = "창문은 닫아 두세요"
#: 바깥 미세먼지 등급(에어코리아 말) — 환기해도 되는 것·나쁜 것.
OUTDOOR_OK_GRADES = ("좋음", "보통")
OUTDOOR_BAD_GRADES = ("나쁨", "매우 나쁨")
#: 실내 공기가 괜찮다(공기청정기가 매긴 등급).
INDOOR_FINE_LEVELS = ("GOOD", "NORMAL")

#: 돌아왔을 때 켜기를 물을 실내 공기 등급(가전이 매긴 값 — 우리 임계값 없음, 공기질 제안과 같은 등급 이름).
#: '보통'부터 넣는다: 나쁨 이상은 공기질 제안도 잡지만, 돌아온 때는 보통이어도 미리 켜 둘지 묻는다(사용자 지시).
ARRIVAL_AIR_LEVELS = ("NORMAL", "BAD", "VERY_BAD")

# 근거·질문 문장(정해 둔 틀, 해요체·느낌표 없음 — docs/UX-문구-기준-2026-10-19.md)
SLEEP_REASON = "불을 끄셨네요. 밤이고 공기청정기가 켜져 있어요."
ARRIVAL_PREFIX = "다녀오셨어요."
ARRIVAL_AIR_SENTENCES = {
    "NORMAL": "실내 공기가 보통이에요.",
    "BAD": "실내 공기가 나빠요.",
    "VERY_BAD": "실내 공기가 매우 나빠요.",
}
#: '왜 지금' 칩의 공기 등급 말(가전이 매긴 등급 그대로).
ARRIVAL_AIR_WORDS = {"NORMAL": "보통", "BAD": "나쁨", "VERY_BAD": "매우 나쁨"}
DUST_SENTENCE = "황사 특보가 있어요."
PURIFIER_OFF_SENTENCE = "공기청정기가 꺼져 있어요."
DUST_REASON = "황사 특보가 났어요. " + PURIFIER_OFF_SENTENCE
OUTDOOR_BAD_SENTENCE = "바깥 미세먼지도 나빠요."


@dataclass(frozen=True)
class ContextRuleConfig:
    #: 불이 꺼진 뒤 이만큼 그대로여야 묻는다(초). 사용자 지시 2분. 방 밝기 판단 자체가 30초 평균이라 실제로는 더 늦다.
    lights_off_hold_s: float = 120.0
    #: 불 끈 지 이보다 오래면 묻지 않는다(초) — 한참 전에 끈 불로 뒤늦게 묻지 않게. **추측** 15분.
    lights_off_fresh_s: float = 15 * 60.0
    #: 밤 시간 창(지역 시각, 시작 포함·끝 제외). 사용자 지시 21:00~02:00.
    night_start_hour: int = 21
    night_end_hour: int = 2
    #: 수면 모드 카드를 만든 뒤 다시 만들지 않는 시간(초). **추측** 하룻밤 한 번(8시간).
    sleep_cooldown_s: float = 8 * 3600.0
    #: 돌아온 뒤 이 안에서만 묻는다(초) — 공기청정기 상태를 아직 못 읽었으면 이 안에서 다음 판독을 기다린다. **추측** 10분.
    arrival_window_s: float = 10 * 60.0
    #: 돌아왔을 때 카드 뒤 쉬는 시간(초). 인사 간격(3시간)과 같게 — **추측**.
    arrival_cooldown_s: float = 3 * 3600.0
    #: 황사 특보 카드 뒤 쉬는 시간(초). 사용자 지시 6시간.
    dust_cooldown_s: float = 6 * 3600.0
    #: 공기청정기 상태를 믿는 나이(초) — 공기질 판독 주기 기본 120초의 두 번 + 여유. **추측**.
    purifier_state_max_age_s: float = 300.0
    # 조언(2026-10-26, 표시 없는 값은 **추측** — 사용 뒤 조정)
    #: 조언을 하는 지역 시각(시작 포함·끝 제외). 사용자 지시 8~21시.
    advice_start_hour: int = 8
    advice_end_hour: int = 21
    #: 실내 습도가 이 이상이면 '습하다'(온습도 카드와 같은 70%).
    vent_humidity_pct: float = 70.0
    #: 바깥 습도가 실내보다 이만큼 낮아야 '바깥이 덜 습하다'.
    vent_humidity_gap: float = 10.0
    #: 실내 온도 기준도 만족할 때 필요한 실내외 온도 차.
    vent_temp_gap: float = 3.0
    #: 온도 차만으로 환기를 권하지 않는다. 기존 환경 제안과 같은 제품 기본값이며 체감 온도 판정은 아니다.
    vent_min_indoor_c: float = 28.0
    #: 바깥이 이보다 추우면 창문 열기를 권하지 않는다.
    vent_min_outdoor_c: float = 10.0
    #: 강수확률이 이 이상이면 권하지 않는다. 사용자 지시 40%.
    vent_max_pop: float = 40.0

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> ContextRuleConfig:
        """``SIMPLELAY_CONTEXT_<칸 이름 대문자>``로 바꾼다(예: ``SIMPLELAY_CONTEXT_NIGHT_START_HOUR=22``). 틀린 값은 기본값."""
        env = os.environ if env is None else env
        config = cls()
        changes = {}
        for field in fields(cls):
            raw = (env.get(f"{CONTEXT_ENV_PREFIX}{field.name.upper()}") or "").strip()
            if not raw:
                continue
            try:
                value = int(raw) if field.type in ("int", int) else float(raw)
            except ValueError:
                log.warning("%s%s 값이 숫자가 아니라 기본값으로 읽어요", CONTEXT_ENV_PREFIX, field.name.upper())
                continue
            if value != value or value < 0 or (field.type in ("int", int) and value > 23):
                continue
            changes[field.name] = value
        return replace(config, **changes) if changes else config


CONTEXT_ENV_PREFIX = "SIMPLELAY_CONTEXT_"
POLL_ENV = "SIMPLELAY_CONTEXT_POLL_SECONDS"
#: 판정 주기(초). 판정 자체는 메모리 값만 보고(특보만 30분마다 묻는다) 가볍다. **추측** 30초.
DEFAULT_POLL_SECONDS = 30.0
MIN_POLL_SECONDS = 5.0
MAX_POLL_SECONDS = 600.0


def poll_seconds_from_env(env: Mapping[str, str] | None = None) -> float:
    env = os.environ if env is None else env
    raw = (env.get(POLL_ENV) or "").strip()
    try:
        value = float(raw) if raw else DEFAULT_POLL_SECONDS
    except ValueError:
        return DEFAULT_POLL_SECONDS
    if value != value:
        return DEFAULT_POLL_SECONDS
    return min(max(value, MIN_POLL_SECONDS), MAX_POLL_SECONDS)


@dataclass(frozen=True)
class ContextSignals:
    """한 번 판정에 쓰는 신호. 모르는 것은 None — 규칙은 모르는 신호로 묻지 않는다."""

    #: 지역 시각.
    local_now: datetime
    #: 사람 감지 판단(present·idle·away·unknown), 감지가 꺼져 있으면 None.
    presence: str | None = None
    #: 오래 비웠다 돌아온 때(사람 감지 ``arrived_at``, ``greet``일 때만)와 지금(같은 벽시계).
    arrival_at: float | None = None
    wall_now: float = 0.0
    #: 불이 꺼진 순간(밝음 → 어두움)과 그 뒤 지난 초 — 방 밝기 시계 기준. 아니면 None.
    lights_off_at: float | None = None
    dark_for_s: float | None = None
    #: 공기청정기 ThinQ 상태(최근에 읽은 것), 없으면 None.
    purifier: Mapping | None = None
    #: 우리 지역에 황사 특보가 걸려 있나.
    dust_warning: bool = False
    #: 실내 온습도(DHT22), 바깥 기온·습도·강수형태·강수확률(기상청 '지금' 칸), 바깥 미세먼지 등급(에어코리아 말 — '보통').
    indoor_temp: float | None = None
    indoor_humidity: float | None = None
    outdoor_temp: float | None = None
    outdoor_humidity: float | None = None
    outdoor_pty: int | None = None
    outdoor_pop: int | None = None
    outdoor_air: str | None = None
    #: 오늘 해 지는 시각(지역 시각). 모르면 None.
    sunset: datetime | None = None


def _purifier_power(state) -> str | None:
    operation = state.get("operation") if isinstance(state, Mapping) else None
    value = operation.get("airPurifierOperationMode") if isinstance(operation, Mapping) else None
    return value if value in ("POWER_ON", "POWER_OFF") else None


def _purifier_job_mode(state) -> str | None:
    section = state.get("airPurifierJobMode") if isinstance(state, Mapping) else None
    value = section.get("currentJobMode") if isinstance(section, Mapping) else None
    return value if isinstance(value, str) and value else None


def is_night(local_now: datetime, start_hour: int, end_hour: int) -> bool:
    """``start_hour`` 이상 또는 ``end_hour`` 미만(자정을 넘는 창). 시작이 끝보다 작으면 하루 안의 창."""
    hour = local_now.hour
    if start_hour <= end_hour:
        return start_hour <= hour < end_hour
    return hour >= start_hour or hour < end_hour


class ContextSuggestionMonitor:
    """판정 한 번(:meth:`check_once`)마다 규칙 A·B·C를 본다. 입출력은 넘겨받은 함수가 한다(이 클래스는 기억만).

    - ``signals()`` → :class:`ContextSignals`.
    - ``offer(scenario_id, reason)`` → 만든(또는 떠 있던) 카드, 막혔으면 None.
    - ``blocked()`` → 막는 이유 이름(비상정지 걸림·떠 있는 카드) 또는 None.
    - ``air_card_recent()`` → 공기질 카드 쉬는 시간 안인가. ``note_power_card()`` → 켜기 카드를 만들었다고 알린다.
    """

    def __init__(
        self,
        signals: Callable[[], ContextSignals],
        offer: Callable[[str, str], object | None],
        *,
        blocked: Callable[[], str | None] = lambda: None,
        air_card_recent: Callable[[], bool] = lambda: False,
        note_power_card: Callable[[], None] = lambda: None,
        advise: Callable[..., object | None] | None = None,
        monotonic: Callable[[], float] | None = None,
        config: ContextRuleConfig | None = None,
    ) -> None:
        self._signals = signals
        self._offer = offer
        self._blocked = blocked
        self._air_card_recent = air_card_recent
        self._note_power_card = note_power_card
        #: ``advise(title=, text=, signals=)`` → 조언 카드(막혔으면 None). None이면 조언 규칙은 쉰다.
        self._advise = advise
        #: 조언마다 마지막으로 만든 날(지역 날짜) — 하루 한 번.
        self._advice_days: dict[str, object] = {}
        self._monotonic = monotonic or time.monotonic
        self.config = config or ContextRuleConfig()
        try:
            params = inspect.signature(offer).parameters.values()
            self._offer_takes_signals = any(p.name == "signals" or p.kind is p.VAR_KEYWORD for p in params)
        except (TypeError, ValueError):
            self._offer_takes_signals = False
        self._lock = threading.Lock()
        self._last_card: dict[str, float] = {}
        self._sleep_done_for: float | None = None  # 이미 다룬 불 끔(꺼진 순간)
        self._arrival_done_for: float | None = None  # 이미 다룬 돌아옴(돌아온 시각)
        self._dust_seen = False
        self._dust_pending = False
        self.last_outcome: str | None = None

    def forget_recent(self) -> None:
        """쉬는 시간·다룬 일 기억을 지운다 — 시험·모의 리허설용."""
        with self._lock:
            self._last_card.clear()
            self._sleep_done_for = None
            self._arrival_done_for = None
            self._dust_seen = False
            self._dust_pending = False
            self._advice_days.clear()

    def check_once(self) -> str:
        """결과 한 줄 — ``<규칙>:<결과>``를 ``,``로 이은 것, 또는 ``blocked:<이유>``. 카드를 만든 규칙이 있으면 거기서 끝."""
        with self._lock:
            outcome = self._check_locked()
            self.last_outcome = outcome
            return outcome

    # 판정
    def _check_locked(self) -> str:
        s = self._signals()
        self._track_dust(s.dust_warning)
        reason = self._blocked()
        if reason:
            return f"blocked:{reason}"
        outcomes = []
        for name, rule in (("sleep", self._rule_sleep), ("arrival", self._rule_arrival), ("dust", self._rule_dust),
                           ("ventilate", self._rule_ventilate), ("windows", self._rule_windows_closed)):
            result = rule(s)
            outcomes.append(f"{name}:{result}")
            if result in ("offered", "not_offered"):
                # 규칙이 맞았다(카드를 만들었거나 제안 서비스가 막았다) — 신호 이름만 한 줄(개인 정보 없음).
                log.info("context rule %s → %s (presence=%s night=%s dark_s=%s power=%s mode=%s dust=%s)",
                         name, result, s.presence, is_night(s.local_now, self.config.night_start_hour,
                                                            self.config.night_end_hour),
                         None if s.dark_for_s is None else int(s.dark_for_s),
                         _purifier_power(s.purifier), _purifier_job_mode(s.purifier), s.dust_warning)
            if result == "offered":
                break
        return ",".join(outcomes)

    def _track_dust(self, active: bool) -> None:
        if active and not self._dust_seen:
            self._dust_pending = True  # 없음 → 있음: 새로 걸린 특보
        if not active:
            self._dust_pending = False
        self._dust_seen = active

    def _cooling(self, rule: str, cooldown_s: float) -> bool:
        last = self._last_card.get(rule)
        return last is not None and self._monotonic() - last < cooldown_s

    def _ask(self, rule: str, reason: str, signals) -> object | None:
        """카드를 청한다 — 판정에 실제로 쓴 신호를 '왜 지금' 칩으로 함께 넘긴다(받을 수 있는 쪽에만)."""
        if self._offer_takes_signals:
            return self._offer(rule, reason, signals=tuple((label, True) for label in signals))
        return self._offer(rule, reason)

    def _mark(self, rule: str) -> None:
        self._last_card[rule] = self._monotonic()

    def _rule_sleep(self, s: ContextSignals) -> str:
        c = self.config
        if s.lights_off_at is None or s.dark_for_s is None:
            return "no_lights_off"
        if s.lights_off_at == self._sleep_done_for:
            return "done"
        if s.dark_for_s < c.lights_off_hold_s:
            return "holding"
        if s.dark_for_s > c.lights_off_fresh_s:
            return "stale"
        if s.presence != PRESENT:
            return "absent"
        if not is_night(s.local_now, c.night_start_hour, c.night_end_hour):
            return "not_night"
        if s.sunset is not None and s.local_now.hour >= 12 and s.local_now < s.sunset:
            return "before_sunset"  # 해가 아직 있다 — 방이 어두워도 밤으로 보지 않는다(밤 창을 바꿨을 때의 덧막이)
        if s.purifier is None:
            return "no_purifier_state"
        if _purifier_power(s.purifier) != "POWER_ON":
            return "purifier_not_on"
        mode = _purifier_job_mode(s.purifier)
        if mode is None:
            return "mode_unknown"
        if mode == "SLEEP":
            self._sleep_done_for = s.lights_off_at
            return "already_sleep"
        if self._cooling(RULE_SLEEP, c.sleep_cooldown_s):
            return "cooldown"
        if self._ask(RULE_SLEEP, SLEEP_REASON, ("집에 계심", "불을 끄심", "밤", "공기청정기 켜짐")) is None:
            return "not_offered"
        self._sleep_done_for = s.lights_off_at
        self._mark(RULE_SLEEP)
        return "offered"

    def _rule_arrival(self, s: ContextSignals) -> str:
        c = self.config
        if s.arrival_at is None:
            return "no_arrival"
        if s.arrival_at == self._arrival_done_for:
            return "done"
        if s.wall_now - s.arrival_at > c.arrival_window_s:
            return "window_passed"
        if s.presence != PRESENT:
            return "absent"
        if s.purifier is None:
            return "no_purifier_state"
        if _purifier_power(s.purifier) != "POWER_OFF":
            return "purifier_not_off"
        summary = air_summary(s.purifier)
        grade = summary["grade"] if summary is not None else None
        air_sentence = ARRIVAL_AIR_SENTENCES.get(grade) if grade in ARRIVAL_AIR_LEVELS else None
        outdoor_bad = s.outdoor_air in OUTDOOR_BAD_GRADES
        if air_sentence is None and not s.dust_warning and not outdoor_bad:
            return "air_ok"
        if self._cooling(RULE_ARRIVAL, c.arrival_cooldown_s):
            return "cooldown"
        if self._air_card_recent():
            return "air_card_quiet"
        parts = [ARRIVAL_PREFIX]
        chips = ["다녀오심"]
        if air_sentence is not None:
            parts.append(air_sentence)
            chips.append(f"실내 공기 {ARRIVAL_AIR_WORDS[grade]}")
        if s.dust_warning:
            parts.append(DUST_SENTENCE)
            chips.append("황사 특보")
        if outdoor_bad:
            parts.append(OUTDOOR_BAD_SENTENCE if air_sentence is not None or s.dust_warning
                         else "바깥 미세먼지가 나빠요.")
            chips.append(f"바깥 미세먼지 {s.outdoor_air}")
        parts.append(PURIFIER_OFF_SENTENCE)
        chips.append("공기청정기 꺼짐")
        if self._ask(RULE_ARRIVAL, " ".join(parts), chips) is None:
            return "not_offered"
        self._arrival_done_for = s.arrival_at
        self._mark(RULE_ARRIVAL)
        if s.dust_warning:
            self._dust_pending = False  # 같은 특보로 C가 또 묻지 않게
        self._note_power_card()
        return "offered"

    def _rule_dust(self, s: ContextSignals) -> str:
        c = self.config
        if not self._dust_pending:
            return "no_new_warning"
        if s.presence != PRESENT:
            return "absent"  # 특보가 걸린 동안 사람이 오면 그때 묻는다
        if s.purifier is None:
            return "no_purifier_state"
        power = _purifier_power(s.purifier)
        if power == "POWER_ON":
            self._dust_pending = False  # 이미 켜져 있다 — 물을 일이 없다
            return "purifier_on"
        if power != "POWER_OFF":
            return "power_unknown"
        if self._cooling(RULE_DUST, c.dust_cooldown_s):
            return "cooldown"
        if self._air_card_recent():
            return "air_card_quiet"
        if self._ask(RULE_DUST, DUST_REASON, ("황사 특보", "집에 계심", "공기청정기 꺼짐")) is None:
            return "not_offered"
        self._dust_pending = False
        self._mark(RULE_DUST)
        self._note_power_card()
        return "offered"


    # 조언(실행 없음, 2026-10-26)
    def _window_likely(self, s: ContextSignals):
        """창문을 열 만한 때인가 — ``(이유 이름, 근거 문장, 칩)``, 아니면 ``(안 되는 이유, None, None)``.

        사람이 집에 있고, 낮(8~21시), 실내가 습하고 바깥이 덜 습하거나 실내 온도 기준과 실내외 온도 차를 모두 만족하고, 바깥이 너무 춥지
        않고, 비·눈이 없고 강수확률이 낮고, 황사 특보가 없을 때. 바깥 미세먼지는 부르는 쪽(D·E)이 따로 본다."""
        c = self.config
        if s.presence != PRESENT:
            return "absent", None, None
        if not c.advice_start_hour <= s.local_now.hour < c.advice_end_hour:
            return "not_daytime", None, None
        if s.outdoor_temp is None or s.outdoor_pty is None or s.outdoor_pop is None:
            return "no_outdoor", None, None
        if s.outdoor_pty != 0 or s.outdoor_pop >= c.vent_max_pop:
            return "rain", None, None
        if s.dust_warning:
            return "dust_warning", None, None
        if s.outdoor_temp < c.vent_min_outdoor_c:
            return "cold_outside", None, None
        humid = (s.indoor_humidity is not None and s.indoor_humidity >= c.vent_humidity_pct
                 and s.outdoor_humidity is not None
                 and s.outdoor_humidity <= s.indoor_humidity - c.vent_humidity_gap)
        warm = (s.indoor_temp is not None and s.indoor_temp >= c.vent_min_indoor_c
                and s.indoor_temp >= s.outdoor_temp + c.vent_temp_gap)
        if humid:
            return "humid", f"실내 습도가 {s.indoor_humidity:.0f}%로 꽤 습해요.", [f"실내 습도 {s.indoor_humidity:.0f}%"]
        if warm:
            return "warm", f"실내 온도는 {s.indoor_temp:.0f}도예요.", [f"실내 {s.indoor_temp:.0f}°C"]
        return "indoor_ok", None, None

    def _give_advice(self, advice_id: str, title: str, text: str, chips, s: ContextSignals) -> str:
        if self._advise(title=title, text=text, signals=tuple((label, True) for label in chips)) is None:
            return "not_offered"
        self._advice_days[advice_id] = s.local_now.date()
        return "offered"

    def _rule_ventilate(self, s: ContextSignals) -> str:
        """D 환기 권유 — 창문을 열 만한 때이고 바깥 미세먼지가 좋음·보통이면(모르면 권하지 않는다). 하루 한 번."""
        if self._advise is None:
            return "off"
        if self._advice_days.get(ADVICE_VENTILATE) == s.local_now.date():
            return "done"
        why, first, chips = self._window_likely(s)
        if first is None:
            return why
        if s.outdoor_air not in OUTDOOR_OK_GRADES:
            return "outdoor_air_unknown" if s.outdoor_air is None else "outdoor_air_bad"
        if why == "humid" and s.outdoor_temp > 22:
            second = f"바깥은 습도가 {s.outdoor_humidity:.0f}%로 덜 습하니"
        else:
            second = f"바깥은 {s.outdoor_temp:.0f}도로 선선하니"
        text = f"{first} {second} 잠깐 창문을 열어 환기해 보시는 건 어떨까요?"
        return self._give_advice(ADVICE_VENTILATE, VENTILATE_TITLE, text,
                                 ["집에 계심", *chips, f"바깥 {s.outdoor_temp:.0f}°C", f"바깥 미세먼지 {s.outdoor_air}"], s)

    def _rule_windows_closed(self, s: ContextSignals) -> str:
        """E 창문 닫기 — 창문을 열 만한 때인데 바깥 미세먼지가 나쁘면(드물게, 하루 한 번)."""
        if self._advise is None:
            return "off"
        if s.outdoor_air not in OUTDOOR_BAD_GRADES:
            return "outdoor_air_ok"
        if self._advice_days.get(ADVICE_WINDOWS_CLOSED) == s.local_now.date():
            return "done"
        why, first, chips = self._window_likely(s)
        if first is None:
            return why
        summary = air_summary(s.purifier) if s.purifier is not None else None
        indoor_fine = summary is not None and summary.get("grade") in INDOOR_FINE_LEVELS
        text = ("밖 공기는 나쁜데 집 안은 괜찮아요. 창문은 닫아 두세요." if indoor_fine
                else "밖 공기가 나빠요. 창문은 닫아 두세요.")
        return self._give_advice(ADVICE_WINDOWS_CLOSED, WINDOWS_CLOSED_TITLE, text,
                                 ["집에 계심", f"바깥 미세먼지 {s.outdoor_air}", *chips], s)


def has_dust_warning(warnings) -> bool:
    """기상특보 목록(:func:`rpi.services.weather.warnings.active_warnings` 모양)에 황사가 있나."""
    return any(isinstance(w, Mapping) and (w.get("icon") == "dust" or w.get("kind") == "황사") for w in warnings or ())


__all__ = [
    "ADVICE_VENTILATE",
    "ADVICE_WINDOWS_CLOSED",
    "ARRIVAL_AIR_LEVELS",
    "CONTEXT_SCENARIO_IDS",
    "ContextRuleConfig",
    "ContextSignals",
    "ContextSuggestionMonitor",
    "DUST_REASON",
    "RULE_ARRIVAL",
    "RULE_DUST",
    "RULE_SLEEP",
    "SLEEP_REASON",
    "has_dust_warning",
    "is_night",
    "poll_seconds_from_env",
]
