"""루틴 트리거 → 제안 카드(approve) 또는 알림(notify). **실행하지 않는다.**

트리거 종류와 근거(시나리오 엔진과 같은 규칙):

- ``time``: 요일·시각. ``tick(now)``가 시각부터 ``TIME_WINDOW_MINUTES`` 안이면 그날
  한 번만 낸다(같은 루틴·같은 날·같은 시각). 서버가 그 창 동안 꺼져 있었으면 놓친다.
- ``approach``: 공간 상태 기계(``/presence/distance``·``/presence/arriving``)의 **전이**를
  본다. arrival=폰 귀가 신호, room=방 안(ROOM_PRESENT 이상), near=가전 앞(APPROACHING
  이상). 노드는 하나라 가전별 구역은 아직 없다(트리거의 가전은 기록용).
- ``after_done``: 가전 — 실제 실행이 L3(operation_confirmed)·상태 확인(state_confirmed)으로
  끝났을 때만 일반 카드, 모의 성공은 시연 카드, 그 밖은 무시. 끝 센서가 있는 가전
  (``SIMPLELAY_ROUTINE_DONE_SENSORS``, 2026-10-06 M2)은 L3 시작 확인이 아니라 사이클 끝(``appliance_done``)에서 깬다. 루틴 — 그 루틴의 실행이
  성공으로 끝났을 때(모의 단계가 섞였으면 시연 카드).
- ``event``: ThinQ 이벤트 이름(예: wash_complete). 모의 이벤트면 시연 카드.
- 버튼식 가전의 끝(``on_appliance_done``, 2026-10-06): RPi4가 CT 전력 하강 + 종료음을 융합한
  ``appliance_done``. 그 가전의 ``after_done`` 트리거와 같은 이름의 ``event`` 트리거를 깨운다.
  **두 입력이 다 맞을 때만(done_confirmed) '끝났어요'** — 하나뿐이면 '끝난 것 같아요, 확인해 주세요'로
  말하고 루틴의 안내 문장(끝났다고 단정하는 문장)을 읽지 않는다. 주입은 "(시연 주입)", 모의 입력은
  "(모의 입력)"을 붙인다.
- ``manual``: 앱의 '지금 실행' — 카드를 만든다. 실행은 여전히 승인 뒤다.

한 사이클에 한 번(2026-10-06 평가 B3): 같은 가전의 ``after_done``이 실행 끝(``on_job_finished``)으로 이미 깼으면 뒤이어
온 그 사이클의 ``appliance_done``(RPi5·RPi4 끝 센서 목록이 어긋났을 때, 또는 모의 실행 끝 + 리허설 주입)은 다시 깨우지
않는다. 또 그 가전을 돌린 루틴 자신은 그 사이클의 끝으로 깨우지 않는다(``on_job_finished``와 같은 자기 제외).

조건(``conditions``)은 트리거 시점에 본다. 만족하지 않으면 카드도 알림도 없다(기록만).
"""

from __future__ import annotations

import logging
import threading
from collections import deque
from datetime import datetime, timedelta

from rpi.commands import CommandStatus, Confirmation, ControlRoute
from rpi.controller.models import ExecutionMode

from .model import (
    MODE_LABELS,
    Routine,
    RoutineValidationError,
    compile_commands,
    parse_hhmm,
    parse_scenario_key,
)

log = logging.getLogger(__name__)

TIME_WINDOW_MINUTES = 10
KIND_ROUTINE_NOTICE = "routine_notice"

_ZONE_LEVEL = {"idle": 0, "room_present": 1, "approaching": 2, "at_device": 2}
_ZONE_NEEDS = {"room": 1, "near": 2}


class RoutineUnavailableError(RuntimeError):
    """지금은 이 루틴의 카드를 만들 수 없다(가전 미등록·준비 안 됨·부재·쉬는 중)."""


