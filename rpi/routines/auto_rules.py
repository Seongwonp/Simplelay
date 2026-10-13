"""자동 실행 허용 규칙 (2026-10-13, 시연 v4 — docs/본선-시연-계획-v4.md).

범위는 하나다: **전자레인지 가열 종료 감지(CT) → ThinQ 공기청정기 동작 하나**. 정책(10/14 사용자 확정, 3차 평가 L1):
가열 종료가 감지되면 취소·문 열림이어도 제안·자동 실행이 일어날 수 있다 — 낮은 위험 동작(풍량 변경)이라 허용하고
화면·기록은 '조리 완료가 아닐 수 있음'을 밝힌다. 사용자가 제안 카드에서
'이번에 실행하고 다음부터 자동으로'를 고르고 조건·동작 확인을 본 뒤에만 생긴다. 자주 승인했다고 저절로
켜지지 않는다. 규칙은 카드가 보여 준 내용(조건·대상 기기·속성·값)을 그대로 저장한다 — 빈 루틴 폼이 아니다.

필수 조건과 이 모듈이 강제하는 자리:

1. **낮은 위험 ThinQ 동작만**(`LOW_RISK_ACTIONS`: 공기청정기 풍량·운전 모드·전원 켜기). 물리 버튼 누름이 있는
   카드는 허용 제안이 없고(`offer_for` → None) 서버도 거절한다. 저장된 규칙도 실행 직전에 다시 본다.
2. **모의 사건 → 모의 ThinQ만.** 대상 실행 환경이 real이면 사건 출처도 real(RPi4 L3 실물 판정)이어야 보낸다.
3. **같은 사건 한 번.** 사건 키(가전·이벤트·출처·RPi4 끝 시각)로 멱등 — 재전송·재연결로 다시 와도 한 번.
   사건 나이는 **이 허브 단조 시계로 옮긴 끝 시각**부터 잰다(3차 평가 M1, ``rpi/services/event_clock.py`` — RPi4가
   프레임을 낸 뒤 링크에서 늦어진 시간까지 센다. 다른 장치의 monotonic을 그대로 비교하지 않는다). 옮길 근거가 없거나
   (옛 RPi4·연결 세션 바뀜) 사건이 오래됐거나(``SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S``, 기본 120초, 측정 필요) 허용하기
   전에 끝난 가열이면 보내지 않는다(보류가 기본). 전송 직전에도 나이를 다시 본다(전송 대기 중 만료).
   허용 전후도 같은 허브 단조 시계 축에서 가른다(4차 평가 M-N2) — 재시작 뒤 불러온 허용은 이 프로세스가 시작한 뒤에 끝난
   가열에만 쓴다.
   결과가 미확인이어도 **다시 보내지 않는다**(재시도 코드 없음).
4. **허용은 지문에 묶인다**(조건 가전·이벤트·대상 가전·대상 기기 키·종류·동작·속성·값). 값을 바꾸면 꺼지고 다시
   허용해야 한다. 대상 기기가 없어지거나 다른 기기로 바뀌면 그 자리에서 무효(꺼짐 + 이유)가 된다.
5. **비상정지**: 세대를 올려(`halt`) 판단은 끝났지만 아직 보내지 않은 자동 실행을 실행 게이트 안에서 막고
   (`approval_guard`), 켜진 규칙을 모두 끈다. 이미 클라우드에 보낸 명령은 취소되지 않는다고 그대로 적는다.
6. **가열 종료 근거**(취소·문 열림과 구분 못 함 — 위 정책, 실측 기록표 §6)는 RPi4 ``appliance_done``(전자레인지 CT 채널 전력 끝, 입력에 ``power``)뿐이다. 실행
   끝(버튼 누름 완료)은 이 모듈에 오지 않는다.

**검증 수준: 모의 ThinQ·모의 클라우드 끝-끝까지. 실제 CT 판정·실가전 미검증.**
"""

from __future__ import annotations

import hashlib
import logging
import math
import os
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timedelta
from types import MappingProxyType
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
#: 사건 나이 상한(초) — RPi4가 끝을 본 뒤 이 허브가 보내기 직전까지(링크 지연 포함, 3차 평가 M1). **측정 필요**
#: (전자레인지 settle_s 10초 + 여유).
DEFAULT_MAX_EVENT_AGE_S = 120.0
#: 자동 실행 승인 1건의 유효 시간(초).
APPROVAL_SECONDS = 60
#: 실행 기록의 시나리오 ID 접두사(시나리오·루틴 트리거가 다시 깨우지 않게).
AUTO_SCENARIO_PREFIX = "auto:"
KIND_AUTO_RULE = "auto_rule"
CONDITION_BASIS = "ct_power_end"
MAX_SEEN_EVENTS = 500

ESTOP_REASON = "비상정지로 자동 실행을 껐어요."
ESTOP_NOTICE = ("비상정지로 자동 실행을 껐어요 — 새 자동 실행과 아직 보내지 않은 명령은 보내지 않아요. "
                "이미 ThinQ 클라우드로 보낸 명령은 취소되지 않아요(공기청정기를 되돌리거나 끄지 않아요)")
