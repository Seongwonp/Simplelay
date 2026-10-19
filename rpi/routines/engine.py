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
  말하고 루틴의 안내 문장(끝났다고 단정하는 문장)을 읽지 않는다. 주입은 "연습으로 넣은 신호예요.", 모의 입력은
  "연습 신호예요."를 붙인다.
- ``manual``: 앱의 '지금 실행' — 카드를 만든다. 실행은 여전히 승인 뒤다.

한 사이클에 한 번(2026-10-06 평가 B3): 같은 가전의 ``after_done``이 실행 끝(``on_job_finished``)으로 이미 깼으면 뒤이어
온 그 사이클의 ``appliance_done``(RPi5·RPi4 끝 센서 목록이 어긋났을 때, 또는 모의 실행 끝 + 리허설 주입)은 다시 깨우지
않는다. 또 그 가전을 돌린 루틴 자신은 그 사이클의 끝으로 깨우지 않는다(``on_job_finished``와 같은 자기 제외).

조건(``conditions``)은 트리거 시점에 본다. 만족하지 않으면 카드도 알림도 없다(기록만).
"""

from __future__ import annotations

import json
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
#: 시각 루틴이 이미 띄운 회차(루틴 ID → [날짜, 시각]) — 서버 DB 설정 한 칸(2026-10-16 결함 ①).
FIRED_SETTING = "routine_time_fired"
KIND_ROUTINE_NOTICE = "routine_notice"
#: '다음 루틴' 한 번 건너뛰기(2026-10-18) — 루틴 ID → 건너뛸 회차 시각(ISO). 루틴마다 한 회차뿐. 서버 DB 설정 한 칸.
SKIP_SETTING = "routine_skip_next"
#: 건너뛴 회차의 기록 말(루틴 기록·자동 실행 기록) — 그 회차 시각에 쓰므로 늘 '오늘'이다.
SKIP_REASON = "오늘은 건너뛰기로 해서 안 했어요"

_ZONE_LEVEL = {"idle": 0, "room_present": 1, "approaching": 2, "at_device": 2}
_ZONE_NEEDS = {"room": 1, "near": 2}


class RoutineUnavailableError(RuntimeError):
    """지금은 이 루틴의 카드를 만들 수 없다(가전 미등록·준비 안 됨·부재·쉬는 중)."""


class RoutineSkipError(Exception):
    """'다음 루틴 건너뛰기'를 받을 수 없다 — ``status``(HTTP)와 화면에 그대로 보여도 되는 ``message``."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


SKIP_PAST_DETAIL = "이미 지난 회차라 바꿀 수 없어요 — 지금 하고 있으면 정지를 눌러 주세요"
SKIP_CHANGED_DETAIL = "다음 회차가 바뀌었어요 — 화면을 새로 고친 뒤 다시 눌러 주세요"
SKIP_NO_NEXT_DETAIL = "켜진 시각 루틴만 건너뛸 수 있어요"


def _parse_at(value) -> datetime | None:
    try:
        return datetime.fromisoformat(value) if isinstance(value, str) else None
    except ValueError:
        return None


def _same_instant(a: datetime | None, b: datetime | None) -> bool:
    if a is None or b is None:
        return False
    try:
        return a == b
    except TypeError:
        return False


_WEEKDAYS = "월화수목금토일"


def _day_label(when: datetime, now: datetime) -> str:
    days = (when.date() - now.date()).days
    if days == 0:
        return "오늘"
    if days == 1:
        return "내일"
    return f"{_WEEKDAYS[when.weekday()]}요일"