class RoutineEngine:
    def __init__(self, store, suggestions, service, clock, *, care_events=None,
                 presence_machine=None, environment_reader=None, runner=None,
                 done_sensors: frozenset = frozenset()) -> None:
        self._store = store
        #: 끝 센서(RPi4 사이클 끝)가 있는 가전 — 그 가전의 after_done은 시작 확인이 아니라 appliance_done에서 깬다(M2).
        self._done_sensors = done_sensors if not isinstance(done_sensors, (set, frozenset, list, tuple)) \
            else frozenset(done_sensors)
        #: 가전 → (이번 사이클을 돌린 루틴 ID 또는 None, after_done을 이미 깼나). 실행 끝에서 잡고 끝 알림에서 쓴다.
        self._cycles: dict[str, tuple[str | None, bool]] = {}
        self._suggestions = suggestions
        self._service = service
        self._clock = clock
        self._care = care_events
        self._presence = presence_machine
        self._environment = environment_reader
        self.runner = runner
        self._lock = threading.Lock()
        self._fired: dict[str, tuple] = {}
        self._seen_transitions = 0
        self._last_transition_key = None
        self._log: deque[dict] = deque(maxlen=50)

    # ── 제안 서비스·실행 서비스 연결 ─────────────────────────────────────────
    def current_commands(self, scenario_id: str) -> tuple:
        """승인 시 대조용: 카드의 지문이 지금 루틴과 같을 때만 지금 명령을 돌려준다."""
        key = parse_scenario_key(scenario_id)
        routine = self._store.get(key[0]) if key else None
        if (routine is None or not routine.enabled or routine.mode != "approve"
                or routine.steps_fingerprint()[:12] != key[1]):
            return ()
        try:
            return compile_commands(routine, self._registry())
        except RoutineValidationError:
            return ()

    def habit_routine(self, appliance_id, steps) -> tuple[str, str] | None:
        """습관 제안의 버튼 순서와 **똑같은** 단일 단계 루틴이 있으면 (ID, 이름).

        여러 단계 루틴(안내·기다리기 포함)은 고르지 않는다 -- 습관 카드는 그 버튼
        순서만 실행하므로 이름만 빌려 쓰면 사용자가 본 것과 할 일이 달라진다.
        """
        if appliance_id is None or not steps:
            return None
        registry = self._registry()
        for routine in self._store.list():
            if not routine.enabled or len(routine.steps) != 1:
                continue
            step = routine.steps[0]
            if step.kind != "press_sequence" or step.appliance_id != appliance_id:
                continue
            try:
                (command,) = compile_commands(routine, registry)
            except (RoutineValidationError, ValueError):
                continue
            if tuple(command.buttons) == tuple(steps):
                return routine.routine_id, routine.name
        return None

    # ── 트리거 ──────────────────────────────────────────────────────────────
    def tick(self, now: datetime | None = None) -> list:
        """주기 호출(main.py). 시각 트리거와 다가옴 트리거를 본다."""
        now = now or self._clock.now()
        fired = []
        for routine in self._store.list():
            trigger = routine.trigger
            if not routine.enabled or trigger.kind != "time" or now.weekday() not in trigger.days:
                continue
            at = parse_hhmm(trigger.time)
            scheduled = now.replace(hour=at.hour, minute=at.minute, second=0, microsecond=0)
            if not scheduled <= now < scheduled + timedelta(minutes=TIME_WINDOW_MINUTES):
                continue
            key = (now.date().isoformat(), trigger.time)
            with self._lock:
                if self._fired.get(routine.routine_id) == key:
                    continue
                self._fired[routine.routine_id] = key
            fired.append(self._fire(routine, f"{trigger.describe()} 시각이에요", False, "time"))
        for zone in self._approach_edges():
            for routine in self._store.list():
                trigger = routine.trigger
                if routine.enabled and trigger.kind == "approach" and trigger.zone == zone:
                    fired.append(self._fire(routine, trigger.describe() + " (공간 인식 — 레이더 실측 전)",
                                            False, "approach"))
        return [f for f in fired if f is not None]

    def on_job_finished(self, event) -> None:
        if event.status != CommandStatus.SUCCEEDED.value or event.appliance_id is None:
            return
        own = parse_scenario_key(event.scenario_id)
        with self._lock:
            # 새 사이클 — 이 실행을 낸 루틴(있으면)을 기억한다. after_done을 깨면 아래에서 True로 바꾼다.
            self._cycles[event.appliance_id] = (own[0] if own else None, False)
        if (event.execution_mode is ExecutionMode.REAL
                and event.confirmation in (Confirmation.OPERATION_CONFIRMED, Confirmation.STATE_CONFIRMED)):
            if event.appliance_id in self._done_sensors:
                return  # 끝 센서가 있으면 시작 확인으로 깨우지 않는다 — 사이클 끝(on_appliance_done)에서 한 번
            reason, is_demo = "동작을 확인했어요", False
        elif event.execution_mode is ExecutionMode.MOCK:
            reason, is_demo = "시연: 모의 실행이 끝났어요 — 실제 완료를 확인한 것은 아니에요", True
        else:
            return
        fired_any = False
        for routine in self._store.list():
            trigger = routine.trigger
            if (routine.enabled and trigger.kind == "after_done"
                    and trigger.appliance_id == event.appliance_id
                    and not (own and own[0] == routine.routine_id)):
                self._fire(routine, f"{self._name_of(event.appliance_id)} {reason}", is_demo, "after_done")
                fired_any = True
        if fired_any:
            with self._lock:
                self._cycles[event.appliance_id] = (own[0] if own else None, True)

    def on_routine_finished(self, run) -> None:
        if run.status.value != "succeeded":
            return
        for routine in self._store.list():
            trigger = routine.trigger
            if routine.enabled and trigger.kind == "after_done" and trigger.routine_id == run.routine_id:
                reason = f"'{run.routine_name}' 루틴이 끝났어요" + (" (시연: 모의 실행 포함)" if run.is_demo else "")
                self._fire(routine, reason, run.is_demo, "after_done")

    def on_thinq_event(self, record: dict) -> None:
        name = record.get("event")
        is_demo = record.get("execution_mode") != "real"
        for routine in self._store.list():
            trigger = routine.trigger
            if routine.enabled and trigger.kind == "event" and trigger.event == name:
                reason = f"가전 알림 '{name}'이 왔어요" + (" (시연: 모의 이벤트예요)" if is_demo else "")
                self._fire(routine, reason, is_demo, "event")

    def on_appliance_done(self, record: dict) -> list:
        """검증한 ``appliance_done`` 기록(`rpi.services.appliance_done.parse_appliance_done`)."""
        appliance_id = record["appliance_id"]
        event_name = record.get("event")
        confirmed = record.get("state") == "done_confirmed"
        source = record.get("source")
        noun = "세탁" if event_name == "wash_complete" else f"{self._name_of(appliance_id)} 동작"
        if confirmed:
            reason = f"{noun}이 끝났어요 (전력·종료음 둘 다 확인)"
        else:
            which = "전력 하강만" if record.get("inputs") == ["power"] else "종료음만"
            reason = f"{noun}이 끝난 것 같아요 — 확인해 주세요 ({which} 감지)"
        if source == "injected":
            reason += " (시연 주입)"
        elif source != "real":
            reason += " (모의 입력)"
        is_demo = source != "real"
        extra = {"confidence": "confirmed" if confirmed else "probable",
                 "inputs": list(record.get("inputs") or []), "input_source": source}
        with self._lock:
            # 이 사이클 정보는 한 번만 쓴다 — 다음 끝(우리 실행 없이 사람이 돌린 것)은 새 사이클이다.
            owner, already = self._cycles.pop(appliance_id, (None, False))
        fired = []
        for routine in self._store.list():
            trigger = routine.trigger
            if not routine.enabled:
                continue
            if trigger.kind == "after_done" and trigger.appliance_id == appliance_id:
                if already or routine.routine_id == owner:
                    # 같은 사이클의 실행 끝에서 이미 깼거나, 이 가전을 돌린 루틴 자신이다(평가 B3).
                    self._record(routine, "after_done", "skipped",
                                 "같은 사이클에서 이미 알렸거나 이 가전을 돌린 루틴이에요", **extra)
                    continue
                kind = "after_done"
            elif (trigger.kind == "event" and trigger.event == event_name
                  and trigger.appliance_id in (None, appliance_id)):
                kind = "event"
            else:
                continue
            fired.append(self._fire(routine, reason, is_demo, kind, probable=not confirmed, extra=extra))
        return [f for f in fired if f is not None]

    def trigger_manual(self, routine_id: str):
        """앱의 '지금 실행'. 승인 루틴은 카드를, 알림 루틴은 알림을 만든다."""
        routine = self._store.get(routine_id)
        if routine is None:
            raise KeyError(routine_id)
        if not routine.enabled:
            raise RoutineUnavailableError("꺼져 있는 루틴이에요 — 켠 뒤 다시 시도해 주세요")
        return self._fire(routine, "직접 실행을 눌렀어요", False, "manual", raise_unavailable=True,
                          check_conditions=False)

    # ── 다음 실행 ────────────────────────────────────────────────────────────
    def next_runs(self, now: datetime | None = None, limit: int = 3) -> list[dict]:
        now = now or self._clock.now()
        upcoming = []
        for routine in self._store.list():
            trigger = routine.trigger
            if not routine.enabled or trigger.kind != "time":
                continue
            at = parse_hhmm(trigger.time)
            for offset in range(8):
                day = now + timedelta(days=offset)
                if day.weekday() not in trigger.days:
                    continue
                when = day.replace(hour=at.hour, minute=at.minute, second=0, microsecond=0)
                if when <= now:
                    continue
                upcoming.append({"routine_id": routine.routine_id, "name": routine.name,
                                 "icon": routine.icon, "at": when.isoformat(),
                                 "when": trigger.describe(), "mode": routine.mode,
                                 "mode_label": MODE_LABELS[routine.mode]})
                break
        upcoming.sort(key=lambda item: item["at"])
        return upcoming[:limit]

    def recent_log(self) -> list[dict]:
        with self._lock:
            return list(reversed(self._log))

    # ── 내부 ────────────────────────────────────────────────────────────────
    def _registry(self):
        return getattr(self._service, "_appliance_registry", None)

    def _name_of(self, appliance_id: str) -> str:
        registry = self._registry()
        appliance = registry.get(appliance_id) if registry is not None else None
        return appliance.name if appliance is not None else appliance_id

    def _approach_edges(self) -> list[str]:
        machine = self._presence
        if machine is None:
            return []
        history = machine.history()
        key = (history[-1].at_s, history[-1].reason) if history else None
        with self._lock:
            if key == self._last_transition_key:
                return []
            # 기록은 최대 100건 링이라 개수로는 새 전이를 못 센다 -- 마지막으로 본 전이 뒤만 본다.
            last = self._last_transition_key
            self._last_transition_key = key
        start = 0
        if last is not None:
            for index in range(len(history) - 1, -1, -1):
                if (history[index].at_s, history[index].reason) == last:
                    start = index + 1
                    break
        zones = []
        for transition in history[start:]:
            if transition.reason == "arrival_hint":
                zones.append("arrival")
                continue
            before = _ZONE_LEVEL.get(transition.previous.value, 0)
            after = _ZONE_LEVEL.get(transition.current.value, 0)
            for zone, need in _ZONE_NEEDS.items():
                if before < need <= after:
                    zones.append(zone)
        return list(dict.fromkeys(zones))

    def _conditions_met(self, routine: Routine) -> tuple[bool, str]:
        now = self._clock.now()
        for condition in routine.conditions:
            if condition.kind == "time_window":
                start, end = parse_hhmm(condition.start), parse_hhmm(condition.end)
                t = now.time().replace(second=0, microsecond=0)
                inside = start <= t < end if start < end else (t >= start or t < end)
                if not inside:
                    return False, f"{condition.start}~{condition.end} 시간대가 아니에요"
            elif condition.kind == "environment":
                reading = None
                if self._environment is not None:
                    try:
                        reading = self._environment()
                    except Exception:  # noqa: BLE001
                        reading = None
                temperature, humidity = reading if reading else (None, None)
                if temperature is None and humidity is None:
                    return False, "온습도를 읽지 못했어요"
                hot = (condition.temperature_at_least is not None and temperature is not None
                       and temperature >= condition.temperature_at_least)
                humid = (condition.humidity_at_least is not None and humidity is not None
                         and humidity >= condition.humidity_at_least)
                if not (hot or humid):
                    return False, "온습도 기준을 넘지 않았어요"
        return True, ""

    def _record(self, routine: Routine, source: str, outcome: str, detail: str = "", **extra) -> dict:
        entry = {"at": self._clock.now().isoformat(), "routine_id": routine.routine_id,
                 "routine_name": routine.name, "trigger": source, "outcome": outcome,
                 "detail": detail, **extra}
        with self._lock:
            self._log.append(entry)
        return entry

    def _fire(self, routine: Routine, reason: str, is_demo: bool, source: str, *,
              raise_unavailable: bool = False, check_conditions: bool = True,
              probable: bool = False, extra: dict | None = None):
        extra = extra or {}
        if check_conditions:
            ok, why = self._conditions_met(routine)
            if not ok:
                self._record(routine, source, "skipped", why, **extra)
                return None
        line = f"루틴 '{routine.name}' · {reason}"
        if routine.mode == "notify":
            return self._notify(routine, line, source, probable=probable, extra=extra)
        try:
            return self._offer(routine, line, is_demo, source, extra=extra)
        except RoutineUnavailableError as exc:
            self._record(routine, source, "unavailable", str(exc), **extra)
            if raise_unavailable:
                raise
            return None

    def _notify(self, routine: Routine, line: str, source: str, *, probable: bool = False,
                extra: dict | None = None):
        # 확신이 없으면(입력 하나만) 루틴의 안내 문장을 읽지 않는다 — '끝났어요'라고 단정하는 문장일 수 있다.
        notices = [] if probable else [s.text for s in routine.steps if s.kind == "announce"]
        message = line + (f" — {' / '.join(notices)}" if notices else "")
        if self._care is not None:
            self._care.append(KIND_ROUTINE_NOTICE, message, purpose=routine.name)
        return self._record(routine, source, "notified", message, **(extra or {}))

    def _offer(self, routine: Routine, reason: str, is_demo: bool, source: str, *,
               extra: dict | None = None):
        absent = getattr(self._suggestions, "presence_absent", None)
        if not is_demo and absent is not None and absent():
            raise RoutineUnavailableError("지금은 자리에 안 계셔서 제안을 만들지 않았어요")
        try:
            commands = compile_commands(routine, self._registry())
        except RoutineValidationError as exc:
            raise RoutineUnavailableError(str(exc)) from exc
        problems = []
        for command in commands:
            if command.route is ControlRoute.THINQ:
                readiness = self._service.thinq_readiness(command.target_id)
                if not readiness.can_execute:
                    problems.extend(readiness.reasons or ("ThinQ 가전이 준비되지 않았어요",))
        if problems:
            raise RoutineUnavailableError(" · ".join(problems))
        summaries = tuple(self._service.summary_of(c) for c in commands)
        suggestion = self._suggestions.create_scenario_suggestion(
            scenario_id=routine.scenario_key(), purpose=f"'{routine.name}' 루틴을 실행할까요?",
            commands=commands, summaries=summaries, reason=reason, is_demo=is_demo,
            routine_id=routine.routine_id, routine_name=routine.name, time_band="루틴",
            # '지금 실행'은 사용자가 직접 요청한 것 — 조용한 시간에도 카드를 만든다(실행은 여전히 승인 뒤, 2026-10-14).
            user_started=source == "manual",
        )
        if suggestion is None:
            raise RoutineUnavailableError("지금은 제안을 쉬는 중이거나 이 제안을 그만 받기로 하셨어요")
        self._record(routine, source, "offered", reason, suggestion_id=suggestion.suggestion_id,
                     **(extra or {}))
        return suggestion
