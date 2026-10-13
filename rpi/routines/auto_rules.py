"""자동 실행 허용 규칙 (2026-10-13, 시연 v4 — docs/본선-시연-계획-v4.md).

범위는 하나다: **전자레인지 조리 완료(확인된 사건) → ThinQ 공기청정기 동작 하나**. 사용자가 제안 카드에서
'이번에 실행하고 다음부터 자동으로'를 고르고 조건·동작 확인을 본 뒤에만 생긴다. 자주 승인했다고 저절로
켜지지 않는다. 규칙은 카드가 보여 준 내용(조건·대상 기기·속성·값)을 그대로 저장한다 — 빈 루틴 폼이 아니다.

필수 조건과 이 모듈이 강제하는 자리:

1. **낮은 위험 ThinQ 동작만**(`LOW_RISK_ACTIONS`: 공기청정기 풍량·운전 모드·전원 켜기). 물리 버튼 누름이 있는
   카드는 허용 제안이 없고(`offer_for` → None) 서버도 거절한다. 저장된 규칙도 실행 직전에 다시 본다.
2. **모의 사건 → 모의 ThinQ만.** 대상 실행 환경이 real이면 사건 출처도 real(RPi4 L3 실물 판정)이어야 보낸다.
3. **같은 사건 한 번.** 사건 키(가전·이벤트·출처·RPi4 끝 시각)로 멱등 — 재전송·재연결로 다시 와도 한 번.
   RPi4 시각이 없거나 사건이 오래됐거나(``SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S``, 기본 120초, 측정 필요)
   허용하기 전에 끝난 조리면 보내지 않는다. 결과가 미확인이어도 **다시 보내지 않는다**(재시도 코드 없음).
4. **허용은 지문에 묶인다**(조건 가전·이벤트·대상 가전·대상 기기 키·종류·동작·속성·값). 값을 바꾸면 꺼지고 다시
   허용해야 한다. 대상 기기가 없어지거나 다른 기기로 바뀌면 그 자리에서 무효(꺼짐 + 이유)가 된다.
5. **비상정지**: 세대를 올려(`halt`) 판단은 끝났지만 아직 보내지 않은 자동 실행을 실행 게이트 안에서 막고
   (`approval_guard`), 켜진 규칙을 모두 끈다. 이미 클라우드에 보낸 명령은 취소되지 않는다고 그대로 적는다.
6. **조리 완료 근거**(정확히는 가열 종료 감지 — 취소·문 열림과 구분 못 함, 실측 기록표 §6)는 RPi4 ``appliance_done``(전자레인지 CT 채널 전력 끝, 입력에 ``power``)뿐이다. 실행
   끝(버튼 누름 완료)은 이 모듈에 오지 않는다.

**검증 수준: 모의 ThinQ·모의 클라우드 끝-끝까지. 실제 CT 판정·실가전 미검증.**
"""

from __future__ import annotations

import hashlib
import logging
import math
import os
import threading
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timedelta
from uuid import uuid4

from rpi.commands import ApprovedCommand, ControlRoute, canonical_json
from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageSource

log = logging.getLogger(__name__)

#: 자동 실행해도 되는 낮은 위험 동작 — 기기 종류 → 동작 → 허용 값(None이면 그 동작의 모든 값).
LOW_RISK_ACTIONS: dict[str, dict[str, tuple[str, ...] | None]] = {
    "DEVICE_AIR_PURIFIER": {
        "set_wind_strength": None,
        "set_job_mode": None,
        "set_power": ("POWER_ON",),  # 켜기만. 끄기는 자동 실행 대상이 아니다.
    },
}

MAX_EVENT_AGE_ENV = "SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S"
#: 사건 나이 상한(초) — RPi4가 끝을 본 뒤 프레임을 낼 때까지. **측정 필요**(전자레인지 settle_s 10초 + 여유).
DEFAULT_MAX_EVENT_AGE_S = 120.0
#: 자동 실행 승인 1건의 유효 시간(초).
APPROVAL_SECONDS = 60
#: 실행 기록의 시나리오 ID 접두사(시나리오·루틴 트리거가 다시 깨우지 않게).
AUTO_SCENARIO_PREFIX = "auto:"
KIND_AUTO_RULE = "auto_rule"
CONDITION_BASIS = "ct_power_end"
MAX_SEEN_EVENTS = 500

ESTOP_REASON = "비상정지로 자동 실행을 껐어요 — 다시 켜려면 조건·동작을 확인하고 허용해 주세요"
ESTOP_NOTICE = ("비상정지로 자동 실행을 껐어요 — 새 자동 실행과 아직 보내지 않은 명령은 보내지 않아요. "
                "이미 ThinQ 클라우드로 보낸 명령은 취소되지 않아요(공기청정기를 되돌리거나 끄지 않아요)")