USER_OFF_REASON = "직접 자동 실행을 껐어요."
VALUE_CHANGED_REASON = "세기를 바꿔서 다시 허용해야 켜져요."
PHYSICAL_REFUSED = "버튼을 누르는 단계는 자동 실행할 수 없어요 — 매번 승인해 주세요"
#: 허용 요청을 처리하는 사이 전체 정지가 들어왔다(3차 평가 H2) — 이번 허용은 저장하지 않는다.
STOP_RACE_REASON = "허용하는 사이 정지가 들어와서 자동 실행을 켜지 않았어요."
#: 지난 프로세스가 깨끗이 닫히지 않았다(전원 끊김·강제 종료·규칙 저장 실패, 4차 평가 M-N3) — 정지의 규칙 끄기가 DB에
#: 닿기 전에 끝났을 수 있어 켜진 규칙을 믿지 않는다.
UNCLEAN_RESTART_REASON = "허브가 갑자기 꺼져서 자동 실행을 껐어요."
#: 재시작 뒤 불러온 허용인데 사건이 이 프로세스가 시작하기 전에 끝났다(4차 평가 M-N2) — 허용 전후를 단정하지 않는다.
RESTART_BOUNDARY_REASON = "허브가 다시 켜지기 전에 끝난 가열이라 자동 실행하지 않았어요."
#: 철회가 이미 전송을 시작한 자동 실행과 겹쳤다(4차 평가 H-N1) — 그 명령은 되돌리지 않는다.
IN_FLIGHT_NOTICE = ("자동 실행 명령을 이미 보내기 시작했어요 — 그 명령은 취소되지 않아요(공기청정기를 되돌리거나 끄지 않아요). "
                    "다음부터는 보내지 않아요")
#: 이 프로세스의 표시(세션). 규칙 DB의 세션 표시가 다른 프로세스 것이고 열려 있으면 지난 종료가 깨끗하지 않았다.
PROCESS_SESSION = uuid4().hex
#: 정지의 규칙 끄기를 뒤에서 DB에 쓸 때 다시 해 보는 횟수·간격(초).
PERSIST_ATTEMPTS = 3
PERSIST_RETRY_S = 1.0


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


def _josa_stem(word: str) -> str:
    """조사 고를 낱말 — 끝의 괄호 표기("(모의)")는 건너뛴다."""
    stem = word.strip()
    while stem.endswith(")") and "(" in stem:
        stem = stem[: stem.rindex("(")].rstrip()
    return stem