class RoutineEngine:
    def __init__(self, store, suggestions, service, clock, *, care_events=None,
                 presence_machine=None, environment_reader=None, runner=None,
                 done_sensors: frozenset = frozenset(), auto_rules=None) -> None:
        self._store = store
        #: 자동 실행 허용 규칙 엔진을 돌려주는 함수(2026-10-16 시각 규칙). 없으면 시각 트리거는 늘 카드다.
        self._auto_rules = auto_rules
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
        #: 저장 잠금(검토 2026-10-19 #8) — 스냅숏과 저장을 함께 줄 세운다. 예전에는 저장이 잠금 밖이라 동시 요청이면 먼저
        #: 찍은 옛 스냅숏이 나중에 저장될 수 있었다. ``_lock``은 DB를 기다리는 동안 쥐지 않는다(``tick``·화면 읽기가 막히지 않게).
        self._persist_lock = threading.Lock()
        self._fired: dict[str, tuple] = {}
        #: '이 회차는 이미 띄웠다'를 남기는 저장소(2026-10-16 결함 ①) — 없으면 메모리만(재시작하면 10분 창 안에서
        #: 같은 카드가 다시 떴다). restore_fired로 연결한다.
        self._save_fired = None
        #: 한 번 건너뛸 회차(루틴 ID → ISO 시각, 2026-10-18). restore_skips로 DB에 잇는다.
        self._skips: dict[str, str] = {}
        self._save_skips = None
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

    def restore_fired(self, load, save) -> None:
        """재시작 뒤에도 같은 날 같은 시각 회차를 다시 띄우지 않게 저장값을 읽고 저장 함수를 건다. 깨진 값은 버린다."""
        try:
            raw = json.loads(load(FIRED_SETTING) or "{}")
            restored = {str(k): (str(v[0]), str(v[1])) for k, v in raw.items()
                        if isinstance(v, list) and len(v) == 2}
        except (ValueError, TypeError, AttributeError):
            restored = {}
        with self._lock:
            restored.update(self._fired)
            self._fired = restored
            self._save_fired = save

    def _persist_fired(self) -> None:
        save = self._save_fired
        if save is None:
            return
        with self._persist_lock:
            with self._lock:
                snapshot = json.dumps({k: list(v) for k, v in self._fired.items()})
            try:
                save(FIRED_SETTING, snapshot)
            except Exception:  # noqa: BLE001 — 저장 실패로 카드를 막지 않는다(메모리 기억은 남는다)
                log.exception("routine fired occurrence save failed")

    # ── 다음 회차 한 번 건너뛰기(2026-10-18) ──────────────────────────────────
    def restore_skips(self, load, save) -> None:
        """재시작 뒤에도 '이 회차는 건너뛴다'가 남게 저장값을 읽고 저장 함수를 건다. 깨진 값은 버린다."""
        try:
            raw = json.loads(load(SKIP_SETTING) or "{}")
            restored = {str(k): str(v) for k, v in raw.items() if _parse_at(v) is not None}
        except (ValueError, TypeError, AttributeError):
            restored = {}
        with self._lock:
            restored.update(self._skips)
            self._skips = restored
            self._save_skips = save

    def _persist_skips(self) -> None:
        save = self._save_skips
        if save is None:
            return
        with self._persist_lock:  # 스냅숏과 저장을 함께(검토 2026-10-19 #8) — 마지막 저장이 늘 마지막 상태
            with self._lock:
                snapshot = json.dumps(self._skips)
            try:
                save(SKIP_SETTING, snapshot)
            except Exception:  # noqa: BLE001 — 저장 실패는 기록만(메모리 기억은 남는다)
                log.exception("routine skip save failed")

    def _prune_skips_locked(self, now: datetime) -> bool:
        """회차 시각 + 창이 지난 건너뛰기는 버린다(그 회차는 이미 지나 의미가 없다 — 꺼진 루틴 등으로 쓰이지 않은 것)."""
        stale = []
        for routine_id, raw in self._skips.items():
            at = _parse_at(raw)
            try:
                if at is None or at + timedelta(minutes=TIME_WINDOW_MINUTES) <= now:
                    stale.append(routine_id)
            except TypeError:
                stale.append(routine_id)
        for routine_id in stale:
            del self._skips[routine_id]
        return bool(stale)

    @staticmethod
    def _next_occurrence(routine: Routine, now: datetime) -> datetime | None:
        """켜진 시각 루틴의 다음 회차(지금보다 뒤). 없으면 None."""
        trigger = routine.trigger
        if not routine.enabled or trigger.kind != "time":
            return None
        at = parse_hhmm(trigger.time)
        for offset in range(8):
            day = now + timedelta(days=offset)
            if day.weekday() not in trigger.days:
                continue
            when = day.replace(hour=at.hour, minute=at.minute, second=0, microsecond=0)
            if when > now:
                return when
        return None

    def set_skip(self, routine_id, at_value, skip: bool, now: datetime | None = None) -> dict:
        """``/routines/next``가 준 회차(``at``) 한 번만 건너뛴다(``skip=False``면 되돌린다). 같은 요청을 다시 해도 같다.

        지난 회차(이미 시작한 회차 포함)·다음 회차와 다른 시각은 거절한다 — 건너뛰기는 이미 시작한 실행을 멈추지 않는다
        (정지는 ``/stop``). 판정과 저장은 ``tick``의 '이 회차를 띄웠다' 표시와 같은 잠금 안에서 한다(경계에서 둘 다
        일어나지 않게). 돌려주는 값은 그 루틴의 ``/routines/next`` 항목."""
        routine = self._store.get(routine_id) if isinstance(routine_id, str) and routine_id else None
        if routine is None:
            raise RoutineSkipError(404, "루틴을 찾을 수 없어요")
        at = _parse_at(at_value)
        if at is None:
            raise RoutineSkipError(422, "회차 시각은 '다음 루틴'이 준 값 그대로 보내 주세요")
        with self._lock:
            now = now or self._clock.now()
            try:
                past = at <= now
            except TypeError:  # 시간대 표기가 다르다 — 우리가 준 값이 아니다
                raise RoutineSkipError(409, SKIP_CHANGED_DETAIL) from None
            started = self._fired.get(routine.routine_id) == (at.date().isoformat(), routine.trigger.time)
            if past or started:
                raise RoutineSkipError(409, SKIP_PAST_DETAIL)
            expected = self._next_occurrence(routine, now)
            if expected is None:
                raise RoutineSkipError(409, SKIP_NO_NEXT_DETAIL)
            if not _same_instant(expected, at):
                raise RoutineSkipError(409, SKIP_CHANGED_DETAIL)
            self._prune_skips_locked(now)
            if skip:
                self._skips[routine.routine_id] = expected.isoformat()
            else:
                self._skips.pop(routine.routine_id, None)
        self._persist_skips()
        item = next((i for i in self.next_runs(now=now, limit=10_000) if i["routine_id"] == routine.routine_id), None)
        if item is None:  # 그 사이 루틴이 꺼졌다
            raise RoutineSkipError(409, SKIP_NO_NEXT_DETAIL)
        return item

    def _skip_time(self, routine: Routine, scheduled: datetime) -> None:
        """건너뛰기로 한 회차 — 카드도 자동 실행도 없이 기록만 남긴다(루틴 기록, 시각 규칙이 켜져 있으면 자동 실행 기록도)."""
        self._record(routine, "time", "skipped", SKIP_REASON, scheduled_at=scheduled.isoformat())
        if self._auto_rules is None:
            return
        try:
            engine = self._auto_rules()
            if engine is not None:
                engine.on_time_skipped(routine, scheduled, SKIP_REASON)
        except Exception:  # noqa: BLE001 — 기록 실패로 건너뛰기를 바꾸지 않는다(실행하지 않는 쪽)
            log.exception("recording the skipped time occurrence failed")

    # ── 트리거 ──────────────────────────────────────────────────────────────
    def tick(self, now: datetime | None = None) -> list:
        """주기 호출(main.py). 시각 트리거와 다가옴 트리거를 본다."""
        now = now or self._clock.now()
        fired = []
        with self._lock:
            pruned = bool(self._skips) and self._prune_skips_locked(now)
        if pruned:
            self._persist_skips()
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
                previous = self._fired.get(routine.routine_id)
                if previous == key:
                    continue
                # 메모리에만 먼저 잡아 둔다(같은 회차를 두 번 띄우지 않게). 저장은 결과가 난 뒤 — 그 사이 예외가 나면 되돌려
                # 같은 창 안의 다음 확인에서 다시 띄운다(검토 10/19 #4: 예전에는 먼저 저장해 카드 없이 회차가 영영 쓰였다).
                self._fired[routine.routine_id] = key
                # '다음 루틴 건너뛰기'(2026-10-18) — 이 회차를 건너뛰기로 했으면 카드·자동 실행 없이 기록만. 한 번 쓰고 지운다.
                skip_raw = self._skips.get(routine.routine_id)
                skipped = _same_instant(_parse_at(skip_raw), scheduled)
                if skipped:
                    del self._skips[routine.routine_id]
            try:
                if skipped:
                    self._skip_time(routine, scheduled)
                elif not self._auto_time(routine, scheduled, now):
                    # 허용한 시각 규칙이 맡지 않았다(맡았으면 보냄·막힘·중복 — 카드를 만들지 않는다).
                    fired.append(self._fire(routine, f"{trigger.describe()} 시각이에요", False, "time"))
            except Exception:  # noqa: BLE001 — 이 회차는 쓰지 않은 것으로 되돌리고 다른 루틴은 계속 본다
                log.exception("time occurrence of routine %s failed; it stays unfired", routine.routine_id)
                with self._lock:
                    if self._fired.get(routine.routine_id) == key:
                        if previous is None:
                            self._fired.pop(routine.routine_id, None)
                        else:
                            self._fired[routine.routine_id] = previous
                    if skipped:
                        self._skips.setdefault(routine.routine_id, skip_raw)
                continue
            self._persist_fired()
            if skipped:
                self._persist_skips()
        for zone in self._approach_edges():
            for routine in self._store.list():
                trigger = routine.trigger
                if routine.enabled and trigger.kind == "approach" and trigger.zone == zone:
                    fired.append(self._fire(routine, trigger.describe() + " (공간 인식 — 레이더 실측 전)",
                                            False, "approach"))
        return [f for f in fired if f is not None]

    def _auto_time(self, routine: Routine, scheduled: datetime, now: datetime) -> bool:
        """정해진 시각 — 켜진 시각 규칙이 맡았으면 True(카드 없음). 규칙이 없거나 늦음·허용 전·재시작 전·무효로 카드로
        물어야 하면 False. 규칙 엔진 오류는 기록하고 카드로(승인 필요) 돌아간다. 자리 비움 확인은 하지 않는다(사용자가
        허용한 시각 동작)."""
        if self._auto_rules is None:
            return False
        try:
            engine = self._auto_rules()
            entries = engine.on_time_due(routine, scheduled, now) if engine is not None else []
        except Exception:  # noqa: BLE001
            log.exception("time auto rule failed; falling back to the card")
            return False
        handled = [e for e in entries if not e.get("reoffer")]
        if not handled:
            return False
        first = handled[0]
        self._record(routine, "time", "auto", first.get("reason") or "",
                     auto_outcome=first.get("outcome"), job_id=first.get("job_id"))
        return True

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
            reason, is_demo = "연습 실행이 끝났어요. 실제로 끝났는지는 몰라요.", True
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
                reason = f"'{run.routine_name}' 루틴이 끝났어요." + (" 연습 실행이 들어 있어요." if run.is_demo else "")
                self._fire(routine, reason, run.is_demo, "after_done")

    def on_thinq_event(self, record: dict) -> None:
        name = record.get("event")
        is_demo = record.get("execution_mode") != "real"
        for routine in self._store.list():
            trigger = routine.trigger
            if routine.enabled and trigger.kind == "event" and trigger.event == name:
                reason = f"가전 알림 '{name}'이 왔어요." + (" 연습 알림이에요." if is_demo else "")
                self._fire(routine, reason, is_demo, "event")

    def on_appliance_done(self, record: dict) -> list:
        """검증한 ``appliance_done`` 기록(`rpi.services.appliance_done.parse_appliance_done`)."""
        appliance_id = record["appliance_id"]
        event_name = record.get("event")
        confirmed = record.get("state") == "done_confirmed"
        source = record.get("source")
        noun = "세탁" if event_name == "wash_complete" else f"{self._name_of(appliance_id)} 동작"
        # 10/18 쉬운 말: 결과 한 줄 + 할 일 한 줄. 근거(전력·종료음)는 ``extra``(confidence·inputs)에 남는다.
        if confirmed:
            reason = f"{noun}이 끝났어요."
        else:
            reason = f"{noun}이 끝난 것 같아요. 다 됐는지 봐 주세요."
        if source == "injected":
            reason += " 연습으로 넣은 신호예요."
        elif source != "real":
            reason += " 연습 신호예요."
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
        """켜진 시각 루틴의 가까운 회차. ``auto``: 허용한 시각 규칙이 켜져 카드 없이 실행한다(외부 평가 10/16 p02 —
        아래 줄의 '자동 실행 켜짐'과 같은 말). ``day_label``: 오늘·내일·요일.

        건너뛰기(2026-10-18): ``skipped``(이 회차는 건너뛴다)·``skip_label``('오늘은 건너뛰어요', 아니면 None)·
        ``skip_action_label``(단추 말 '오늘은 건너뛰기'). 건너뛴 회차도 지나기 전까지는 그대로 보인다(되돌리기)."""
        now = now or self._clock.now()
        upcoming = []
        try:
            rules = self._auto_rules() if self._auto_rules is not None else None
        except Exception:  # noqa: BLE001 — 표시용이다. 모르면 승인으로 보인다(더 보수적)
            rules = None
        with self._lock:
            skips = dict(self._skips)
        for routine in self._store.list():
            when = self._next_occurrence(routine, now)
            if when is None:
                continue
            try:
                auto = bool(rules is not None and routine.mode == "approve"
                            and rules.time_rule_on(routine.routine_id))
            except Exception:  # noqa: BLE001
                auto = False
            day = _day_label(when, now)  # 오늘·내일·○요일 — 모두 받침이 있어 '은'
            skipped = _same_instant(_parse_at(skips.get(routine.routine_id)), when)
            upcoming.append({"routine_id": routine.routine_id, "name": routine.name,
                             "icon": routine.icon, "at": when.isoformat(),
                             "when": routine.trigger.describe(), "mode": routine.mode,
                             "mode_label": "자동 실행" if auto else MODE_LABELS[routine.mode],
                             "auto": auto, "day_label": day,
                             "skipped": skipped, "skip_label": f"{day}은 건너뛰어요" if skipped else None,
                             "skip_action_label": f"{day}은 건너뛰기"})
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