USER_OFF_REASON = "사용자가 자동 실행을 껐어요"
VALUE_CHANGED_REASON = "설정값을 바꿔 다시 허용이 필요해요"
PHYSICAL_REFUSED = "버튼을 누르는 단계는 자동 실행할 수 없어요 — 매번 승인해 주세요"


class AutoRuleError(Exception):
    """허용·수정할 수 없다. ``status``는 HTTP 상태, 메시지는 화면에 보여도 되는 문장."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class AutoRuleBlocked(RuntimeError):
    """실행 게이트 안에서 막혔다(비상정지·규칙 꺼짐). 실행을 시작하지 않는다."""


def is_low_risk(device_type: str | None, action: str | None, value) -> bool:
    allowed = LOW_RISK_ACTIONS.get(device_type or "", {})
    if action not in allowed:
        return False
    values = allowed[action]
    return values is None or value in values


def _josa(word: str, with_final: str, without_final: str) -> str:
    """받침이 있으면 앞, 없으면 뒤(한글 끝 글자 기준, 그 밖은 앞)."""
    last = word.strip()[-1:] if word.strip() else ""
    if "가" <= last <= "힣":
        return with_final if (ord(last) - 0xAC00) % 28 else without_final
    return with_final


def _device_key(device_id: str) -> str:
    from rpi.services.thinq.discovery import device_key  # noqa: PLC0415

    return device_key(device_id)


@dataclass(frozen=True)
class AutoRule:
    rule_id: str
    scenario_id: str
    condition_appliance_id: str
    condition_event: str
    target_appliance_id: str
    target_device_key: str
    target_device_type: str
    action: str
    arg: str
    value: str
    enabled: bool = False
    #: 사용자가 확인 화면에서 허용한 지문. 지금 지문과 다르면 허용이 아니다.
    allowed_fingerprint: str | None = None
    created_at: str | None = None
    allowed_at: str | None = None
    updated_at: str | None = None
    disabled_reason: str | None = None

    def fingerprint(self) -> str:
        """허용이 묶이는 내용 — 조건(가전·이벤트·근거)·대상(가전·기기 키·종류)·동작·속성·값."""
        payload = {
            "scenario": self.scenario_id,
            "condition": {"appliance_id": self.condition_appliance_id, "event": self.condition_event,
                          "basis": CONDITION_BASIS},
            "target": {"appliance_id": self.target_appliance_id, "device_key": self.target_device_key,
                       "device_type": self.target_device_type},
            "action": self.action, "arg": self.arg, "value": self.value,
        }
        return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()

    @property
    def allowed(self) -> bool:
        return self.enabled and self.allowed_fingerprint == self.fingerprint()

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Mapping) -> "AutoRule":
        fields = {name: data.get(name) for name in cls.__dataclass_fields__}
        fields["enabled"] = data.get("enabled") is True
        return cls(**fields)


class AutoRuleStore:
    """규칙 목록 — 서버 DB 설정 칸(``auto_rules``)이 있으면 재시작에도 남는다. 없으면 메모리."""

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None) -> None:
        import json  # noqa: PLC0415

        self._json = json
        self._save_fn = save
        self._lock = threading.Lock()
        self._rules: dict[str, AutoRule] = {}
        raw = load() if load is not None else None
        if raw:
            try:
                for item in json.loads(raw):
                    rule = AutoRule.from_dict(item)
                    self._rules[rule.rule_id] = rule
            except (ValueError, TypeError, KeyError):
                log.exception("auto rules unreadable; starting empty (자동 실행은 꺼진 것과 같다)")

    def list(self) -> tuple[AutoRule, ...]:
        with self._lock:
            return tuple(self._rules.values())

    def get(self, rule_id: str) -> AutoRule | None:
        with self._lock:
            return self._rules.get(rule_id)

    def save(self, rule: AutoRule) -> AutoRule:
        with self._lock:
            self._rules[rule.rule_id] = rule
            self._persist_locked()
        return rule

    def delete(self, rule_id: str) -> bool:
        with self._lock:
            removed = self._rules.pop(rule_id, None) is not None
            if removed:
                self._persist_locked()
        return removed

    def _persist_locked(self) -> None:
        if self._save_fn is not None:
            self._save_fn(self._json.dumps([r.to_dict() for r in self._rules.values()], ensure_ascii=False))


class SeenEvents:
    """한 번 처리한 완료 사건 키(최근 ``MAX_SEEN_EVENTS``개). DB가 있으면 재시작 뒤 재전송도 막는다."""

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None) -> None:
        import json  # noqa: PLC0415

        self._json = json
        self._save_fn = save
        self._lock = threading.Lock()
        self._keys: deque[str] = deque(maxlen=MAX_SEEN_EVENTS)
        raw = load() if load is not None else None
        if raw:
            try:
                self._keys.extend(str(k) for k in json.loads(raw))
            except (ValueError, TypeError):
                log.exception("seen auto-rule events unreadable")

    def add(self, key: str) -> bool:
        """처음 본 키면 넣고 True, 이미 있으면 False."""
        with self._lock:
            if key in self._keys:
                return False
            self._keys.append(key)
            if self._save_fn is not None:
                self._save_fn(self._json.dumps(list(self._keys)))
            return True


def event_key(record: Mapping) -> str | None:
    """완료 사건 키 — 가전·이벤트·출처·RPi4 끝 시각(at_s). 끝 시각이 없으면 None(같은 사건인지 모름)."""
    at_s = record.get("at_s")
    if not isinstance(at_s, (int, float)) or isinstance(at_s, bool) or not math.isfinite(at_s):
        return None
    raw = f"{record.get('appliance_id')}|{record.get('event')}|{record.get('source')}|{float(at_s):.3f}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def event_age_s(record: Mapping) -> float | None:
    """RPi4가 끝을 본 시각부터 프레임을 낸 시각까지(초, 같은 단조 시계). 모르면 None."""
    at_s, sent_ns = record.get("at_s"), record.get("t_monotonic_ns")
    if not isinstance(at_s, (int, float)) or not isinstance(sent_ns, int) or isinstance(sent_ns, bool):
        return None
    age = sent_ns / 1e9 - float(at_s)
    return age if age >= -1.0 else None


def max_event_age_from_env(env: Mapping[str, str] | None = None) -> float:
    src = os.environ if env is None else env
    raw = (src.get(MAX_EVENT_AGE_ENV) or "").strip()
    if not raw:
        return DEFAULT_MAX_EVENT_AGE_S
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{MAX_EVENT_AGE_ENV} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not (math.isfinite(value) and value > 0):
        raise RuntimeError(f"{MAX_EVENT_AGE_ENV}는 0보다 커야 합니다: {raw!r}")
    return value


class AutoRuleEngine:
    """규칙 만들기·실행·관리. 서비스(실행 게이트)와 시나리오 엔진(카드)을 그때그때 받아 쓴다."""

    def __init__(self, store: AutoRuleStore, seen: SeenEvents, service, clock, *,
                 scenarios: Callable[[], object] | None = None, care_events=None,
                 max_event_age_s: float = DEFAULT_MAX_EVENT_AGE_S) -> None:
        self.store = store
        self._seen = seen
        self.service = service
        self._clock = clock
        self._scenarios = scenarios or (lambda: None)
        self._care = care_events
        self._max_age = max_event_age_s
        self._lock = threading.Lock()
        #: 비상정지 세대. 판단 시점과 실행 게이트 안의 값이 다르면 보내지 않는다.
        self._gen_lock = threading.Lock()
        self._generation = 0
        self._runs: deque[dict] = deque(maxlen=50)
        #: 기록보다 먼저 끝난 자동 실행의 결과(job_id → 완료 이벤트).
        self._early_results: dict[str, object] = {}
        #: 보내기 직전 재검사에 걸린 자동 실행(규칙:사건 키 → 이유). 결과가 오면 기록을 '막힘'으로 고친다.
        self._dispatch_blocked: dict[str, str] = {}

    # ── 등록부·문장 ─────────────────────────────────────────────────────────
    def _registry(self):
        return getattr(self.service, "_appliance_registry", None)

    def _appliance(self, appliance_id: str):
        registry = self._registry()
        return registry.get(appliance_id) if registry is not None else None

    def _name(self, appliance_id: str) -> str:
        appliance = self._appliance(appliance_id)
        return appliance.name if appliance is not None else appliance_id

    def _definition(self, scenario_id: str | None):
        engine = self._scenarios()
        catalog = getattr(engine, "catalog", None)
        return catalog.get(scenario_id) if catalog is not None and scenario_id else None

    def condition_text(self, rule: AutoRule) -> str:
        # A5(2026-10-14): CT 끝 판정은 취소·문 열림 가열 종료와 구분하지 못한다 — 조리 완료라고 말하지 않는다.
        return f"{self._name(rule.condition_appliance_id)} 가열 종료가 감지됐을 때(조리 완료가 아닐 수 있어요)"

    def action_text(self, rule: AutoRule) -> str:
        name = self._name(rule.target_appliance_id)
        appliance = self._appliance(rule.target_appliance_id)
        binding = getattr(appliance, "thinq", None)
        try:
            cap = binding.capability(rule.action) if binding is not None else None
        except Exception:  # noqa: BLE001 -- 대상이 바뀌었으면 동작 이름만
            cap = None
        if cap is None:
            return f"{name} {rule.action} {rule.value}"
        value = cap.value_label(str(rule.value))
        if rule.action == "set_power":
            return f"{name} 전원 {value}"
        return f"{name} {cap.label}{_josa(cap.label, '을', '를')} {value}{_josa(value, '으로', '로')} 변경"

    # ── 카드의 허용 제안 ─────────────────────────────────────────────────────
    def offer_for(self, suggestion) -> AutoRule | None:
        """카드가 '다음부터도 자동으로'를 고를 수 있으면 그 내용(저장 전 규칙), 아니면 None.

        v4 정의(``auto_allowed``)의 카드이고, 명령이 ThinQ 하나이며, 낮은 위험 동작일 때만. 물리 누름이 하나라도
        있으면 None — 화면에 버튼이 없고 서버도 거절한다."""
        commands = tuple(getattr(suggestion, "commands", ()) or ())
        if any(c.route is not ControlRoute.THINQ for c in commands) or len(commands) != 1:
            return None
        definition = self._definition(getattr(suggestion, "scenario_id", None))
        if definition is None or not definition.auto_allowed or definition.trigger.kind != "appliance_done":
            return None
        command = commands[0]
        return self._draft(definition.scenario_id, definition.trigger.appliance_id,
                           definition.trigger.event, command.target_id, command.action,
                           command.args_dict())

    def _draft(self, scenario_id, condition_appliance, condition_event, target_id, action, args) -> AutoRule | None:
        appliance = self._appliance(target_id)
        binding = getattr(appliance, "thinq", None)
        if appliance is None or appliance.control_path is not ControlRoute.THINQ or binding is None:
            return None
        try:
            cap = binding.capability(action)
            value = args.get(cap.arg)
            cap.validate({cap.arg: value})
        except Exception:  # noqa: BLE001
            return None
        if not is_low_risk(binding.device_type, action, value):
            return None
        return AutoRule(
            rule_id="", scenario_id=scenario_id, condition_appliance_id=condition_appliance,
            condition_event=condition_event, target_appliance_id=target_id,
            target_device_key=_device_key(binding.device_id), target_device_type=binding.device_type,
            action=action, arg=cap.arg, value=str(value),
        )

    def offer_payload(self, suggestion) -> dict | None:
        draft = self.offer_for(suggestion)
        if draft is None:
            return None
        return {"condition_text": self.condition_text(draft), "action_text": self.action_text(draft),
                "fingerprint": draft.fingerprint()}

    def allow_from_offer(self, draft: AutoRule) -> AutoRule:
        """확인 화면에서 허용한 내용을 규칙으로 저장한다. 같은 조건·대상·동작의 규칙이 있으면 바꾼다."""
        now = self._clock.now().isoformat()
        existing = next((r for r in self.store.list()
                         if (r.scenario_id, r.condition_appliance_id, r.condition_event,
                             r.target_appliance_id, r.action)
                         == (draft.scenario_id, draft.condition_appliance_id, draft.condition_event,
                             draft.target_appliance_id, draft.action)), None)
        rule = replace(draft, rule_id=existing.rule_id if existing else f"ar-{uuid4().hex[:10]}",
                       enabled=True, allowed_fingerprint=draft.fingerprint(),
                       created_at=existing.created_at if existing else now,
                       allowed_at=now, updated_at=now, disabled_reason=None)
        self.store.save(rule)
        log.info("auto rule allowed by user: %s (%s → %s %s)", rule.rule_id, rule.condition_event,
                 rule.target_appliance_id, rule.action)
        return rule

    # ── 사건 ─────────────────────────────────────────────────────────────────
    def on_appliance_done(self, record: Mapping) -> list[dict]:
        """검증한 ``appliance_done`` 기록. 켜진 규칙이 맡은 조건이면 자동 실행을 시도하고, 아니면 카드를 띄운다."""
        key = event_key(record)
        if key is not None and not self._seen.add(key):
            matching = [r for r in self.store.list() if self._matches(r, record)]
            if matching:
                return [self._record(rule, record, key, "duplicate",
                                     "같은 가열 종료 사건을 다시 받았어요 — 한 번만 실행해요") for rule in matching]
            return []
        received_at = self._clock.now()
        entries: list[dict] = []
        handled: set[str] = set()
        for rule in self.store.list():
            if not (rule.enabled and self._matches(rule, record)):
                continue
            entry = self._try_run(rule, record, key, received_at)
            entries.append(entry)
            if not entry.get("reoffer"):
                handled.add(rule.scenario_id)
        engine = self._scenarios()
        if engine is not None and hasattr(engine, "on_appliance_done"):
            try:
                engine.on_appliance_done(dict(record), skip=frozenset(handled))
            except Exception:  # noqa: BLE001
                log.exception("scenario card for appliance_done failed")
        return entries

    @staticmethod
    def _matches(rule: AutoRule, record: Mapping) -> bool:
        return (rule.condition_appliance_id == record.get("appliance_id")
                and rule.condition_event == record.get("event"))

    def _try_run(self, rule: AutoRule, record: Mapping, key: str | None, received_at: datetime) -> dict:
        with self._gen_lock:
            generation = self._generation
        source = record.get("source")
        # ⑥ 조리 완료 근거 = CT 전력 끝.
        if "power" not in (record.get("inputs") or []):
            return self._record(rule, record, key, "blocked",
                                "가열 종료가 콘센트 전력(CT)으로 감지되지 않아 자동 실행하지 않았어요")
        # ③ 같은 사건·오래된 사건.
        age = event_age_s(record)
        if key is None or age is None:
            return self._record(rule, record, key, "blocked",
                                "가열 종료 시각을 확인할 수 없어 자동 실행하지 않았어요")
        if age > self._max_age:
            return self._record(rule, record, key, "blocked",
                                f"오래된 가열 종료({age:.0f}초 전)라 자동 실행하지 않았어요")
        allowed_at = _parse_time(rule.allowed_at)
        if allowed_at is None or received_at - timedelta(seconds=max(age, 0.0)) < allowed_at:
            return self._record(rule, record, key, "blocked",
                                "허용하기 전에 끝난 가열이라 자동 실행하지 않았어요")
        # ④ 허용 지문·대상 기기.
        invalid = self._invalid_reason(rule)
        if invalid is not None:
            self.store.save(replace(rule, enabled=False, allowed_fingerprint=None,
                                    updated_at=received_at.isoformat(), disabled_reason=invalid))
            return self._record(rule, record, key, "blocked", invalid, reoffer=True)
        # ⑤ 비상정지 걸림(RPi4 콘센트 모듈).
        latched = getattr(self.service, "estop_latched", None)
        if callable(latched) and latched():
            return self._record(rule, record, key, "blocked",
                                "비상정지가 걸려 있어 자동 실행하지 않았어요")
        # ② 모의 사건 → 모의 ThinQ만.
        thinq = getattr(self.service, "thinq_controller", None)
        if thinq is None:
            return self._record(rule, record, key, "blocked", "ThinQ 연동이 꺼져 있어 자동 실행하지 않았어요")
        mode = getattr(thinq, "execution_mode", ExecutionMode.UNKNOWN)
        if mode is ExecutionMode.REAL and source != "real":
            return self._record(rule, record, key, "blocked",
                                "모의·주입 사건으로는 실제 공기청정기를 움직이지 않아요 — 자동 실행하지 않았어요")
        if mode not in (ExecutionMode.REAL, ExecutionMode.MOCK):
            return self._record(rule, record, key, "blocked",
                                "ThinQ 실행 환경을 확인할 수 없어 자동 실행하지 않았어요")
        return self._submit(rule, record, key, generation)

    def _invalid_reason(self, rule: AutoRule) -> str | None:
        if self._appliance(rule.condition_appliance_id) is None:
            return "조건 가전이 없어져 자동 실행을 껐어요 — 다시 허용이 필요해요"
        appliance = self._appliance(rule.target_appliance_id)
        binding = getattr(appliance, "thinq", None)
        if appliance is None or appliance.control_path is not ControlRoute.THINQ or binding is None:
            return "대상 공기청정기가 없어져 자동 실행을 껐어요 — 다시 허용이 필요해요"
        if (binding.device_type != rule.target_device_type
                or _device_key(binding.device_id) != rule.target_device_key):
            return "대상 공기청정기가 다른 기기로 바뀌어 자동 실행을 껐어요 — 다시 허용이 필요해요"
        if not is_low_risk(rule.target_device_type, rule.action, rule.value):
            return "자동 실행할 수 없는 동작이라 껐어요"
        try:
            binding.validate_command(binding.command(rule.target_appliance_id, rule.action,
                                                     {rule.arg: rule.value}))
        except Exception:  # noqa: BLE001
            return "이 가전에서 쓸 수 없는 설정이라 자동 실행을 껐어요 — 다시 허용이 필요해요"
        if rule.allowed_fingerprint != rule.fingerprint():
            return "허용한 뒤 조건·동작이 바뀌어 자동 실행을 껐어요 — 다시 허용이 필요해요"
        return None

    def _submit(self, rule: AutoRule, record: Mapping, key: str, generation: int) -> dict:
        appliance = self._appliance(rule.target_appliance_id)
        command = appliance.thinq.command(rule.target_appliance_id, rule.action, {rule.arg: rule.value})
        now = self._clock.now()
        approved = ApprovedCommand(
            command=command, approval_id=f"auto-rule:{rule.rule_id}:{key}", approved_at=now,
            shown_summary=self.service.summary_of(command),
            expires_at=now + timedelta(seconds=APPROVAL_SECONDS),
        )

        decided = rule.fingerprint()
        block_key = f"{rule.rule_id}:{key}"

        def guard() -> None:
            # 실행 게이트(서비스 락) 안에서 — 비상정지 세대가 바뀌었거나 규칙이 꺼졌거나, 판단 때와 내용
            # (설정값·대상)이 달라졌으면 시작하지 않는다. 값을 바꾸고 다시 허용해도 판단 때의 옛 명령은 보내지 않는다.
            with self._gen_lock:
                if self._generation != generation:
                    raise AutoRuleBlocked("비상정지로 아직 보내지 않은 자동 실행을 보내지 않았어요")
            current = self.store.get(rule.rule_id)
            if current is None or not current.allowed:
                raise AutoRuleBlocked("자동 실행이 꺼져 보내지 않았어요")
            if current.fingerprint() != decided:
                raise AutoRuleBlocked("자동 실행 설정이 바뀌어 이전 내용을 보내지 않았어요")

        def dispatch_guard() -> None:
            # 보내기 직전(실행 스레드) 재검사 — 시작 게이트 뒤에 꺼지거나 바뀌었으면 보내지 않는다.
            try:
                guard()
            except AutoRuleBlocked as exc:
                with self._lock:
                    self._dispatch_blocked[block_key] = str(exc)
                raise

        try:
            job_id = self.service.submit_approved(
                (approved,), purpose=f"자동 실행 · {self.action_text(rule)}",
                usage_source=UsageSource.SUGGESTION, approval_guard=guard,
                scenario_id=f"{AUTO_SCENARIO_PREFIX}{rule.rule_id}", dispatch_guard=dispatch_guard,
            )
        except AutoRuleBlocked as exc:
            return self._record(rule, record, key, "blocked", str(exc))
        except Exception as exc:  # noqa: BLE001 -- 시작 못 함. 나중에 다시 보내지 않는다.
            text = str(exc)
            reason = ("다른 작업이 실행 중이라 자동 실행하지 않았어요 — 나중에 다시 보내지 않아요"
                      if "already in progress" in text
                      else f"자동 실행을 시작하지 못했어요 — {text or type(exc).__name__}")
            return self._record(rule, record, key, "blocked", reason)
        return self._record(rule, record, key, "sent", "허용한 조건이라 승인 없이 보냈어요", job_id=job_id,
                            notices=[self._cook_notice(rule, record)])

    def _cook_notice(self, rule: AutoRule, record: Mapping) -> str:
        # A5(2026-10-14): 취소·문 열림으로 끝난 가열도 같은 사건으로 온다 — '데우기가 끝났어요'라고 하지 않는다.
        notice = (f"{self._name(rule.condition_appliance_id)} 가열 종료를 감지했어요 "
                  "(콘센트 전력 · 조리 완료가 아닐 수 있어요)")
        source = record.get("source")
        if source == "injected":
            notice += " (시연 주입)"
        elif source != "real":
            notice += " (모의 입력)"
        return notice

    # ── 실행 결과 ────────────────────────────────────────────────────────────
    def on_job_finished(self, event) -> None:
        scenario_id = getattr(event, "scenario_id", None) or ""
        if not scenario_id.startswith(AUTO_SCENARIO_PREFIX):
            return
        with self._lock:
            entry = next((e for e in reversed(self._runs) if e.get("job_id") == event.job_id), None)
            if entry is None:
                # 실행이 기록보다 먼저 끝났다(제출 직후 끝난 모의 실행) — 기록할 때 붙인다.
                self._early_results[event.job_id] = event
                return
            self._apply_result_locked(entry, event)
        self._notify(entry)

    def _apply_result_locked(self, entry: dict, event) -> None:
        rule = self.store.get(entry["rule_id"])
        blocked = self._dispatch_blocked.pop(f"{entry['rule_id']}:{entry.get('event_key')}", None)
        if blocked is not None and event.receipt.value == "not_dispatched":
            notice = blocked
            entry.update({"outcome": "blocked", "reason": blocked})
        else:
            notice = self._result_notice(entry, rule, event)
        entry.update({"status": event.status, "receipt": event.receipt.value,
                      "confirmation": event.confirmation.value,
                      "execution_mode": event.execution_mode.value,
                      "notices": [*entry.get("notices", []), notice]})

    def _notify(self, entry: dict) -> None:
        if self._care is None:
            return
        try:
            for text in entry["notices"]:
                self._care.append(KIND_AUTO_RULE, text, purpose=entry.get("action_text"))
        except Exception:  # noqa: BLE001
            log.exception("auto rule care notice failed")

    def _result_notice(self, entry: dict, rule: AutoRule | None, event) -> str:
        name = self._name(rule.target_appliance_id) if rule is not None else "공기청정기"
        label = "설정"
        if rule is not None:
            appliance = self._appliance(rule.target_appliance_id)
            try:
                label = appliance.thinq.capability(rule.action).label
            except Exception:  # noqa: BLE001
                pass
        mock = " — 모의 실행 · 실제 조작 아님" if event.execution_mode is ExecutionMode.MOCK else ""
        status, receipt = event.status, event.receipt.value
        if status == "succeeded" and event.confirmation.value == "state_confirmed":
            return f"{name} {label}{_josa(label, '을', '를')} 바꿨어요 (상태 재조회로 확인){mock}"
        if status == "unconfirmed":
            return (f"{name} 명령을 보냈지만 바뀐 것을 확인하지 못했어요 — 자동으로 다시 보내지 않아요. "
                    f"가전을 직접 확인해 주세요{mock}")
        if status == "stopped":
            if receipt == "not_dispatched":
                return f"정지 요청으로 {name} 명령을 보내지 않았어요{mock}"
            return f"{name} 명령은 이미 보내 취소할 수 없어요 — 공기청정기를 되돌리거나 끄지 않아요{mock}"
        if receipt == "not_dispatched":
            return f"{name} 명령을 보내지 못했어요{mock}"
        return f"{name} {label}{_josa(label, '을', '를')} 바꾸지 못했어요{mock}"

    # ── 비상정지 ─────────────────────────────────────────────────────────────
    def halt(self) -> None:
        """세대만 올린다(입출력 없음) — 정지 경로 맨 앞에서 부른다."""
        with self._gen_lock:
            self._generation += 1

    def emergency_stop(self, reason: str = "비상정지") -> int:
        """세대를 올리고 켜진 규칙을 모두 끈다. 끈 개수."""
        self.halt()
        now = self._clock.now().isoformat()
        disabled = [r for r in self.store.list() if r.enabled]
        for rule in disabled:
            self.store.save(replace(rule, enabled=False, updated_at=now, disabled_reason=ESTOP_REASON))
        if disabled:
            entry = {"at": now, "rule_id": disabled[0].rule_id, "outcome": "estop", "reason": ESTOP_NOTICE,
                     "event_key": None, "event_source": None, "job_id": None, "notices": [ESTOP_NOTICE],
                     "trigger": reason}
            with self._lock:
                self._runs.append(entry)
            if self._care is not None:
                try:
                    self._care.append(KIND_AUTO_RULE, ESTOP_NOTICE, purpose="자동 실행")
                except Exception:  # noqa: BLE001
                    log.exception("auto rule estop notice failed")
        return len(disabled)

    # ── 목록에서 끄기·켜기·수정·삭제 ─────────────────────────────────────────
    def _require(self, rule_id: str) -> AutoRule:
        rule = self.store.get(rule_id)
        if rule is None:
            raise AutoRuleError(404, "자동 실행 규칙을 찾을 수 없어요")
        return rule

    def _rebound(self, rule: AutoRule) -> AutoRule | None:
        """지금 등록된 대상 기기로 다시 묶은 규칙(다시 허용할 때 사용자가 보는 내용). 대상이 없으면 None."""
        draft = self._draft(rule.scenario_id, rule.condition_appliance_id, rule.condition_event,
                            rule.target_appliance_id, rule.action, {rule.arg: rule.value})
        if draft is None:
            return None
        return replace(rule, target_device_key=draft.target_device_key,
                       target_device_type=draft.target_device_type)

    def set_enabled(self, rule_id: str, enabled: bool, fingerprint: str | None = None) -> AutoRule:
        rule = self._require(rule_id)
        now = self._clock.now().isoformat()
        if not enabled:
            return self.store.save(replace(rule, enabled=False, updated_at=now, disabled_reason=USER_OFF_REASON))
        rebound = self._rebound(rule)
        if rebound is None or self._appliance(rule.condition_appliance_id) is None:
            raise AutoRuleError(409, "대상 가전을 찾지 못해 켤 수 없어요 — 가전 연결을 확인해 주세요")
        if fingerprint != rebound.fingerprint():
            raise AutoRuleError(409, "허용할 내용이 바뀌었어요 — 조건과 동작을 다시 확인해 주세요")
        return self.store.save(replace(rebound, enabled=True, allowed_fingerprint=fingerprint,
                                       allowed_at=now, updated_at=now, disabled_reason=None))

    def update(self, rule_id: str, body: Mapping) -> AutoRule:
        """설정값만 바꿀 수 있다. 바꾸면 꺼지고 다시 허용해야 한다."""
        rule = self._require(rule_id)
        if not isinstance(body, Mapping):
            raise AutoRuleError(422, "형식이 맞지 않아요")
        if body.get("kind") == "press_sequence" or "buttons" in body:
            raise AutoRuleError(422, PHYSICAL_REFUSED)
        extra = set(body) - {"value"}
        if extra:
            raise AutoRuleError(422, "자동 실행 규칙은 설정값만 바꿀 수 있어요 — 다른 조건·동작은 카드에서 새로 허용해 주세요")
        value = body.get("value")
        if not isinstance(value, str) or not value:
            raise AutoRuleError(422, "바꿀 설정값을 골라 주세요")
        if self._draft(rule.scenario_id, rule.condition_appliance_id, rule.condition_event,
                       rule.target_appliance_id, rule.action, {rule.arg: value}) is None:
            raise AutoRuleError(422, "이 가전에서 자동 실행할 수 없는 설정값이에요")
        if value == rule.value:
            return rule
        return self.store.save(replace(rule, value=value, enabled=False, allowed_fingerprint=None,
                                       updated_at=self._clock.now().isoformat(),
                                       disabled_reason=VALUE_CHANGED_REASON))

    def delete(self, rule_id: str) -> None:
        if not self.store.delete(rule_id):
            raise AutoRuleError(404, "자동 실행 규칙을 찾을 수 없어요")

    # ── 조회 ─────────────────────────────────────────────────────────────────
    def payload(self, rule: AutoRule) -> dict:
        definition = self._definition(rule.scenario_id)
        rebound = self._rebound(rule)
        values = []
        appliance = self._appliance(rule.target_appliance_id)
        try:
            cap = appliance.thinq.capability(rule.action)
            values = [{"value": v, "label": cap.value_label(v)} for v in cap.allowed
                      if is_low_risk(rule.target_device_type, rule.action, v)]
        except Exception:  # noqa: BLE001
            pass
        last = next((dict(e) for e in reversed(self.runs_snapshot()) if e.get("rule_id") == rule.rule_id), None)
        return {
            "id": rule.rule_id, "scenario_id": rule.scenario_id,
            "name": definition.name if definition is not None else "자동 실행",
            "condition_text": self.condition_text(rule), "action_text": self.action_text(rule),
            "target_appliance_id": rule.target_appliance_id, "action": rule.action, "value": rule.value,
            "allowed_values": values,
            "enabled": rule.enabled and rule.allowed,
            "status_label": "자동 실행 켜짐" if rule.enabled and rule.allowed else "자동 실행 꺼짐",
            "disabled_reason": rule.disabled_reason,
            #: 다시 허용할 때 보낼 지문(지금 등록된 대상 기기로 묶은 내용). 대상이 없으면 null.
            "fingerprint": rebound.fingerprint() if rebound is not None else None,
            "created_at": rule.created_at, "allowed_at": rule.allowed_at,
            "last_run": last,
        }

    def list_payloads(self) -> list[dict]:
        return [self.payload(r) for r in self.store.list()]

    def runs_snapshot(self) -> list[dict]:
        with self._lock:
            return [dict(e) for e in self._runs]

    def recent_runs(self) -> list[dict]:
        return list(reversed(self.runs_snapshot()))

    def _record(self, rule: AutoRule, record: Mapping, key: str | None, outcome: str, reason: str, *,
                job_id: str | None = None, notices: list[str] | None = None, reoffer: bool = False) -> dict:
        entry = {
            "at": self._clock.now().isoformat(), "rule_id": rule.rule_id, "outcome": outcome,
            "reason": reason, "event_key": key, "event_source": record.get("source"),
            "event_state": record.get("state"), "job_id": job_id, "notices": list(notices or []),
            "action_text": self.action_text(rule),
        }
        early = None
        with self._lock:
            self._runs.append(entry)
            if job_id is not None:
                early = self._early_results.pop(job_id, None)
                if early is not None:
                    self._apply_result_locked(entry, early)
        if early is not None:
            self._notify(entry)
        if outcome == "blocked":
            log.warning("auto rule %s blocked: %s", rule.rule_id, reason)
        result = dict(entry)
        if reoffer:
            result["reoffer"] = True
        return result


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


__all__ = [
    "AUTO_SCENARIO_PREFIX",
    "AutoRule",
    "AutoRuleEngine",
    "AutoRuleError",
    "AutoRuleStore",
    "LOW_RISK_ACTIONS",
    "SeenEvents",
    "event_age_s",
    "event_key",
    "is_low_risk",
    "max_event_age_from_env",
]
