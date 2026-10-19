"""사용자 루틴 — 값 객체·검증·지문 (2026-09-30).

루틴 = 이름 + 단계들 + 언제(트리거) + 조건 + 실행 방식. 고정 명령 버튼("즉석밥")을
없애고 사용자가 만든 루틴이 메뉴가 된다(docs/UI-확정-2026-09-30.md §1).

- **실행 방식** ``approve``: 트리거가 오면 제안 카드를 만든다. 실행은 사용자가 카드를
  승인한 뒤에만 일어나고, 승인은 그 순간의 단계 지문에 묶인다(편집하면 재승인).
  ``notify``: 알림(보호자 알림함의 기록)만 남긴다. **어떤 경우에도 실행하지 않는다.**
- **단계** ``press_sequence``(사진 조작부의 버튼 순서) · ``thinq_command``(U1 명령 계약)
  · ``announce``(안내 문장 — 시간 알림까지이며 의료 판단은 하지 않는다)
  · ``wait_until_done``(앞 단계의 확인 결과를 보고 다음으로 넘어갈지 정한다).
- **트리거** ``time`` · ``approach`` · ``after_done`` · ``event`` · ``manual``.

이 모듈은 가전 등록부 없이도 검사할 수 있는 **구조 검증**과, 등록부를 받아 하는
**가전 검증**(버튼이 사진 조작부에 있는가, ThinQ 동작이 허용되는가)을 나눠 둔다.
템플릿은 구조 검증만 통과하면 된다(사용자 가전이 아직 없을 수 있다).

오류 메시지는 화면에 그대로 보일 수 있는 한국어 문장이다(HTTP 422 detail).
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field, replace
from datetime import datetime, time as dtime

from rpi.commands import ArgumentError, Command, ControlRoute, canonical_json, normalize_args
from rpi.josa import quoted_josa, with_josa

#: 저장 문서의 형식 번호. 올리면 ``migrate_document``에 한 단계를 더한다.
SCHEMA_VERSION = 1

STEP_KINDS = ("press_sequence", "thinq_command", "announce", "wait_until_done")
DEVICE_STEP_KINDS = ("press_sequence", "thinq_command")
TRIGGER_KINDS = ("time", "approach", "after_done", "event", "manual")
CONDITION_KINDS = ("time_window", "environment")
MODES = ("approve", "notify")
APPROACH_ZONES = ("arrival", "room", "near")

MAX_NAME_LEN = 30
MAX_ICON_LEN = 24
MAX_STEPS = 10
MAX_CONDITIONS = 4
MAX_ANNOUNCE_LEN = 80
MAX_NOTE_LEN = 60
MAX_ID_LEN = 64

MODE_LABELS = {"approve": "승인 후 실행", "notify": "알림만"}
WEEKDAY_LABELS = ("월", "화", "수", "목", "금", "토", "일")

_TIME = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
_EVENT = re.compile(r"^[a-z][a-z0-9_]{0,39}$")


class RoutineValidationError(ValueError):
    """루틴이 규칙에 맞지 않는다. 메시지는 사용자에게 보일 문장이다(422)."""


def _fail(message: str) -> None:
    raise RoutineValidationError(message)


def _text(value, what: str, limit: int, *, required: bool = True) -> str | None:
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            _fail(f"{with_josa(what, '을', '를')} 적어 주세요")
        return None
    if not isinstance(value, str):
        _fail(f"{with_josa(what, '은', '는')} 글자여야 해요")
    value = value.strip()
    if len(value) > limit:
        _fail(f"{with_josa(what, '은', '는')} {limit}자 이내로 적어 주세요 (지금 {len(value)}자)")
    return value


def _ident(value, what: str) -> str:
    text = _text(value, what, MAX_ID_LEN)
    assert text is not None
    return text


def parse_hhmm(value, what: str = "시각") -> dtime:
    if not isinstance(value, str) or not _TIME.fullmatch(value.strip()):
        _fail(f"{with_josa(what, '은', '는')} 07:30처럼 24시간 형식으로 적어 주세요")
    hour, minute = value.strip().split(":")
    return dtime(int(hour), int(minute))


# ── 단계 ────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class RoutineStep:
    kind: str
    appliance_id: str | None = None
    #: press_sequence — 사진 조작부에 기록된 버튼 ID 또는 이름(적은 그대로 저장).
    buttons: tuple[str, ...] = ()
    #: thinq_command
    action: str | None = None
    args: tuple = ()
    #: announce
    text: str | None = None
    note: str | None = None

    def to_dict(self) -> dict:
        data: dict = {"kind": self.kind}
        if self.appliance_id is not None:
            data["appliance_id"] = self.appliance_id
        if self.kind == "press_sequence":
            data["buttons"] = list(self.buttons)
        if self.kind == "thinq_command":
            data["action"] = self.action
            data["args"] = dict(self.args)
        if self.kind == "announce":
            data["text"] = self.text
        if self.note:
            data["note"] = self.note
        return data

    @classmethod
    def from_dict(cls, data, index: int = 0) -> "RoutineStep":
        where = f"{index + 1}번째 단계"
        if not isinstance(data, dict):
            _fail(f"{where}의 형식이 맞지 않아요")
        kind = data.get("kind")
        if kind not in STEP_KINDS:
            _fail(f"{where}의 종류를 알 수 없어요 (버튼 누르기·ThinQ 명령·안내·완료 기다리기 중 하나)")
        note = _text(data.get("note"), f"{where}의 메모", MAX_NOTE_LEN, required=False)
        if kind == "press_sequence":
            appliance = _ident(data.get("appliance_id"), f"{where}의 가전")
            buttons = data.get("buttons")
            if not isinstance(buttons, (list, tuple)) or not buttons:
                _fail(f"{where}: 누를 버튼을 하나 이상 골라 주세요")
            cleaned = []
            for b in buttons:
                if not isinstance(b, str) or not b.strip():
                    _fail(f"{where}: 빈 버튼 이름이 있어요")
                cleaned.append(b.strip())
            return cls(kind, appliance, buttons=tuple(cleaned), note=note)
        if kind == "thinq_command":
            appliance = _ident(data.get("appliance_id"), f"{where}의 가전")
            action = data.get("action")
            args = data.get("args") or {}
            if not isinstance(action, str) or not _EVENT.fullmatch(action):
                _fail(f"{where}: ThinQ 동작 이름을 골라 주세요 (예: set_power)")
            if not isinstance(args, dict):
                _fail(f"{where}: 명령 인자 형식이 맞지 않아요")
            try:
                Command.thinq(appliance, action, args)
                normalized = normalize_args(args)
            except (ArgumentError, ValueError) as exc:
                _fail(f"{where}: ThinQ 명령이 규칙에 맞지 않아요 ({exc})")
            return cls(kind, appliance, action=action, args=normalized, note=note)
        if kind == "announce":
            text = _text(data.get("text"), f"{where}의 안내 문장", MAX_ANNOUNCE_LEN)
            return cls(kind, text=text, note=note)
        appliance = _ident(data.get("appliance_id"), f"{where}에서 기다릴 가전")
        return cls(kind, appliance, note=note)

    @property
    def is_device_step(self) -> bool:
        return self.kind in DEVICE_STEP_KINDS


# ── 트리거·조건 ───────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class RoutineTrigger:
    kind: str
    #: time — 요일(0=월 … 6=일), "HH:MM"
    days: tuple[int, ...] = ()
    time: str | None = None
    #: approach — arrival(폰 귀가 신호) · room(방 안) · near(가전 앞)
    zone: str | None = None
    #: approach(참고용)·after_done·event
    appliance_id: str | None = None
    #: after_done — 다른 루틴이 끝난 뒤
    routine_id: str | None = None
    #: event — ThinQ 이벤트 이름(예: wash_complete)
    event: str | None = None

    def to_dict(self) -> dict:
        data: dict = {"kind": self.kind}
        if self.kind == "time":
            data["days"] = list(self.days)
            data["time"] = self.time
        if self.zone is not None:
            data["zone"] = self.zone
        if self.appliance_id is not None:
            data["appliance_id"] = self.appliance_id
        if self.routine_id is not None:
            data["routine_id"] = self.routine_id
        if self.event is not None:
            data["event"] = self.event
        return data

    @classmethod
    def from_dict(cls, data) -> "RoutineTrigger":
        if data is None:
            return cls("manual")
        if not isinstance(data, dict):
            _fail("'언제' 형식이 맞지 않아요")
        kind = data.get("kind")
        if kind not in TRIGGER_KINDS:
            _fail("'언제'의 종류를 알 수 없어요 (시각·다가오면·끝난 뒤·가전 알림·직접 실행 중 하나)")
        if kind == "time":
            days = data.get("days")
            if not isinstance(days, (list, tuple)) or not days:
                _fail("요일을 하나 이상 골라 주세요")
            if any(isinstance(d, bool) or not isinstance(d, int) or not 0 <= d <= 6 for d in days):
                _fail("요일은 0(월)부터 6(일)까지의 숫자로 보내 주세요")
            parse_hhmm(data.get("time"))
            return cls("time", days=tuple(sorted(set(days))), time=data["time"].strip())
        if kind == "approach":
            zone = data.get("zone", "near")
            if zone not in APPROACH_ZONES:
                _fail("다가오는 곳은 귀가(arrival)·방 안(room)·가전 앞(near) 중에서 골라 주세요")
            appliance = data.get("appliance_id")
            return cls("approach", zone=zone,
                       appliance_id=_ident(appliance, "가전") if appliance is not None else None)
        if kind == "after_done":
            appliance = data.get("appliance_id")
            routine = data.get("routine_id")
            if (appliance is None) == (routine is None):
                _fail("'끝난 뒤'는 가전 하나 또는 루틴 하나를 골라 주세요")
            return cls("after_done",
                       appliance_id=_ident(appliance, "가전") if appliance is not None else None,
                       routine_id=_ident(routine, "루틴") if routine is not None else None)
        if kind == "event":
            event = data.get("event")
            if not isinstance(event, str) or not _EVENT.fullmatch(event):
                _fail("가전 알림 이름을 골라 주세요 (예: wash_complete)")
            appliance = data.get("appliance_id")
            return cls("event", event=event,
                       appliance_id=_ident(appliance, "가전") if appliance is not None else None)
        return cls("manual")

    def describe(self, routine_names: dict[str, str] | None = None) -> str:
        """화면 '언제' 줄. 예: '평일 07:30', '세탁기 세탁 완료 알림이 오면'."""
        if self.kind == "time":
            if self.days == tuple(range(7)):
                days = "매일"
            elif self.days == tuple(range(5)):
                days = "평일"
            elif self.days == (5, 6):
                days = "주말"
            else:
                days = "·".join(WEEKDAY_LABELS[d] for d in self.days)
            return f"{days} {self.time}"
        if self.kind == "approach":
            return {"arrival": "집에 도착할 때", "room": "방에 들어오면",
                    "near": "가전 앞에 오면"}[self.zone or "near"]
        if self.kind == "after_done":
            if self.routine_id is not None:
                name = (routine_names or {}).get(self.routine_id, self.routine_id)
                return f"'{name}' 루틴이 끝나면"
            return f"{self.appliance_id} 동작이 끝나면"
        if self.kind == "event":
            return f"가전 알림 {quoted_josa(str(self.event), '이', '가')} 오면"
        return "직접 실행할 때"


@dataclass(frozen=True)
class RoutineCondition:
    kind: str
    #: time_window
    start: str | None = None
    end: str | None = None
    #: environment — 적은 기준 중 **하나라도** 넘으면 만족(예: 28°C 이상 또는 습도 70% 이상)
    temperature_at_least: float | None = None
    humidity_at_least: float | None = None

    def to_dict(self) -> dict:
        data: dict = {"kind": self.kind}
        for name in ("start", "end", "temperature_at_least", "humidity_at_least"):
            value = getattr(self, name)
            if value is not None:
                data[name] = value
        return data

    @classmethod
    def from_dict(cls, data, index: int = 0) -> "RoutineCondition":
        where = f"{index + 1}번째 조건"
        if not isinstance(data, dict):
            _fail(f"{where}의 형식이 맞지 않아요")
        kind = data.get("kind")
        if kind not in CONDITION_KINDS:
            _fail(f"{where}의 종류를 알 수 없어요 (시간대·온습도 중 하나)")
        if kind == "time_window":
            parse_hhmm(data.get("start"), f"{where}의 시작 시각")
            parse_hhmm(data.get("end"), f"{where}의 끝 시각")
            if data["start"].strip() == data["end"].strip():
                _fail(f"{where}: 시작과 끝 시각이 같아요")
            return cls(kind, start=data["start"].strip(), end=data["end"].strip())
        values = {}
        for name, lo, hi, label in (("temperature_at_least", -20, 60, "온도"),
                                    ("humidity_at_least", 0, 100, "습도")):
            value = data.get(name)
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not lo <= value <= hi:
                _fail(f"{where}: {label} 기준은 {lo}~{hi} 사이 숫자로 적어 주세요")
            values[name] = float(value)
        if not values:
            _fail(f"{where}: 온도나 습도 기준을 하나 이상 적어 주세요")
        return cls(kind, **values)


# ── 루틴 ────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Routine:
    routine_id: str
    name: str
    steps: tuple[RoutineStep, ...]
    trigger: RoutineTrigger = field(default_factory=lambda: RoutineTrigger("manual"))
    conditions: tuple[RoutineCondition, ...] = ()
    mode: str = "approve"
    enabled: bool = True
    icon: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None

    @property
    def device_steps(self) -> tuple[RoutineStep, ...]:
        return tuple(s for s in self.steps if s.is_device_step)

    def steps_fingerprint(self) -> str:
        """승인이 묶이는 내용 — 단계 전체(안내·기다리기 포함)와 실행 방식.

        이름·아이콘·트리거는 들어가지 않는다: 그것들이 바뀌어도 기계가 할 일은 같다.
        """
        payload = {"mode": self.mode, "steps": [s.to_dict() for s in self.steps]}
        return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()

    def scenario_key(self) -> str:
        """제안 카드의 ``scenario_id`` — 루틴 ID와 단계 지문 앞 12자리."""
        return f"{SCENARIO_PREFIX}{self.routine_id}@{self.steps_fingerprint()[:12]}"

    def to_dict(self) -> dict:
        return {
            "schema_version": SCHEMA_VERSION,
            "id": self.routine_id,
            "name": self.name,
            "icon": self.icon,
            "steps": [s.to_dict() for s in self.steps],
            "trigger": self.trigger.to_dict(),
            "conditions": [c.to_dict() for c in self.conditions],
            "mode": self.mode,
            "enabled": self.enabled,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


SCENARIO_PREFIX = "routine:"


def parse_scenario_key(scenario_id: str | None) -> tuple[str, str] | None:
    """``routine:<id>@<지문12>`` → (id, 지문12). 루틴 카드가 아니면 None."""
    if not scenario_id or not scenario_id.startswith(SCENARIO_PREFIX):
        return None
    body = scenario_id[len(SCENARIO_PREFIX):]
    routine_id, sep, fp = body.rpartition("@")
    if not sep or not routine_id or not fp:
        return None
    return routine_id, fp


def build_routine(data: dict, *, routine_id: str, now: datetime,
                  created_at: datetime | None = None) -> Routine:
    """요청 본문 → 구조 검증을 통과한 루틴. 가전 검증은 ``validate_against``."""
    if not isinstance(data, dict):
        _fail("루틴 형식이 맞지 않아요")
    name = _text(data.get("name"), "루틴 이름", MAX_NAME_LEN)
    icon = _text(data.get("icon"), "아이콘", MAX_ICON_LEN, required=False)
    raw_steps = data.get("steps")
    if not isinstance(raw_steps, (list, tuple)) or not raw_steps:
        _fail("단계를 하나 이상 넣어 주세요")
    if len(raw_steps) > MAX_STEPS:
        _fail(f"단계는 {MAX_STEPS}개까지 넣을 수 있어요")
    steps = tuple(RoutineStep.from_dict(s, i) for i, s in enumerate(raw_steps))
    trigger = RoutineTrigger.from_dict(data.get("trigger"))
    raw_conditions = data.get("conditions") or []
    if not isinstance(raw_conditions, (list, tuple)):
        _fail("조건 형식이 맞지 않아요")
    if len(raw_conditions) > MAX_CONDITIONS:
        _fail(f"조건은 {MAX_CONDITIONS}개까지 넣을 수 있어요")
    conditions = tuple(RoutineCondition.from_dict(c, i) for i, c in enumerate(raw_conditions))
    mode = data.get("mode", "approve")
    if mode not in MODES:
        _fail("실행 방식은 '승인 후 실행(approve)' 또는 '알림만(notify)'에서 골라 주세요")
    enabled = data.get("enabled", True)
    if not isinstance(enabled, bool):
        _fail("켜기/끄기 값은 true 또는 false로 보내 주세요")
    _check_step_order(steps, mode)
    if trigger.kind == "after_done" and trigger.routine_id == routine_id:
        _fail("자기 자신이 끝난 뒤에 다시 시작하게 할 수는 없어요")
    return Routine(routine_id=routine_id, name=name, steps=steps, trigger=trigger,
                   conditions=conditions, mode=mode, enabled=enabled, icon=icon,
                   created_at=created_at or now, updated_at=now)


def _check_step_order(steps: tuple[RoutineStep, ...], mode: str) -> None:
    seen: set[str] = set()
    for index, step in enumerate(steps):
        if step.kind == "wait_until_done" and step.appliance_id not in seen:
            _fail(f"{index + 1}번째 단계: 기다릴 가전은 앞 단계에서 먼저 움직여야 해요")
        if step.is_device_step:
            seen.add(step.appliance_id)  # type: ignore[arg-type]
    if index_of_last_device(steps) is None and mode == "approve":
        _fail("가전을 움직이는 단계가 없어요 — 안내만 하는 루틴은 '알림만'으로 저장해 주세요")
    if steps and steps[-1].kind == "wait_until_done":
        _fail("마지막 단계가 '완료 기다리기'면 기다린 뒤 할 일이 없어요")


def index_of_last_device(steps) -> int | None:
    last = None
    for index, step in enumerate(steps):
        if step.is_device_step:
            last = index
    return last


# ── 가전 검증·명령 만들기 ─────────────────────────────────────────────────────


def _button_label(appliance, token: str) -> str | None:
    for button in appliance.buttons:
        if button.id == token:
            return button.label
    for button in appliance.buttons:
        if button.label == token:
            return button.label
    return None


def step_command(step: RoutineStep, registry) -> Command:
    """장치 단계 → 명령. 등록부 기준으로 검사한다(없으면 RoutineValidationError)."""
    appliance = registry.get(step.appliance_id) if registry is not None else None
    if appliance is None:
        _fail(f"'{step.appliance_id}' 가전이 등록되어 있지 않아요")
    if step.kind == "press_sequence":
        if appliance.control_path is not ControlRoute.PHYSICAL:
            _fail(f"{quoted_josa(appliance.name, '은', '는')} 버튼을 누르는 가전이 아니에요 — ThinQ 명령 단계를 써 주세요")
        labels = []
        missing = []
        for token in step.buttons:
            label = _button_label(appliance, token)
            (labels if label is not None else missing).append(label if label is not None else token)
        if missing:
            _fail(f"'{appliance.name}' 조작부 사진에 없는 버튼이에요: {', '.join(missing)}")
        try:
            return Command.physical(appliance.appliance_id, tuple(labels))
        except ValueError as exc:
            _fail(f"'{appliance.name}' 버튼 순서가 실행 한도를 넘어요 ({exc})")
    if appliance.control_path is not ControlRoute.THINQ or appliance.thinq is None:
        _fail(f"{quoted_josa(appliance.name, '은', '는')} ThinQ로 연결된 가전이 아니에요")
    try:
        return appliance.thinq.command(appliance.appliance_id, step.action, dict(step.args))
    except Exception as exc:  # noqa: BLE001 -- CapabilityError 등 허용 범위 밖
        _fail(f"'{appliance.name}'에서 쓸 수 없는 명령이에요 ({exc})")
    raise AssertionError("unreachable")


def compile_commands(routine: Routine, registry) -> tuple[Command, ...]:
    return tuple(step_command(step, registry) for step in routine.device_steps)


def validate_against(routine: Routine, registry, known_routine_ids=()) -> None:
    """저장 전 가전 검증 — 버튼·동작이 지금 등록된 가전에 있는가."""
    compile_commands(routine, registry)
    for step in routine.steps:
        if step.kind == "wait_until_done" and registry is not None and registry.get(step.appliance_id) is None:
            _fail(f"'{step.appliance_id}' 가전이 등록되어 있지 않아요")
    trigger = routine.trigger
    if trigger.kind == "after_done" and trigger.routine_id is not None:
        if trigger.routine_id not in set(known_routine_ids):
            _fail("'끝난 뒤'에 고른 루틴이 없어요")
    if trigger.kind in ("after_done", "approach", "event") and trigger.appliance_id is not None:
        if registry is not None and registry.get(trigger.appliance_id) is None:
            _fail(f"'{trigger.appliance_id}' 가전이 등록되어 있지 않아요")


# ── 저장 문서 이관 ──────────────────────────────────────────────────────────


def migrate_document(doc: dict) -> dict:
    """옛 형식의 저장 문서를 지금 형식으로 올린다(읽을 때마다, 제자리 아님).

    형식 0(번호 없음, 9/30 초안): ``mode`` 없음 → approve, ``conditions`` 없음 → [],
    ``enabled`` 없음 → true, 트리거의 ``weekdays`` → ``days``, 단계의 ``type`` → ``kind``.
    """
    doc = dict(doc)
    version = doc.get("schema_version") or 0
    if version < 1:
        doc.setdefault("mode", "approve")
        doc.setdefault("conditions", [])
        doc.setdefault("enabled", True)
        trigger = dict(doc.get("trigger") or {"kind": "manual"})
        if "weekdays" in trigger and "days" not in trigger:
            trigger["days"] = trigger.pop("weekdays")
        doc["trigger"] = trigger
        doc["steps"] = [
            ({**s, "kind": s["type"]} if isinstance(s, dict) and "kind" not in s and "type" in s else s)
            for s in (doc.get("steps") or [])
        ]
        doc["schema_version"] = 1
    return doc


def routine_from_document(doc: dict) -> Routine:
    doc = migrate_document(doc)

    def when(value):
        return datetime.fromisoformat(value) if value else None

    created = when(doc.get("created_at"))
    routine = build_routine(doc, routine_id=doc["id"], now=when(doc.get("updated_at")) or created,
                            created_at=created)
    return replace(routine, updated_at=when(doc.get("updated_at")))