#: 대상 기능을 찾지 못했을 때 동작 이름 대신 보일 말(원시 이름을 화면에 내지 않는다).
ACTION_LABELS = {"set_wind_strength": "바람 세기", "set_job_mode": "운전 모드", "set_power": "전원"}


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
    """규칙 목록 — 서버 DB 설정 칸(``auto_rules``)이 있으면 재시작에도 남는다. 없으면 메모리.

    4차 평가 H-N2: **판정용 메모리와 영속 쓰기를 나눈다.** 규칙 목록은 불변 사본(``MappingProxyType``)을 통째로 바꿔
    끼우고(``put``·``remove``, 짧은 메모리 잠금), 읽기(``get``·``list``)는 지금 사본을 잠금 없이 본다. DB 쓰기(``flush``)는
    따로 잠금을 잡고 그때의 **가장 새 사본**을 쓴다(늦게 끝난 쓰기가 새 상태를 옛 상태로 덮지 않는다). 그래서 실행
    게이트(서비스 잠금 안)의 ``get``이 다른 요청의 DB 쓰기 대기에 묶이지 않는다 — 정지 경로가 서비스 잠금을 기다리지 않는다."""

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None, *,
                 session_load: Callable[[], str | None] | None = None,
                 session_save: Callable[[str], None] | None = None,
                 now: Callable[[], str] | None = None) -> None:
        import json  # noqa: PLC0415

        self._json = json
        self._save_fn = save
        self._session_save = session_save
        #: 메모리 사본 교체만(입출력 없음).
        self._mem_lock = threading.Lock()
        #: DB 쓰기 직렬화 — 이 잠금을 잡은 채 메모리 잠금을 기다리지 않는다(사본·판 번호만 짧게 읽는다).
        self._persist_lock = threading.Lock()
        rules: dict[str, AutoRule] = {}
        raw = load() if load is not None else None
        if raw:
            try:
                for item in json.loads(raw):
                    rule = AutoRule.from_dict(item)
                    rules[rule.rule_id] = rule
            except (ValueError, TypeError, KeyError):
                log.exception("auto rules unreadable; starting empty (자동 실행은 꺼진 것과 같다)")
                rules = {}
        self._rules: Mapping[str, AutoRule] = MappingProxyType(rules)
        self._version = 0
        self._persisted_version = 0
        #: 지난 프로세스가 깨끗이 닫히지 않아 이번 기동에서 끈 규칙 수(4차 평가 M-N3 내구성 경계).
        self.held_on_start = 0
        if session_load is not None or session_save is not None:
            self._open_session(session_load, now)

    # ── 내구성 경계(4차 평가 M-N3) ─────────────────────────────────────────────
    def _open_session(self, session_load, now) -> None:
        """정지의 규칙 끄기는 메모리에서 바로 효력을 내고 DB 쓰기는 뒤에서 한다. 그 쓰기가 끝나기 전에 프로세스가 죽으면
        DB에는 '켜짐'이 남는다 — 그래서 **깨끗이 닫히지 않은 지난 프로세스**(세션 표시가 열린 채, 다른 프로세스)의 켜진
        규칙은 이번 기동에서 끈다(다시 허용 필요). 깨끗한 종료(:meth:`close`)는 남은 쓰기를 마친 뒤에만 표시를 닫는다."""
        raw = None
        try:
            raw = session_load() if session_load is not None else None
        except Exception:  # noqa: BLE001
            log.exception("auto rule session marker unreadable — 지난 종료를 모르므로 켜진 규칙을 끈다")
            raw = '{"open": true, "session": null}'
        marker = None
        if raw:
            try:
                marker = self._json.loads(raw)
            except ValueError:
                marker = {"open": True, "session": None}
        unclean = isinstance(marker, dict) and marker.get("open") is not False \
            and marker.get("session") != PROCESS_SESSION
        if unclean:
            stamp = now() if now is not None else None
            held = [r for r in self._rules.values() if r.enabled]
            for rule in held:
                self.put(replace(rule, enabled=False, updated_at=stamp, disabled_reason=UNCLEAN_RESTART_REASON))
            self.held_on_start = len(held)
            if held:
                log.warning("auto rules: previous process did not close cleanly — %d rule(s) held off", len(held))
                try:
                    self.flush()
                except Exception:  # noqa: BLE001 -- 메모리는 꺼짐. 다음 깨끗한 종료 전까지 표시는 열려 있다
                    log.exception("auto rules: could not persist the restart hold")
        self._write_session(open_=True)

    def _write_session(self, *, open_: bool) -> bool:
        if self._session_save is None:
            return True
        try:
            self._session_save(self._json.dumps({"open": open_, "session": PROCESS_SESSION}))
            return True
        except Exception:  # noqa: BLE001
            log.exception("auto rule session marker write failed")
            return False

    def close(self, timeout_s: float = 5.0) -> bool:
        """깨끗한 종료 — 남은 규칙 쓰기를 ``timeout_s`` 안에 마쳤을 때만 세션 표시를 닫는다(다음 기동이 규칙을 믿는다).
        쓰기가 멈췄거나 실패하면 표시를 열어 둔다 → 다음 기동은 켜진 규칙을 끈다. 닫았으면 True."""
        done = threading.Event()
        ok: list[bool] = []

        def flush() -> None:
            try:
                self.flush()
                ok.append(not self.pending())
            except Exception:  # noqa: BLE001
                log.exception("auto rules: final flush failed — 다음 기동에서 켜진 규칙을 끈다")
            finally:
                done.set()

        threading.Thread(target=flush, name="auto-rule-close", daemon=True).start()
        if not done.wait(timeout_s) or not ok or not ok[0]:
            return False
        return self._write_session(open_=False)

    # ── 읽기: 잠금 없음(불변 사본) ─────────────────────────────────────────────
    def list(self) -> tuple[AutoRule, ...]:
        return tuple(self._rules.values())

    def get(self, rule_id: str) -> AutoRule | None:
        return self._rules.get(rule_id)

    # ── 메모리 바꾸기(즉시 효력) ─────────────────────────────────────────────
    def put(self, rule: AutoRule) -> AutoRule:
        with self._mem_lock:
            rules = dict(self._rules)
            rules[rule.rule_id] = rule
            self._rules = MappingProxyType(rules)
            self._version += 1
        return rule

    def remove(self, rule_id: str) -> bool:
        with self._mem_lock:
            if rule_id not in self._rules:
                return False
            rules = dict(self._rules)
            del rules[rule_id]
            self._rules = MappingProxyType(rules)
            self._version += 1
        return True

    # ── 영속 ────────────────────────────────────────────────────────────────
    def flush(self) -> None:
        """지금 메모리 사본을 DB에 쓴다(이미 쓴 판이면 아무것도 안 함). 실패는 예외로 올린다(메모리는 그대로)."""
        with self._persist_lock:
            with self._mem_lock:
                rules, version = self._rules, self._version
            if version <= self._persisted_version:
                return
            if self._save_fn is not None:
                self._save_fn(self._json.dumps([r.to_dict() for r in rules.values()], ensure_ascii=False))
            self._persisted_version = version

    def pending(self) -> bool:
        """메모리에만 있고 아직 DB에 쓰지 못한 변경이 있다."""
        with self._mem_lock:
            return self._version > self._persisted_version

    def save(self, rule: AutoRule) -> AutoRule:
        self.put(rule)
        self.flush()
        return rule

    def delete(self, rule_id: str) -> bool:
        removed = self.remove(rule_id)
        if removed:
            self.flush()
        return removed


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


