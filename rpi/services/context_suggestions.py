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
- 습도: 제습기·가습기가 없으니 습도로 무엇을 하자고 하지 않는다(근거 문장에도 넣지 않는다 — 공기청정기와 무관).
- 로그에는 규칙 이름과 결과·신호 이름만 쓴다(사람 이름·영상·기기 ID 없음).

값의 근거: 시간 창 21~02시·2분·6시간은 사용자 지시(2026-10-26). 나머지 기본값은 **추측**이다(측정·사용 뒤 조정 필요) —
아래 :class:`ContextRuleConfig` 주석에 표시했다. 전부 환경 변수로 바꿀 수 있다.
"""

from __future__ import annotations

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

#: 돌아왔을 때 켜기를 물을 실내 공기 등급(가전이 매긴 값 — 우리 임계값 없음, 공기질 제안과 같은 등급 이름).
#: '보통'부터 넣는다: 나쁨 이상은 공기질 제안도 잡지만, 돌아온 때는 보통이어도 미리 켜 둘지 묻는다(사용자 지시).
ARRIVAL_AIR_LEVELS = ("NORMAL", "BAD", "VERY_BAD")

# ── 근거·질문 문장(정해 둔 틀, 해요체·느낌표 없음 — docs/UX-문구-기준-2026-10-19.md) ──
SLEEP_REASON = "불을 끄셨네요. 밤이고 공기청정기가 켜져 있어요."
ARRIVAL_PREFIX = "다녀오셨어요."
ARRIVAL_AIR_SENTENCES = {
    "NORMAL": "실내 공기가 보통이에요.",
    "BAD": "실내 공기가 나빠요.",
    "VERY_BAD": "실내 공기가 매우 나빠요.",
}
DUST_SENTENCE = "황사 특보가 있어요."
PURIFIER_OFF_SENTENCE = "공기청정기가 꺼져 있어요."
DUST_REASON = "황사 특보가 났어요. " + PURIFIER_OFF_SENTENCE


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
        monotonic: Callable[[], float] | None = None,
        config: ContextRuleConfig | None = None,
    ) -> None:
        self._signals = signals
        self._offer = offer
        self._blocked = blocked
        self._air_card_recent = air_card_recent
        self._note_power_card = note_power_card
        self._monotonic = monotonic or time.monotonic
        self.config = config or ContextRuleConfig()
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

    def check_once(self) -> str:
        """결과 한 줄 — ``<규칙>:<결과>``를 ``,``로 이은 것, 또는 ``blocked:<이유>``. 카드를 만든 규칙이 있으면 거기서 끝."""
        with self._lock:
            outcome = self._check_locked()
            self.last_outcome = outcome
            return outcome

    # ── 판정 ──────────────────────────────────────────────────────────────
    def _check_locked(self) -> str:
        s = self._signals()
        self._track_dust(s.dust_warning)
        reason = self._blocked()
        if reason:
            return f"blocked:{reason}"
        outcomes = []
        for name, rule in (("sleep", self._rule_sleep), ("arrival", self._rule_arrival), ("dust", self._rule_dust)):
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
        if self._offer(RULE_SLEEP, SLEEP_REASON) is None:
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
        if air_sentence is None and not s.dust_warning:
            return "air_ok"
        if self._cooling(RULE_ARRIVAL, c.arrival_cooldown_s):
            return "cooldown"
        if self._air_card_recent():
            return "air_card_quiet"
        parts = [ARRIVAL_PREFIX]
        if air_sentence is not None:
            parts.append(air_sentence)
        if s.dust_warning:
            parts.append(DUST_SENTENCE)
        parts.append(PURIFIER_OFF_SENTENCE)
        if self._offer(RULE_ARRIVAL, " ".join(parts)) is None:
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
        if self._offer(RULE_DUST, DUST_REASON) is None:
            return "not_offered"
        self._dust_pending = False
        self._mark(RULE_DUST)
        self._note_power_card()
        return "offered"


def has_dust_warning(warnings) -> bool:
    """기상특보 목록(:func:`rpi.services.weather.warnings.active_warnings` 모양)에 황사가 있나."""
    return any(isinstance(w, Mapping) and (w.get("icon") == "dust" or w.get("kind") == "황사") for w in warnings or ())


__all__ = [
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
