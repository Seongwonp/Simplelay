"""사용 기록 → 루틴 초안(2026-10-14, 사용자 승인 4번 — UI 동결 예외, 범위 제한).

가전 사용 기록 분석(``PatternDetector``)이 찾은 반복 순서를 **가전·버튼 순서가 채워진 초안**으로 돌려준다.
사용자는 이름과 '직접 실행할 때만 / 정해진 때 물어보기'만 고르고 확인한 뒤 저장한다. 빈 폼은 없다.

경계(서로 다른 동의를 한 번에 받지 않는다):

- **저장만 한다.** 이 모듈은 실행 서비스의 실행 진입점을 부르지 않고 제안 카드도 만들지 않는다.
  저장한 루틴은 승인 루틴(``mode=approve``)이라 실행은 늘 카드 승인 뒤다.
- 자동 실행 허용은 만들지 않는다. 버튼 누름(물리) 초안은 자동 실행 규칙 대상도 아니다.
- ThinQ 초안(2026-10-16): 직접 쓴 **낮은 위험** ThinQ 목적 문장(``auto_rules.is_low_risk`` — 공기청정기 켜기·풍량·운전 모드)만
  ThinQ 명령 한 단계짜리 초안이 되고, '정해진 때 물어보기'(기록 시각 대표값)가 먼저 나온다. 저장한 시각 루틴의 카드에서
  사용자가 따로 '다음부터도 자동으로'를 골라야 자동 실행이 생긴다(이 모듈은 만들지 않는다).
- 근거는 패턴 감지기의 근거 그대로다(성공·실제 실행·직접 사용만 — 모의·추천받아 실행한 기록 제외).
  누가 썼는지 모르므로 문장은 가전 사용 기록으로만 말한다("최근 28일 중 아침에 4일 사용했어요").
- 같은 가전·같은 버튼 순서(ThinQ는 같은 동작·인자)의 루틴이 이미 있으면 초안으로 보이지 않고 저장도 409.
- 저장한 초안은 다시 보이지 않는다(루틴을 지워도). 거절한 초안은 ``DECLINE_DAYS``일 동안 보이지 않는다.
- '다시 받지 않기'로 내린 목적은 보이지 않는다.
- 쉬는 동안(잠시 쉬기·매일 조용한 시간 — 둘 다 같게, 2026-10-14 통일): **기존 초안은 사용자가 루틴 탭을 직접 열면
  보이고 저장할 수 있다**(이 목록은 팝업·소리·화면 전환을 만들지 않는다). **새 초안은 쉬는 동안 만들지 않는다** —
  '기존'은 쉬지 않을 때 이 목록에 한 번 내놓은 초안(``ISSUED_SETTING``에 영속)이고, 쉬는 동안 처음 성립한 반복은
  끝난 뒤 목록에 나온다.
"""

from __future__ import annotations

import hashlib
import json
import logging
import threading
from datetime import datetime, timedelta

from rpi.commands import ControlRoute, canonical_json

from .model import RoutineValidationError, build_routine, compile_commands, validate_against

log = logging.getLogger(__name__)

DECLINE_DAYS = 14
DECISIONS_SETTING = "routine_candidate_decisions"
ISSUED_SETTING = "routine_candidate_issued"
RUN_CHOICES = ("manual", "ask_at_time")
SAVE_NOTICE = "저장만으로는 실행하지 않아요. 실행은 매번 승인을 받아요. 자동 실행은 켜지지 않아요."


class CandidateError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class CandidateDecisions:
    """초안별 사용자 판단(saved·declined). DB가 있으면 설정 키 하나에 JSON으로 남는다."""

    def __init__(self, load=None, save=None) -> None:
        self._save = save
        self.lock = threading.Lock()
        self._data: dict[str, dict] = {}
        if load is not None:
            try:
                raw = load()
                parsed = json.loads(raw) if raw else {}
                if isinstance(parsed, dict):
                    self._data = {k: v for k, v in parsed.items() if isinstance(v, dict)}
            except (ValueError, TypeError):
                log.exception("routine candidate decisions unreadable; starting empty")

    def get(self, key: str) -> dict | None:
        return self._data.get(key)

    def put(self, key: str, value: dict) -> None:
        data = {**self._data, key: value}
        if self._save is not None:
            self._save(json.dumps(data, ensure_ascii=False))
        self._data = data