#: 신선도 근거가 없을 때(3차 평가 M1) — 보류가 기본이다.
NO_FRESHNESS_REASON = ("가열 종료 시각을 이 허브 시계로 확인할 근거가 없어(연결이 바뀌었거나 옛 RPi4) "
                       "자동 실행하지 않았어요")


def event_age_s(record: Mapping, now_mono_s: float) -> float | None:
    """사건 나이(초) — 받을 때 이 허브 단조 시계로 옮겨 둔 끝 시각(``event_end_mono_s``)부터 ``now_mono_s``까지.

    옮길 근거가 없었으면(``None``) 또는 1초 넘게 미래면(근거가 어긋남) None — 자동 실행은 보류한다(3차 평가 M1)."""
    end = record.get("event_end_mono_s")
    if not isinstance(end, (int, float)) or isinstance(end, bool) or not math.isfinite(end):
        return None
    age = now_mono_s - float(end)
    return max(age, 0.0) if age >= -1.0 else None


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
                 max_event_age_s: float = DEFAULT_MAX_EVENT_AGE_S,
                 monotonic: Callable[[], float] | None = None,
                 started: Callable[[], float] | None = None) -> None:
        self.store = store
        #: 이 허브의 단조 시계 — 사건 끝 시각을 옮긴 시계와 같아야 한다(기본: rpi/services/event_clock.py).
        self._monotonic = monotonic or _hub_monotonic
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
        #: 이 프로세스에서 규칙이 허용된 세대(3차 평가 H2, 메모리). 지금 세대와 다르면 저장된 '켜짐'이어도 쓰지 않는다 —
        #: 정지(세대 올림)가 규칙 끄기 저장보다 먼저 끝나거나, 정지 전에 시작한 허용 요청이 정지 뒤에 저장해도 켜지지 않는다.
        #: 재시작 직후 불러온 규칙은 세대 0(아직 정지 없음)으로 본다.
        self._allowed_generation: dict[str, int] = {}
        #: 이 프로세스에서 규칙을 허용한 허브 단조 시각(4차 평가 M-N2, 메모리). 없으면 재시작 뒤 불러온 허용이다.
        self._allowed_mono: dict[str, float] = {}
        #: 이 프로세스가 시작한 허브 단조 시각 — 사건 끝 시각을 옮긴 시계와 같은 축.
        self._started = started or (_hub_started if monotonic is None else (lambda value=self._monotonic(): value))
        self._runs: deque[dict] = deque(maxlen=50)
        #: 기록보다 먼저 끝난 자동 실행의 결과(job_id → 완료 이벤트).
        self._early_results: dict[str, object] = {}
        #: 보내기 직전 재검사에 걸린 자동 실행(규칙:사건 키 → 이유). 결과가 오면 기록을 '막힘'으로 고친다.
        self._dispatch_blocked: dict[str, str] = {}
        #: 전송권(4차 평가 H-N1) — 전송 개시 표시와 철회를 직렬화하는 메모리 잠금. 입출력·다른 잠금 대기 없음.
        self._send_lock = threading.Lock()
        #: 전송을 시작한 규칙(규칙 ID → 규칙:사건 키). job이 끝나면 지운다.
        self._sending: dict[str, str] = {}

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
        # 그 단서('조리 완료가 아닐 수 있어요')는 허용 확인 시트(폰)에만 둔다 — 목록·카드 문장은 짧게(2026-10-14 UX).
        name = self._name(rule.condition_appliance_id)
        return f"{name}{_josa(_josa_stem(name), '이', '가')} 멈추면"

    def action_text(self, rule: AutoRule) -> str:
        name = self._name(rule.target_appliance_id)
        appliance = self._appliance(rule.target_appliance_id)
        binding = getattr(appliance, "thinq", None)
        try:
            cap = binding.capability(rule.action) if binding is not None else None
        except Exception:  # noqa: BLE001 -- 대상이 바뀌었으면 동작 이름만
            cap = None
        if cap is None:
            # 원시 동작 이름(set_wind_strength HIGH)을 화면에 내지 않는다(2026-10-14 UX).
            label = ACTION_LABELS.get(rule.action, "설정")
            return f"{name} {label} 변경(대상 가전을 다시 골라 주세요)"
        value = cap.value_label(str(rule.value))
        if rule.action == "set_power":
            return f"{name} 전원 {value}"
        return f"{name} {cap.label} {value}{_josa(value, '으로', '로')}"

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

    # ── 정지 세대 ───────────────────────────────────────────────────────────
    def generation(self) -> int:
        """지금 정지 세대. 허용 요청은 시작할 때 이 값을 잡아 저장 단계까지 넘긴다(3차 평가 H2)."""
        with self._gen_lock:
            return self._generation

    def _generation_ok(self, rule: AutoRule) -> bool:
        """규칙이 지금 정지 세대에서 허용된 것인가(메모리 판정, 입출력 없음)."""
        with self._gen_lock:
            return self._allowed_generation.get(rule.rule_id, 0) == self._generation

    def _allowed_boundary(self, rule: AutoRule) -> tuple[float, bool]:
        """허용 전후를 가르는 허브 단조 시각과 '재시작 뒤 불러온 허용인가'(4차 평가 M-N2). 이 프로세스에서 허용했으면 그
        순간, 아니면(DB에서 불러옴) 이 프로세스가 시작한 순간 — 재시작 전에 끝난 가열은 허용 전후를 단정하지 않고 보류."""
        with self._gen_lock:
            allowed = self._allowed_mono.get(rule.rule_id)
        if allowed is not None:
            return allowed, False
        return self._started(), True

    def usable(self, rule: AutoRule) -> bool:
        """저장된 허용(켜짐·지문 일치)이고 그 뒤로 정지가 없었다."""
        return rule.allowed and self._generation_ok(rule)

    def _save_allowed(self, rule: AutoRule, start_generation: int | None) -> AutoRule:
        """허용 저장 — 요청 시작 세대와 지금 세대를 저장 앞뒤로 대조한다. 정지가 끼면 켜지 않고 409.

        세대 판정은 메모리에서만 한다(정지 경로의 ``halt``는 이 저장의 DB 쓰기를 기다리지 않는다). 저장 전에 이 규칙의 허용
        세대를 **요청 시작 세대**로 적어 두므로, 저장 도중 정지가 들어와도 저장된 '켜짐'은 쓰이지 않고, 저장 뒤 다시 대조해
        꺼진 상태로 되돌린다."""
        generation = self.generation() if start_generation is None else start_generation
        allowed_mono = self._monotonic()
        with self._gen_lock:
            if self._generation != generation:
                raise AutoRuleError(409, STOP_RACE_REASON)
            self._allowed_generation[rule.rule_id] = generation
            self._allowed_mono[rule.rule_id] = allowed_mono
        self.store.save(rule)
        if self.generation() != generation:
            self.store.save(replace(rule, enabled=False, updated_at=self._clock.now().isoformat(),
                                    disabled_reason=ESTOP_REASON))
            raise AutoRuleError(409, STOP_RACE_REASON)
        return rule

    def allow_from_offer(self, draft: AutoRule, start_generation: int | None = None) -> AutoRule:
        """확인 화면에서 허용한 내용을 규칙으로 저장한다. 같은 조건·대상·동작의 규칙이 있으면 바꾼다.

        ``start_generation``: 허용 요청을 시작할 때의 정지 세대(:meth:`generation`). 그 뒤 전체 정지가 들어왔으면
        저장하지 않고(또는 꺼진 상태로 되돌리고) ``AutoRuleError(409)`` — 이번 실행과는 따로 알린다(3차 평가 H2)."""
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
        self._save_allowed(rule, start_generation)
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
            # 정지 뒤(세대가 바뀐 뒤)로 다시 허용받지 않은 규칙은 저장된 '켜짐'이어도 맡지 않는다(3차 평가 H2).
            if not (rule.enabled and self._generation_ok(rule) and self._matches(rule, record)):
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
        # ⑥ 가열 종료 근거 = CT 전력 끝(취소·문 열림 종료도 같게 온다 — 정책상 허용, 문구로 밝힘).
        if "power" not in (record.get("inputs") or []):
            return self._record(rule, record, key, "blocked",
                                "가열 종료가 콘센트 전력(CT)으로 감지되지 않아 자동 실행하지 않았어요")
        # ③ 같은 사건·오래된 사건 — 나이는 이 허브 시계로 옮긴 끝 시각부터 지금까지(링크 지연 포함, 3차 평가 M1).
        age = event_age_s(record, self._monotonic())
        if key is None or age is None:
            return self._record(rule, record, key, "blocked", NO_FRESHNESS_REASON)
        if age > self._max_age:
            return self._record(rule, record, key, "blocked",
                                f"오래된 가열 종료({age:.0f}초 전)라 자동 실행하지 않았어요")
        # 4차 평가 M-N2: 허용 전후는 같은 허브 단조 시계 축에서만 가른다(벽시계 보정·NTP에 흔들리지 않게). 이 프로세스에서
        # 허용했으면 그 순간, 재시작 뒤 불러온 허용이면 이 프로세스가 시작한 순간이 경계 — 그 전에 끝난 가열은 보류한다.
        boundary, restarted = self._allowed_boundary(rule)
        if float(record["event_end_mono_s"]) < boundary:
            return self._record(rule, record, key, "blocked",
                                RESTART_BOUNDARY_REASON if restarted
                                else "허용하기 전에 끝난 가열이라 자동 실행하지 않았어요")
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
        # 3차 평가 M2: 이 job이 보낼 대상·동작·설정값의 불변 사본 — 결과 기록·알림·키오스크 문구는 이것만 쓴다.
        # 보낸 뒤 규칙을 바꾸거나 지우거나 대상 이름이 바뀌어도 결과를 현재 규칙으로 다시 읽어 덮지 않는다.
        snapshot = {**self._target_words(rule), "action": rule.action, "value": rule.value,
                    "action_text": self.action_text(rule)}
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
            # 4차 평가 H-N2: 메모리 사본만 읽는다(``store.get``은 잠금 없음) — 다른 요청의 규칙 DB 쓰기를 기다리지 않으므로
            # 이 게이트를 품은 서비스 잠금도, 그 잠금을 잡아야 하는 정지(``request_stop``)도 DB에 묶이지 않는다.
            with self._gen_lock:
                if self._generation != generation:
                    raise AutoRuleBlocked("비상정지로 아직 보내지 않은 자동 실행을 보내지 않았어요")
            current = self.store.get(rule.rule_id)
            if current is None or not self.usable(current):
                raise AutoRuleBlocked("자동 실행이 꺼져 보내지 않았어요")
            if current.fingerprint() != decided:
                raise AutoRuleBlocked("자동 실행 설정이 바뀌어 이전 내용을 보내지 않았어요")
            # 전송 대기 중 만료(3차 평가 M1) — 판단 뒤 조회·대기로 상한을 넘겼으면 보내지 않는다.
            age = event_age_s(record, self._monotonic())
            if age is None or age > self._max_age:
                raise AutoRuleBlocked(
                    f"가열 종료 뒤 {age:.0f}초가 지나 보내지 않았어요" if age is not None else NO_FRESHNESS_REASON)

        def blocked(exc: AutoRuleBlocked) -> None:
            with self._lock:
                self._dispatch_blocked[block_key] = str(exc)

        def commit() -> None:
            # 4차 평가 H-N1: 전송권 — 실행기가 정지 확인과 같은 잠금 안에서 POST 바로 앞에 부른다. 철회(끄기·값 바꾸기·
            # 삭제·비상정지의 규칙 끄기)와 같은 잠금(``_send_lock``, 메모리만)으로 직렬화한다: 철회가 먼저 끝났으면 여기서
            # 걸려 보내지 않고, 여기를 지났으면 '전송 개시'로 표시해 그 뒤의 철회는 '이미 보내는 중'임을 안다.
            # 네트워크 응답까지 잠그지 않는다(표시만 남기고 곧바로 놓는다).
            with self._send_lock:
                try:
                    guard()
                except AutoRuleBlocked as exc:
                    blocked(exc)
                    raise
                self._sending[rule.rule_id] = block_key

        def dispatch_guard(binding=None):
            # 보내기 직전(실행 스레드) 재검사 — 시작 게이트 뒤에 꺼지거나 바뀌었으면 보내지 않는다. 실행기는 프로필·상태
            # 조회를 마친 뒤 이번에 보낼 대상 바인딩을 넘겨 한 번 더 부른다(3차 평가 H1): 그 대상이 판단 때 결속한 기기
            # (기기 키·종류)와 다르면 보내지 않는다. 메모리 판정만(입출력 없음). 바인딩과 함께 불렸으면 전송권 확인
            # (``commit``)을 돌려준다 — 실행기가 POST 바로 앞에서 부른다(4차 평가 H-N1).
            try:
                guard()
                if binding is not None and (
                        getattr(binding, "device_type", None) != rule.target_device_type
                        or _device_key(getattr(binding, "device_id", "")) != rule.target_device_key):
                    raise AutoRuleBlocked("대상 공기청정기가 판단 때와 달라 보내지 않았어요")
            except AutoRuleBlocked as exc:
                blocked(exc)
                raise
            return commit if binding is not None else None

        try:
            job_id = self.service.submit_approved(
                (approved,), purpose=f"자동 실행 · {self.action_text(rule)}",
                usage_source=UsageSource.SUGGESTION, approval_guard=guard,
                scenario_id=f"{AUTO_SCENARIO_PREFIX}{rule.rule_id}", dispatch_guard=dispatch_guard,
            )
        except AutoRuleBlocked as exc:
            return self._record(rule, record, key, "blocked", str(exc), snapshot=snapshot)
        except Exception as exc:  # noqa: BLE001 -- 시작 못 함. 나중에 다시 보내지 않는다.
            text = str(exc)
            reason = ("다른 작업이 실행 중이라 자동 실행하지 않았어요 — 나중에 다시 보내지 않아요"
                      if "already in progress" in text
                      else f"자동 실행을 시작하지 못했어요 — {text or type(exc).__name__}")
            return self._record(rule, record, key, "blocked", reason, snapshot=snapshot)
        return self._record(rule, record, key, "sent", "허용한 조건이라 승인 없이 보냈어요", job_id=job_id,
                            notices=[self._cook_notice(rule, record)], snapshot=snapshot)

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
        with self._send_lock:
            self._sending.pop(scenario_id[len(AUTO_SCENARIO_PREFIX):], None)
        with self._lock:
            entry = next((e for e in reversed(self._runs) if e.get("job_id") == event.job_id), None)
            if entry is None:
                # 실행이 기록보다 먼저 끝났다(제출 직후 끝난 모의 실행) — 기록할 때 붙인다.
                self._early_results[event.job_id] = event
                return
            self._apply_result_locked(entry, event)
        self._notify(entry)

    def _apply_result_locked(self, entry: dict, event) -> None:
        # 3차 평가 M2: 대상·설정 낱말은 job을 만들 때 entry에 넣은 사본 그대로 — 지금 규칙을 다시 읽지 않는다.
        blocked = self._dispatch_blocked.pop(f"{entry['rule_id']}:{entry.get('event_key')}", None)
        if blocked is not None and event.receipt.value == "not_dispatched":
            notice = blocked
            entry.update({"outcome": "blocked", "reason": blocked})
        else:
            notice = self._result_notice(entry, event)
        entry.update({"status": event.status, "receipt": event.receipt.value,
                      "confirmation": event.confirmation.value,
                      "execution_mode": event.execution_mode.value,
                      "notices": [*entry.get("notices", []), notice]})

    def _target_words(self, rule: AutoRule | None) -> dict:
        """키오스크 알림용 낱말(대상 이름·설정 이름·값 이름). 모르면 None — 지어내지 않는다."""
        if rule is None:
            return {"target_name": None, "setting_label": None, "value_label": None}
        words = {"target_name": self._name(rule.target_appliance_id), "setting_label": None, "value_label": None}
        try:
            cap = self._appliance(rule.target_appliance_id).thinq.capability(rule.action)
            words["setting_label"] = cap.label
            words["value_label"] = cap.value_label(str(rule.value))
        except Exception:  # noqa: BLE001 -- 대상이 바뀌었으면 이름만
            pass
        return words

    def last_result_payload(self) -> dict | None:
        """결과가 나온 마지막 자동 실행(키오스크 짧은 알림, 2026-10-14). 없으면 None.

        보낸 실행만(막힌 판단은 job이 없다). 키오스크는 ``job_id``가 바뀔 때 한 번 알린다."""
        with self._lock:
            entry = next((e for e in reversed(self._runs) if e.get("job_id") and e.get("status")), None)
            if entry is None:
                return None
            return {key: entry.get(key) for key in (
                "job_id", "at", "outcome", "status", "receipt", "confirmation", "execution_mode",
                "target_name", "setting_label", "value_label")}

    def _notify(self, entry: dict) -> None:
        if self._care is None:
            return
        try:
            for text in entry["notices"]:
                self._care.append(KIND_AUTO_RULE, text, purpose=entry.get("action_text"))
        except Exception:  # noqa: BLE001
            log.exception("auto rule care notice failed")

    def _result_notice(self, entry: dict, event) -> str:
        # job을 만들 때의 사본(3차 평가 M2). 사본에 없으면 일반 낱말 — 지금 규칙으로 지어내지 않는다.
        name = entry.get("target_name") or "공기청정기"
        label = entry.get("setting_label") or "설정"
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
        """세대를 올리고 켜진 규칙을 모두 끈다. 끈 개수.

        4차 평가 M-N3: 끄기는 **메모리에서 바로** 효력을 내고(판정·목록이 곧바로 '꺼짐'), DB 쓰기와 알림함 기록은 뒤에서
        한다 — ``/stop`` 응답이 DB 쓰기를 기다리지 않는다. 쓰기가 끝나기 전에 프로세스가 죽으면 다음 기동이 세션 표시로
        알아채고 켜진 규칙을 끈다(:class:`AutoRuleStore` 내구성 경계)."""
        self.halt()
        now = self._clock.now().isoformat()
        with self._send_lock:  # 전송권과 직렬화(4차 평가 H-N1) — 메모리만
            disabled = [r for r in self.store.list() if r.enabled]
            for rule in disabled:
                self.store.put(replace(rule, enabled=False, updated_at=now, disabled_reason=ESTOP_REASON))
        if disabled:
            entry = {"at": now, "rule_id": disabled[0].rule_id, "outcome": "estop", "reason": ESTOP_NOTICE,
                     "event_key": None, "event_source": None, "job_id": None, "notices": [ESTOP_NOTICE],
                     "trigger": reason}
            with self._lock:
                self._runs.append(entry)
        self._persist_later(ESTOP_NOTICE if disabled else None)
        return len(disabled)

    def _persist_later(self, notice: str | None = None) -> threading.Thread:
        """메모리 변경을 뒤에서 DB에 쓴다(몇 번 다시 해 본다). 끝까지 못 쓰면 메모리는 그대로 두고 기록만 남긴다 —
        세션 표시가 열려 있어 다음 기동이 켜진 규칙을 끈다."""

        def run() -> None:
            for attempt in range(PERSIST_ATTEMPTS):
                try:
                    self.store.flush()
                    break
                except Exception:  # noqa: BLE001
                    log.exception("auto rules: background persist failed (attempt %d)", attempt + 1)
                    time.sleep(PERSIST_RETRY_S)
            if notice is not None and self._care is not None:
                try:
                    self._care.append(KIND_AUTO_RULE, notice, purpose="자동 실행")
                except Exception:  # noqa: BLE001
                    log.exception("auto rule estop notice failed")

        thread = threading.Thread(target=run, name="auto-rule-persist", daemon=True)
        thread.start()
        return thread

    def close(self, timeout_s: float = 5.0) -> bool:
        """서버 종료 — 남은 규칙 쓰기를 마치고 세션 표시를 닫는다(:meth:`AutoRuleStore.close`)."""
        return self.store.close(timeout_s)

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

    def _revoke(self, rule_id: str, change: Callable[[AutoRule], AutoRule | None],
                report: dict | None) -> AutoRule | None:
        """철회(끄기·값 바꾸기·삭제) — 전송권 잠금 안에서 메모리를 바꿔(4차 평가 H-N1) 그 뒤의 전송 개시를 막고, 이미 전송을
        시작했으면 ``report["in_flight"]``로 알린다. DB 쓰기는 잠금 밖에서."""
        with self._send_lock:
            current = self.store.get(rule_id)
            if current is None:
                raise AutoRuleError(404, "자동 실행 규칙을 찾을 수 없어요")
            in_flight = rule_id in self._sending
            changed = change(current)
            if changed is None:
                self.store.remove(rule_id)
            elif changed is not current:
                self.store.put(changed)
        if report is not None:
            report["in_flight"] = in_flight
            report["in_flight_notice"] = IN_FLIGHT_NOTICE if in_flight else None
        self.store.flush()
        return changed

    def set_enabled(self, rule_id: str, enabled: bool, fingerprint: str | None = None,
                    start_generation: int | None = None, report: dict | None = None) -> AutoRule:
        """끄기·다시 허용. 다시 허용은 요청 시작 세대(``start_generation``)를 저장 단계까지 대조한다(3차 평가 H2).
        ``report``(선택): 끄기가 이미 전송을 시작한 자동 실행과 겹쳤는지(4차 평가 H-N1)."""
        rule = self._require(rule_id)
        now = self._clock.now().isoformat()
        if not enabled:
            return self._revoke(rule_id, lambda r: replace(r, enabled=False, updated_at=now,
                                                           disabled_reason=USER_OFF_REASON), report)
        rebound = self._rebound(rule)
        if rebound is None or self._appliance(rule.condition_appliance_id) is None:
            raise AutoRuleError(409, "대상 가전을 찾지 못해 켤 수 없어요 — 가전 연결을 확인해 주세요")
        if fingerprint != rebound.fingerprint():
            raise AutoRuleError(409, "허용할 내용이 바뀌었어요 — 조건과 동작을 다시 확인해 주세요")
        return self._save_allowed(replace(rebound, enabled=True, allowed_fingerprint=fingerprint,
                                          allowed_at=now, updated_at=now, disabled_reason=None), start_generation)

    def update(self, rule_id: str, body: Mapping, report: dict | None = None) -> AutoRule:
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
            if report is not None:
                report.update(in_flight=False, in_flight_notice=None)
            return rule
        now = self._clock.now().isoformat()
        return self._revoke(rule_id, lambda r: replace(r, value=value, enabled=False, allowed_fingerprint=None,
                                                       updated_at=now, disabled_reason=VALUE_CHANGED_REASON),
                            report)

    def delete(self, rule_id: str, report: dict | None = None) -> None:
        self._revoke(rule_id, lambda _r: None, report)

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
            "enabled": self.usable(rule),
            "status_label": "자동 실행 켜짐" if self.usable(rule) else "자동 실행 꺼짐",
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
                job_id: str | None = None, notices: list[str] | None = None, reoffer: bool = False,
                snapshot: Mapping | None = None) -> dict:
        entry = {
            "at": self._clock.now().isoformat(), "rule_id": rule.rule_id, "outcome": outcome,
            "reason": reason, "event_key": key, "event_source": record.get("source"),
            "event_state": record.get("state"), "job_id": job_id, "notices": list(notices or []),
            "action_text": self.action_text(rule),
        }
        if snapshot is not None:
            # job을 만들 때 잡은 사본(대상 이름·설정 이름·값 이름·동작·값·동작 문장) — 결과가 와도 덮지 않는다.
            entry.update(snapshot)
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


def _hub_monotonic() -> float:
    from rpi.services.event_clock import get_event_clock  # noqa: PLC0415

    return get_event_clock().monotonic()


def _hub_started() -> float:
    from rpi.services.event_clock import get_event_clock  # noqa: PLC0415

    return get_event_clock().started_s


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