def candidate_key(appliance_id: str, buttons: tuple[str, ...]) -> str:
    payload = canonical_json({"appliance_id": appliance_id, "buttons": list(buttons)})
    return "hc-" + hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


class RoutineCandidates:
    def __init__(self, *, detector, revision_options, registry, store, decisions: CandidateDecisions,
                 clock, is_quiet=lambda: False, is_muted=lambda purpose: False,
                 issued: CandidateDecisions | None = None) -> None:
        self._detector = detector
        self._revision_options = revision_options
        self._registry = registry
        self._store = store
        self._decisions = decisions
        self._clock = clock
        self._is_quiet = is_quiet
        #: 쉬지 않을 때 한 번 내놓은 초안 키 → 처음 내놓은 시각. 쉬는 동안엔 여기 있는 초안만 보인다.
        self._issued = issued if issued is not None else CandidateDecisions()
        self._is_muted = is_muted

    # ── 목록 ──────────────────────────────────────────────────────────────
    def list(self) -> list[dict]:
        now = self._clock.now()
        try:
            quiet = bool(self._is_quiet())
        except Exception:  # noqa: BLE001 -- 판정 실패는 쉬는 쪽(새 초안을 내놓지 않음, 기존 초안은 보임)
            log.exception("quiet check failed for routine candidates")
            quiet = True
        drafts = []
        for draft in self._raw_drafts().values():
            if self._existing_same(draft) is not None:
                continue
            decision = self._decisions.get(draft["key"])
            if decision is not None and not self._decision_expired(decision, now):
                continue
            if self._issued.get(draft["key"]) is None:
                if quiet:
                    continue  # 쉬는 동안 새 초안은 만들지 않는다
                with self._issued.lock:
                    if self._issued.get(draft["key"]) is None:
                        self._issued.put(draft["key"], {"at": now.isoformat()})
            drafts.append(draft)
        return drafts

    def for_habit(self, purpose: str, appliance_id: str | None) -> dict | None:
        """습관 카드(같은 목적·가전)에서 바로 루틴으로 저장할 수 있는 초안(2026-10-25 — 묻기에서 맡기기로 가는 다리).
        목록과 같은 거름(이미 저장·거절·같은 루틴)을 거친다. 없으면 None."""
        if not appliance_id:
            return None
        wanted = purpose.strip()
        return next((d for d in self.list()
                     if d.get("purpose") == wanted and d.get("appliance_id") == appliance_id), None)

    # ── 저장 ──────────────────────────────────────────────────────────────
    def save(self, key: str, body: dict):
        if not isinstance(body, dict):
            raise CandidateError(422, "저장 형식이 맞지 않아요")
        run = body.get("run")
        if run not in RUN_CHOICES:
            raise CandidateError(422, "언제 실행할지 골라 주세요 (직접 실행할 때만 · 정해진 때 물어보기)")
        with self._decisions.lock:
            draft = self._raw_drafts().get(key)
            if draft is None:
                raise CandidateError(404, "이 루틴 초안을 찾을 수 없어요 — 목록을 새로 고쳐 주세요")
            decision = self._decisions.get(key)
            if decision is not None and decision.get("state") == "saved":
                raise CandidateError(409, "이미 루틴으로 저장한 초안이에요")
            same = self._existing_same(draft)
            if same is not None:
                what = "동작" if draft["steps"][0]["kind"] == "thinq_command" else "버튼 순서"
                raise CandidateError(409, f"같은 가전·{what}의 루틴이 이미 있어요: '{same.name}'")
            trigger = ({"kind": "manual"} if run == "manual"
                       else {"kind": "time", "days": list(range(7)), "time": draft["ask_time"]})
            now = self._clock.now()
            try:
                routine = build_routine(
                    {"name": body.get("name"), "steps": draft["steps"], "trigger": trigger, "mode": "approve"},
                    routine_id=self._store.new_id(), now=now)
                validate_against(routine, self._registry,
                                 known_routine_ids=[r.routine_id for r in self._store.list()])
            except RoutineValidationError as exc:
                raise CandidateError(422, str(exc)) from exc
            self._store.save(routine)
            self._decisions.put(key, {"state": "saved", "at": now.isoformat(),
                                      "routine_id": routine.routine_id})
            return routine

    def decline(self, key: str) -> datetime:
        with self._decisions.lock:
            if key not in self._raw_drafts():
                raise CandidateError(404, "이 루틴 초안을 찾을 수 없어요 — 목록을 새로 고쳐 주세요")
            now = self._clock.now()
            self._decisions.put(key, {"state": "declined", "at": now.isoformat()})
            return now + timedelta(days=DECLINE_DAYS)

    # ── 내부 ──────────────────────────────────────────────────────────────
    @staticmethod
    def _decision_expired(decision: dict, now: datetime) -> bool:
        if decision.get("state") != "declined":
            return False  # 저장한 초안은 다시 보이지 않는다
        try:
            at = datetime.fromisoformat(decision.get("at"))
        except (TypeError, ValueError):
            return False
        return now >= at + timedelta(days=DECLINE_DAYS)

    def _raw_drafts(self) -> dict[str, dict]:
        """판단·중복을 보기 전의 초안들. 같은 가전·버튼 순서는 근거가 가장 강한 시간대 하나로 묶는다."""
        drafts: dict[str, dict] = {}
        for candidate, ask_time in self._detector.established():
            if candidate.appliance_id is None or self._is_muted(candidate.purpose):
                continue
            appliance = self._registry.get(candidate.appliance_id) if self._registry is not None else None
            if appliance is None:
                continue
            if appliance.control_path is ControlRoute.THINQ:
                self._thinq_draft(drafts, candidate, ask_time, appliance)
                continue
            if appliance.control_path is not ControlRoute.PHYSICAL:
                continue
            try:
                buttons = self._revision_options(candidate.appliance_id).get(candidate.purpose)
            except Exception:  # noqa: BLE001 -- 해석 실패는 초안 없음
                log.exception("routine candidate button lookup failed")
                buttons = None
            if not buttons:
                continue  # 버튼 순서를 결정적으로 모르면 초안을 만들지 않는다(빈 폼 금지)
            buttons = tuple(buttons)
            steps = [{"kind": "press_sequence", "appliance_id": candidate.appliance_id, "buttons": list(buttons)}]
            key = candidate_key(candidate.appliance_id, buttons)
            strength = (candidate.distinct_days, candidate.occurrences)
            current = drafts.get(key)
            if current is not None and current["_strength"] >= strength:
                continue
            band = candidate.time_band
            drafts[key] = {
                "_strength": strength,
                "key": key,
                "purpose": candidate.purpose,
                "appliance_id": candidate.appliance_id,
                "appliance_name": appliance.name,
                "buttons": list(buttons),
                "steps": steps,
                "suggested_name": f"{band} {candidate.purpose}".strip()[:30],
                "evidence": f"최근 {candidate.window_days}일 중 {band}에 {candidate.distinct_days}일 사용했어요",
                "evidence_detail": {"window_days": candidate.window_days,
                                    "distinct_days": candidate.distinct_days,
                                    "occurrences": candidate.occurrences, "time_band": band},
                "ask_time": ask_time,
                "run_choices": [{"run": "manual", "label": "직접 실행할 때만"},
                                {"run": "ask_at_time", "label": f"매일 {ask_time}에 물어보기"}],
                "notice": SAVE_NOTICE,
            }
        ordered = sorted(drafts.values(), key=lambda d: d["_strength"], reverse=True)
        return {d["key"]: {k: v for k, v in d.items() if k != "_strength"} for d in ordered}

    def _thinq_draft(self, drafts: dict, candidate, ask_time: str, appliance) -> None:
        """ThinQ 목적 문장 → 시각 루틴 초안(2026-10-16). 낮은 위험 동작(자동 실행 허용 대상과 같은 표)만.

        단계는 ThinQ 명령 하나다. 근거 문장은 기록 시각과 날 수로만 말한다(누가 했는지 단정하지 않는다). 폰은 ``buttons``가
        빈 초안을 숨기므로 동작 한 줄(예: "전원 켜기")을 싣는다."""
        from .auto_rules import _josa, _josa_stem, is_low_risk  # noqa: PLC0415

        binding = getattr(appliance, "thinq", None)
        if binding is None:
            return
        try:
            command = binding.command_for_purpose(candidate.appliance_id, candidate.purpose)
            if command is None:
                return  # 대응표에 없는 목적 문장은 초안을 만들지 않는다(빈 폼 금지)
            cap = binding.validate_command(command)
        except Exception:  # noqa: BLE001 -- 해석 실패는 초안 없음
            log.exception("routine candidate thinq lookup failed")
            return
        args = command.args_dict()
        value = args.get(cap.arg)
        if not is_low_risk(binding.device_type, command.action, value):
            return  # 끄기·세탁 시작 같은 동작은 초안으로 권하지 않는다
        key = thinq_candidate_key(candidate.appliance_id, command.action, args)
        strength = (candidate.distinct_days, candidate.occurrences)
        current = drafts.get(key)
        if current is not None and current["_strength"] >= strength:
            return
        band = candidate.time_band
        name = appliance.name
        value_label = cap.value_label(str(value))
        if command.action == "set_power" and value == "POWER_ON":
            did = f"{name}{_josa(_josa_stem(name), '을', '를')} 켰어요"
        else:
            phrase = cap.setting_phrase(str(value))
            did = f"{name} {phrase}{_josa(phrase, '으로', '로')} 바꿨어요"
        hour, minute = (int(part) for part in ask_time.split(":"))
        when = f"{hour}시쯤" if minute == 0 else f"{hour}시 {minute}분쯤"
        drafts[key] = {
            "_strength": strength,
            "key": key,
            "purpose": candidate.purpose,
            "appliance_id": candidate.appliance_id,
            "appliance_name": name,
            "buttons": [f"{cap.label} {value_label}"],
            "steps": [{"kind": "thinq_command", "appliance_id": candidate.appliance_id,
                       "action": command.action, "args": dict(args)}],
            "suggested_name": f"{band} {candidate.purpose}".strip()[:30],
            "evidence": f"최근 {candidate.window_days}일 중 {when} {candidate.distinct_days}일 {did}",
            "evidence_detail": {"window_days": candidate.window_days,
                                "distinct_days": candidate.distinct_days,
                                "occurrences": candidate.occurrences, "time_band": band},
            "ask_time": ask_time,
            # 정해진 시각이 이 초안의 근거라 '정해진 때 물어보기'를 앞에 둔다.
            "run_choices": [{"run": "ask_at_time", "label": f"매일 {ask_time}에 물어보기"},
                            {"run": "manual", "label": "직접 실행할 때만"}],
            "notice": SAVE_NOTICE,
        }

    def _existing_same(self, draft: dict):
        """같은 장치 명령 하나인 저장된 루틴 — 버튼식은 같은 가전·같은 버튼 순서(버튼 ID로 적었어도 이름으로 맞춰 본다),
        ThinQ는 같은 가전·같은 동작·같은 인자."""
        wanted = _draft_signature(draft)
        for routine in self._store.list():
            try:
                commands = compile_commands(routine, self._registry)
            except (RoutineValidationError, ValueError):
                continue
            if len(commands) == 1 and _command_signature(commands[0]) == wanted:
                return routine
        return None


def thinq_candidate_key(appliance_id: str, action: str, args: dict) -> str:
    payload = canonical_json({"appliance_id": appliance_id, "action": action, "args": dict(args)})
    return "tc-" + hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _command_signature(command) -> tuple:
    if command.route is ControlRoute.THINQ:
        return (command.target_id, "thinq", command.action, canonical_json(command.args_dict()))
    return (command.target_id, "press", tuple(command.buttons))


def _draft_signature(draft: dict) -> tuple:
    (step,) = draft["steps"]
    if step["kind"] == "thinq_command":
        return (step["appliance_id"], "thinq", step["action"], canonical_json(dict(step["args"])))
    return (draft["appliance_id"], "press", tuple(draft["buttons"]))
