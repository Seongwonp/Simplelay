"""Proactive suggestion lifecycle with a mandatory one-time approval gate."""

import json
import logging
import threading
from dataclasses import replace
from datetime import datetime, timedelta
from uuid import uuid4

from .base import IntentResolver
from .models import ProactiveSuggestion, SuggestionStatus, UsageSource
from .patterns import PatternDetector
from .ports import Clock, PurposeExecutor, SuppressionStore
from .rules import RuleBasedIntentResolver, UnknownIntentError
from .cooldowns import SuggestionCooldowns
from .completed_actions import CompletedActions
from .feedback import SuggestionFeedback
from rpi.services.snapshot_setting import SnapshotSetting


log = logging.getLogger(__name__)

#: 잠시 쉬기 적용 범위(2026-10-14 마감 2번). 업데이트 뒤 켠 잠시 쉬기는 새 제안 + 아직 시작하지 않은 자동 실행을 쉰다.
PAUSE_SCOPE_ALL = "suggestions_and_auto"
#: 업데이트 전 서버에서 켠 잠시 쉬기를 이어받은 것 — 남은 시간 동안 옛 범위(새 제안만 쉼) 그대로, 자동 실행은 막지 않는다.
PAUSE_SCOPE_SUGGESTIONS = "suggestions_only"
_PAUSE_SCOPES = (PAUSE_SCOPE_ALL, PAUSE_SCOPE_SUGGESTIONS)


def _current(purpose: str) -> str:
    """옛 시나리오 질문 문장 → 지금 문장(10/18 쉬운 말 3차). '다시 받지 않기'·다시 묻기 기한은 질문 문장을 열쇠로 쓰므로,
    문장을 바꾼 뒤에도 옛 문장으로 저장된 기록이 같은 제안을 막게 한다. 시나리오 패키지는 늦게 부른다(순환 import 방지)."""
    from rpi.scenarios.catalog import current_question  # noqa: PLC0415

    return (current_question(purpose) or "").strip()


class UnknownSuggestionError(KeyError):
    def __init__(self, suggestion_id: str, *, reason: str | None = None):
        super().__init__(suggestion_id)
        self.reason = reason


class SuggestionAlreadyApprovedError(RuntimeError):
    pass


class SuggestionTargetUnknownError(RuntimeError):
    """대상 가전이 없는 제안은 실행할 수 없다 (백로그 B10).

    appliance_id가 없는 실행은 '기본 로컬 컨트롤러'로 흘러가는데, 다중
    가전 이후 그 기본은 **우연히 전자레인지일 뿐**이다 -- 사용자가 화면에서
    본 대상과 기계가 움직이는 대상이 다를 수 있는 구멍을 데모 편의라는
    이유로 남기지 않는다. RuntimeError라 라우터에서 409가 된다.
    """

    def __init__(self) -> None:
        super().__init__(
            "이 제안은 대상 가전을 알 수 없어 실행할 수 없습니다 -- "
            "가전을 등록한 뒤 새 제안을 기다려 주세요"
        )


class ProactiveSuggestionService:
    def __init__(
        self,
        detector: PatternDetector,
        clock: Clock,
        executor: PurposeExecutor,
        intent_resolver: IntentResolver | None = None,
        presence_gate=None,
        suppression_store: SuppressionStore | None = None,
        environmental=None,
        cooldowns: SuggestionCooldowns | None = None,
        completed_actions: CompletedActions | None = None,
        feedback: SuggestionFeedback | None = None,
        scenario_resolver=None,
    ) -> None:
        # 시나리오 ID → **지금** 정의대로 만든 명령들. 승인 시 카드가 들고 있는
        # 명령과 지문을 대조한다(달라졌으면 재승인). None이면 대조를 건너뛴다.
        self._scenario_resolver = scenario_resolver
        # 사용자 루틴(rpi/routines, 2026-09-30): 습관 카드가 같은 버튼 순서의 루틴 이름을
        # 빌려 쓰고(``_routine_namer``), 루틴 카드의 승인은 루틴 순서기로 간다(``_plan_runner``).
        self._routine_namer = None
        self._plan_runner = None
        self._feedback = feedback if feedback is not None else SuggestionFeedback()
        self._completed_actions = completed_actions
        self._detector = detector
        self._clock = clock
        self._executor = executor
        self._intent_resolver = intent_resolver
        self._suggestions: dict[str, ProactiveSuggestion] = {}
        self._next_id = 1
        self._id_prefix = uuid4().hex
        self._cooldowns = cooldowns if cooldowns is not None else SuggestionCooldowns()
        #: 잠시 쉬기 — 불변 사본 ``(끝 시각|None, 범위, 이미 검토한 이어받기 값|None)``. 판정은 잠금 없이 읽고, 바꾸기는
        #: 메모리에 먼저 적용한 뒤 저장은 따로(HIGH 재확인 H-R2·M-R1, ``SnapshotSetting``). 저장소는 ``restore_pause``가 붙인다
        #: (없으면 메모리만). 이어받기 값은 같은 값을 두 번 쓰지 않으려고 남긴다(컨테이너 재시작에 env가 남아도).
        self._pause = SnapshotSetting((None, PAUSE_SCOPE_ALL, None), encode=self._encode_pause,
                                      name="pause")
        #: 조용한 시간(매일 시간대) 판정 — None이면 없음. 잠시 쉬기(DND)와 함께 ``is_quiet``가 본다(2026-10-14, 5번).
        self._quiet_schedule = None
        # 승인은 워커 스레드(asyncio.to_thread), 거부·생성은 이벤트 루프
        # 스레드에서 온다 — 상태 확인+전이를 원자화하지 않으면 "폰에서
        # 거부했는데 키오스크 승인이 되살려 실행"되는 레이스가 가능하다.
        self._state_lock = threading.Lock()
        # 공간 맥락 게이트(선택) — False를 돌려주는 동안 자동 제안 생성을
        # 보류한다(부재 중인 공간에 제안을 띄우지 않기). None이면 무시.
        # 수동 데모 트리거는 예외지만 자연 제안은 노출·승인도 재검사한다.
        self._presence_gate = presence_gate
        # "다시 추천 안 함"으로 내린 루틴 억제 목록. None이면 억제 없음.
        self._suppression_store = suppression_store
        # 온습도 기반 제안기(선택). None이면 환경 제안 없음.
        self._environmental = environmental
        self._environment_read_lock = threading.Lock()
        self._environment_snapshot_lock = threading.Lock()
        self._environment_snapshot = (None, None)

    @staticmethod
    def _is_muted(purpose: str, muted) -> bool:
        # Preserve previous opt-outs when a known alias gets a canonical name.
        rules = RuleBasedIntentResolver()
        def key(value):
            value = _current(value)
            try:
                return rules.learning_purpose(value, rules.resolve(value))
            except UnknownIntentError:
                return value.strip()
        return key(purpose) in {key(value) for value in muted}

    def presence_absent(self) -> bool:
        """부재 게이트가 켜져 있고 지금 '자리에 없음'으로 판정됐는가.

        부재 정책은 여기 하나뿐이다 -- 호출자(시나리오 엔진 등)가 같은 판정을
        되풀이 구현하면 게이트를 끄는 조건이 두 군데로 갈린다.
        """
        return self._presence_gate is not None and not self._presence_gate()

    def feedback_events(self, limit: int = 100) -> dict:
        # Read only: observing the journal must not generate/expire suggestions.
        return self._feedback.recent(limit)

    def _record(self, suggestion, action, reason, **details):
        self._feedback.record(suggestion, self._clock.now(), action, reason, **details)

    def learning_status(self) -> dict:
        status = self._detector.learning_status()
        muted = self.muted_purposes()
        for routine in status["routines"]:
            routine["muted"] = self._is_muted(routine["purpose"], muted)
        status["paused"] = self.is_dnd()
        return status

    # ── 잠시 쉬기 — 메모리 적용과 저장을 나눈다(HIGH 재확인 H-R2·M-R1) ────────────────────────────
    def apply_dnd_for(self, minutes: int) -> tuple[datetime, int]:
        """메모리에 바로 켠다(입출력 없음 — 이벤트 루프에서 불러도 된다). (끝 시각, 판 번호)."""
        until = self._clock.now() + timedelta(minutes=minutes)
        _, version = self._pause.change(lambda cur: (until, PAUSE_SCOPE_ALL, cur[2]))
        return until, version

    def apply_clear_dnd(self) -> int:
        """메모리에서 바로 끈다(입출력 없음). 판 번호."""
        _, version = self._pause.change(lambda cur: (None, PAUSE_SCOPE_ALL, cur[2]))
        return version

    def persist_pause(self, version: int | None = None) -> bool | None:
        """잠시 쉬기 DB 저장 — True 저장됨 · False 실패(이번 세션만 적용, 재시작하면 마지막 저장값) · None 저장소 없음.
        DB를 기다리므로 이벤트 루프 밖에서 부른다."""
        return self._pause.persist(version)

    def set_dnd_for(self, minutes: int) -> datetime:
        """메모리 적용 + 저장(같은 스레드) — 호환용. API는 ``apply_dnd_for``·``persist_pause``를 나눈다."""
        until, version = self.apply_dnd_for(minutes)
        self.persist_pause(version)
        return until

    def clear_dnd(self) -> None:
        self.persist_pause(self.apply_clear_dnd())

    # ── 잠시 쉬기 영속(2026-10-14 마감 2번) — 재시작 뒤에도 표시한 끝 시각까지 같은 범위 ──────────
    def restore_pause(self, load=None, save=None) -> None:
        """DB에 남긴 잠시 쉬기(끝 시각·범위)를 다시 읽는다. 읽지 못하거나 지난 값이면 쉬지 않는 상태로 시작."""
        self._pause.set_save(save)
        if load is None:
            return
        try:
            raw = load()
            data = json.loads(raw) if raw else None
        except (ValueError, TypeError):
            log.exception("pause setting unreadable; starting without a pause")
            return
        if not isinstance(data, dict):
            return
        seen = data.get("carryover_seen")
        seen = seen if isinstance(seen, str) else None
        until = _aware(data.get("until"))
        scope = data.get("scope")
        if until is None or scope not in _PAUSE_SCOPES or self._clock.now() >= until:
            self._pause.load((None, PAUSE_SCOPE_ALL, seen))
            return
        self._pause.load((until, scope, seen))

    def carry_over_pause(self, raw: str | None) -> bool:
        """업데이트 전 서버가 알린 잠시 쉬기 끝 시각을 옛 범위(새 제안만)로 이어받는다.

        **확인 가능한 값일 때만**: 오프셋 붙은 ISO 시각, 아직 지나지 않음, 최대 쉬기 길이(24시간) 안. 업데이트 뒤 이미
        켠 잠시 쉬기가 있으면 덮지 않는다. 같은 값은 한 번만 검토한다(쓰든 안 쓰든 기록).
        """
        raw = (raw or "").strip()
        if not raw or raw == self._pause.value[2]:
            return False
        until = _aware(raw)
        result: list[bool] = []

        def carry(cur):
            now = self._clock.now()
            active = cur[0] is not None and now < cur[0]
            applied = until is not None and now < until <= now + timedelta(hours=24) and not active
            result.append(applied)
            return (until, PAUSE_SCOPE_SUGGESTIONS, raw) if applied else (cur[0], cur[1], raw)

        _, version = self._pause.change(carry)
        applied = result[-1]
        log.info("pause carryover %s: %s", "applied (suggestions only)" if applied else "ignored", raw)
        self.persist_pause(version)
        return applied

    def _encode_pause(self, value) -> str:
        until, scope, seen = value
        active = until is not None and self._clock.now() < until
        return json.dumps({"until": until.isoformat() if active else None,
                           "scope": scope if active else None,
                           "carryover_seen": seen}, ensure_ascii=False)

    def _pause_now(self) -> tuple[datetime | None, str]:
        """지금 켜진 잠시 쉬기 ``(끝 시각, 범위)`` — 사본을 한 번만 읽는다(잠금 없음). 꺼져 있으면 ``(None, 범위)``."""
        until, scope, _ = self._pause.value
        if until is None or self._clock.now() >= until:
            return None, scope
        return until, scope

    def dnd_scope(self) -> str | None:
        """켜진 잠시 쉬기의 범위 — ``suggestions_and_auto``(업데이트 뒤 켬)·``suggestions_only``(이어받음)·None(꺼짐)."""
        until, scope = self._pause_now()
        return scope if until is not None else None

    def is_dnd(self) -> bool:
        return self._pause_now()[0] is not None

    def dnd_until(self) -> datetime | None:
        return self._pause_now()[0]

    def set_quiet_schedule(self, active) -> None:
        """active() -> bool: 지금 매일 조용한 시간대인가. 메모리 판정만(입출력 없음) — 실행 게이트 안에서도 부른다."""
        self._quiet_schedule = active

    def is_quiet(self) -> bool:
        """조용한 시간(매일 시간대) 또는 잠시 쉬기(범위 무관). 새 제안을 만들지 않고, 떠 있던 카드는 내린다(정책 b)."""
        if self.is_dnd():
            return True
        return self._schedule_active()

    def is_auto_run_quiet(self) -> bool:
        """아직 시작하지 않은 자동 실행을 건너뛰나 — 매일 시간대, 또는 새 범위 잠시 쉬기. 이어받은 옛 범위는 막지 않는다."""
        until, scope = self._pause_now()
        if until is not None and scope == PAUSE_SCOPE_ALL:
            return True
        return self._schedule_active()

    def _schedule_active(self) -> bool:
        schedule = self._quiet_schedule
        if schedule is None:
            return False
        try:
            return bool(schedule())
        except Exception:  # noqa: BLE001 -- 판정 실패는 조용하지 않은 것으로(제안이 뜰 뿐 실행은 늘 승인 뒤)
            log.exception("quiet schedule check failed")
            return False

    def create_suggestions(self) -> tuple[ProactiveSuggestion, ...]:
        self._refresh_environment()
        with self._state_lock:
            self._expire_locked()
        if self.is_quiet():
            return ()
        if self._presence_gate is not None and not self._presence_gate():
            return ()
        created: list[ProactiveSuggestion] = []
        muted = (
            self._suppression_store.muted()
            if self._suppression_store is not None
            else frozenset()
        )
        for candidate in self._detector.candidates():
            if self._is_muted(candidate.purpose, muted):
                continue  # 사용자가 이 루틴을 "다시 추천 안 함"으로 내렸다
            # 미리보기 해석(느릴 수 있음)은 락 밖에서
            steps = self._preview_steps(candidate.purpose)
            commands, summaries = self._purpose_commands(
                candidate.purpose, candidate.appliance_id
            )
            with self._state_lock:
                self._expire_locked()
                if not self._context_valid(candidate.purpose, candidate.time_band, candidate.appliance_id):
                    continue
                if self._already_completed(candidate.purpose, candidate.time_band, candidate.appliance_id, steps):
                    continue
                if (self._suppression_store is not None
                        and self._is_muted(candidate.purpose, self._suppression_store.muted())):
                    continue
                until = self._detector.band_end(candidate.time_band, self._clock.now())
                if until is None:
                    continue  # 느린 미리보기 동안 시간대가 끝난 경우
                routine = self._routine_for(candidate.appliance_id, steps)
                key = self._cooldowns.key(
                    candidate.purpose, candidate.time_band, candidate.appliance_id
                )
                if self._cooldowns.blocked(key, self._clock.now()):
                    continue
                existing = self._pending_for(
                    candidate.purpose, candidate.time_band, candidate.appliance_id
                )
                if existing is not None:
                    created.append(existing)
                    continue
                suggestion = ProactiveSuggestion(
                    suggestion_id=f"suggestion-{self._id_prefix}-{self._next_id}",
                    purpose=candidate.purpose,
                    time_band=candidate.time_band,
                    occurrences=candidate.occurrences,
                    created_at=self._clock.now(),
                    steps=steps,
                    appliance_id=candidate.appliance_id,
                    expires_at=until,
                    # 근거는 본 사실만 담담하게(평가 14차 10/18 — '자주 하셔서 여쭤봐요'는 높임·낮춤이 섞인 번역투였다).
                    reason=((f"평소처럼 '{routine[1]}' 할까요? " if routine else "")
                            + f"최근 {candidate.window_days}일 중 "
                            f"{candidate.distinct_days}일, {candidate.time_band}에 하셨어요"),
                    commands=commands,
                    command_summaries=summaries,
                    routine_id=routine[0] if routine else None,
                    routine_name=routine[1] if routine else None,
                )
                self._next_id += 1
                self._suggestions[suggestion.suggestion_id] = suggestion
                self._record(suggestion, "created", "habit_pattern")
            created.append(suggestion)
        # 온습도 기반 제안 -- 지금 공간이 더우면 냉방을 선제 제안한다.
        env = self._current_environment()
        if env is not None and not self._is_muted(env.purpose, muted):
            steps = self._preview_steps(env.purpose)
            env_commands, env_summaries = self._purpose_commands(env.purpose, env.appliance_id)
            self._refresh_environment()
            with self._state_lock:
                self._expire_locked()
                current = self._current_environment()
                if (current is None or current.purpose != env.purpose
                        or current.appliance_id != env.appliance_id
                        or not self._context_valid(env.purpose, "환경", env.appliance_id)):
                    return self._created_pending_locked(created)
                env = current
                if self._already_completed(env.purpose, "환경", env.appliance_id, steps):
                    return self._created_pending_locked(created)
                if (self._suppression_store is not None
                        and self._is_muted(env.purpose, self._suppression_store.muted())):
                    return self._created_pending_locked(created)
                key = self._cooldowns.key(
                    env.purpose, "시연환경" if getattr(env, "is_demo", False) else "환경", env.appliance_id,
                )
                if self._cooldowns.blocked(key, self._clock.now()):
                    return self._created_pending_locked(created)
                existing = self._pending_for(env.purpose, "환경", env.appliance_id)
                if existing is not None:
                    created.append(existing)
                else:
                    env_suggestion = ProactiveSuggestion(
                        suggestion_id=f"suggestion-{self._id_prefix}-{self._next_id}",
                        purpose=env.purpose,
                        time_band="환경",
                        occurrences=0,
                        created_at=self._clock.now(),
                        steps=steps,
                        reason=env.reason,
                        is_demo=getattr(env, "is_demo", False),
                        appliance_id=env.appliance_id,
                        expires_at=self._clock.now() + timedelta(minutes=15),
                        commands=env_commands,
                        command_summaries=env_summaries,
                    )
                    self._next_id += 1
                    self._suggestions[env_suggestion.suggestion_id] = (
                        env_suggestion
                    )
                    self._record(env_suggestion, "created", "environment_condition")
                    created.append(env_suggestion)
        with self._state_lock:
            self._expire_locked()
            return self._created_pending_locked(created)

    def _created_pending_locked(self, created):
        return tuple(self._suggestions[s.suggestion_id] for s in created
                     if s.suggestion_id in self._suggestions
                     and self._suggestions[s.suggestion_id].status is SuggestionStatus.PENDING)

    def _claim_for_approval(self, suggestion_id: str) -> ProactiveSuggestion:
        """승인권을 원자적으로 획득 — 상태 확인과 APPROVED 전이를 한 임계구역
        에서 수행한다. 거부가 먼저 pop했으면 KeyError → 404, 이미 승인됐으면
        AlreadyApproved → 409. '거부됐는데 승인 스레드가 되살리는' 레이스 차단."""
        self._refresh_environment()
        with self._state_lock:
            self._expire_locked()
            try:
                suggestion = self._suggestions[suggestion_id]
            except KeyError as exc:
                raise UnknownSuggestionError(suggestion_id) from exc
            if suggestion.status is not SuggestionStatus.PENDING:
                raise SuggestionAlreadyApprovedError(suggestion_id)
            # 대상 없는 제안은 게이트를 소비하기 전에 거절한다(B10) --
            # 카드는 pending으로 남아 화면이 이유를 보여줄 수 있다.
            if suggestion.appliance_id is None:
                raise SuggestionTargetUnknownError()
            self._remember_locked(suggestion)
            self._suggestions[suggestion_id] = replace(
                suggestion, status=SuggestionStatus.APPROVED
            )
            self._record(suggestion, "approval_requested", "user_approval")
            return suggestion

    def create_demo_suggestion(
        self,
        purpose: str,
        occurrences: int = 3,
        appliance_id: str | None = None,
    ) -> ProactiveSuggestion | None:
        """시연용 — 패턴 감지(사용 이력 3회 이상 + 시간대 일치)를 거치지 않고
        제안을 즉시 만든다. 시간대 설정에 구멍이 있는 시각(예: 오후 3시)에도
        데모가 항상 성립하게 하는 것이 목적. DND 중에는 실사용과 동일하게
        만들지 않고 None을 반환한다(호출자가 409 등으로 구분해 알림).

        같은 purpose의 pending 제안이 이미 있으면 그것을 그대로 돌려준다 —
        데모 트리거를 연타해도 중복 카드가 쌓이지 않는다.
        """
        if self.is_quiet():
            return None
        steps = self._preview_steps(purpose)
        commands, summaries = self._purpose_commands(purpose, appliance_id)
        with self._state_lock:
            self._expire_locked()
            existing = self._pending_for(purpose, "데모", appliance_id)
            if existing is not None:
                return existing
            suggestion = ProactiveSuggestion(
                suggestion_id=f"suggestion-{self._id_prefix}-{self._next_id}",
                purpose=purpose,
                time_band="데모",
                occurrences=occurrences,
                created_at=self._clock.now(),
                steps=steps,
                appliance_id=appliance_id,
                expires_at=self._clock.now() + timedelta(minutes=15),
                commands=commands,
                command_summaries=summaries,
            )
            self._next_id += 1
            self._suggestions[suggestion.suggestion_id] = suggestion
            self._record(suggestion, "created", "explicit_demo")
            return suggestion

    def set_scenario_resolver(self, resolver) -> None:
        self._scenario_resolver = resolver

    def set_routine_namer(self, namer) -> None:
        """namer(appliance_id, steps) -> (routine_id, name) | None."""
        self._routine_namer = namer

    def set_plan_runner(self, runner) -> None:
        """runner.handles(scenario_id)가 참인 카드의 승인은 runner가 실행한다."""
        self._plan_runner = runner

    def _routine_for(self, appliance_id, steps):
        if self._routine_namer is None:
            return None
        try:
            return self._routine_namer(appliance_id, tuple(steps))
        except Exception:  # noqa: BLE001 -- 이름 빌리기 실패가 습관 제안을 막지 않는다
            log.exception("routine namer failed")
            return None

    def create_scenario_suggestion(
        self,
        *,
        scenario_id: str,
        purpose: str,
        commands: tuple,
        summaries: tuple[str, ...],
        reason: str,
        is_demo: bool,
        valid_minutes: int = 15,
        routine_id: str | None = None,
        routine_name: str | None = None,
        time_band: str = "시나리오",
        user_started: bool = False,
    ) -> ProactiveSuggestion | None:
        """시나리오 제안 — **확정 명령**을 들고 다니는 카드. 자동 실행하지 않는다.

        근거 규칙(``is_demo``)은 호출자(시나리오 엔진)가 트리거의 실행 환경으로
        정한다: 실제 L3 확인이면 일반 제안, 모의 성공이면 시연 제안. DND·다시 추천
        안 함은 일반 제안과 같다. 부재 게이트는 시연이 아닐 때만 본다.
        """
        if not commands or len(commands) != len(summaries):
            raise ValueError("scenario suggestion needs one summary per command")
        # 사용자가 직접 요청한 카드(루틴 '지금 실행')는 조용한 시간에도 만든다 — 직접 요청한 실행은 그대로다.
        if not user_started and self.is_quiet():
            return None
        muted = (self._suppression_store.muted()
                 if self._suppression_store is not None else frozenset())
        # 옛 질문 문장으로 '다시 받지 않기'한 것도 막는다(10/18 쉬운 말 3차 — 문장만 바꾸고 기록은 잇는다).
        if purpose.strip() in muted or _current(purpose) in {_current(m) for m in muted}:
            return None
        if not is_demo and self._presence_gate is not None and not self._presence_gate():
            return None
        with self._state_lock:
            self._expire_locked()
            existing = next(
                (s for s in self._suggestions.values()
                 if s.scenario_id == scenario_id and s.status is SuggestionStatus.PENDING),
                None,
            )
            if existing is not None:
                return existing
            now = self._clock.now()
            suggestion = ProactiveSuggestion(
                suggestion_id=f"suggestion-{self._id_prefix}-{self._next_id}",
                purpose=purpose,
                time_band=time_band,
                occurrences=0,
                created_at=now,
                steps=(),
                reason=reason,
                is_demo=is_demo,
                appliance_id=commands[0].target_id,
                expires_at=now + timedelta(minutes=valid_minutes),
                commands=tuple(commands),
                command_summaries=tuple(summaries),
                scenario_id=scenario_id,
                routine_id=routine_id,
                routine_name=routine_name,
                user_started=user_started,
            )
            self._next_id += 1
            self._suggestions[suggestion.suggestion_id] = suggestion
            self._record(suggestion, "created", "user_request" if user_started else "scenario_trigger")
            return suggestion

    def _approved_commands(self, suggestion: ProactiveSuggestion) -> tuple:
        """카드의 명령을 승인 1건으로 묶는다. 정의가 바뀌었으면 재승인(결정 #1)."""
        from rpi.commands import ApprovalMismatchError, ApprovedCommand  # noqa: PLC0415

        if self._scenario_resolver is not None and suggestion.scenario_id is not None:
            current = tuple(self._scenario_resolver(suggestion.scenario_id))
            if (len(current) != len(suggestion.commands)
                    or any(not a.same_content(b) for a, b in zip(suggestion.commands, current))):
                raise ApprovalMismatchError("시나리오 내용이 바뀌었어요")
        elif suggestion.scenario_id is None:
            # 목적에서 확정한 카드(ThinQ 경로)는 승인 시점에 목적을 다시 해석해
            # 대조한다. 그 사이 가전의 목적→동작 정의가 바뀌었으면 사용자가
            # 승인한 명령이 아니다 -- 실행하지 않고 재승인을 받는다.
            current, _ = self._purpose_commands(suggestion.purpose, suggestion.appliance_id)
            if (len(current) != len(suggestion.commands)
                    or any(not a.same_content(b) for a, b in zip(suggestion.commands, current))):
                raise ApprovalMismatchError("이 가전의 동작 정의가 바뀌었어요")
        now = self._clock.now()
        expires = (suggestion.expires_at
                   if suggestion.expires_at is not None and suggestion.expires_at > now else None)
        return tuple(
            ApprovedCommand(command=cmd, approval_id=suggestion.suggestion_id,
                            approved_at=now, shown_summary=summary, expires_at=expires)
            for cmd, summary in zip(suggestion.commands, suggestion.command_summaries)
        )

    def _source_of(self, suggestion: ProactiveSuggestion) -> UsageSource:
        return (UsageSource.DEMO if suggestion.time_band == "데모" or suggestion.is_demo
                else UsageSource.SUGGESTION)

    def _approve_commands(self, suggestion: ProactiveSuggestion, *, background: bool):
        approved = self._approved_commands(suggestion)
        target = self._executor
        if self._plan_runner is not None and self._plan_runner.handles(suggestion.scenario_id):
            target = self._plan_runner  # 루틴: 같은 승인 묶음을 단계 순서대로(안내·기다리기 포함)
        run = target.submit_approved if background else target.execute_approved
        return run(
            approved, purpose=suggestion.purpose, usage_source=self._source_of(suggestion),
            scenario_id=suggestion.scenario_id,
            approval_guard=self._approval_options(suggestion).get("approval_guard"),
        )

    def reject(self, suggestion_id: str, mute: bool = False) -> None:
        """실행 없이 pending에서 제거(dismiss). 없는 id이거나 이미 승인된
        제안이면 UnknownSuggestionError — 기존 라우터의 pending 전용
        404 의미를 그대로 보존한다. 확인+제거가 락 안이라 승인과 원자적.

        mute=True면 "다시 추천 안 함" — 그 purpose를 억제 목록에 넣어 패턴이
        다시 만들지 않게 하고, 같은 루틴의 다른 pending 카드도 함께 내린다
        (한쪽에서 "그만"을 눌렀는데 다른 밴드 카드가 남아 있으면 모순)."""
        with self._state_lock:
            self._expire_locked()
            suggestion = self._suggestions.get(suggestion_id)
            if (
                suggestion is None
                or suggestion.status is not SuggestionStatus.PENDING
            ):
                raise UnknownSuggestionError(suggestion_id)
            purpose = suggestion.purpose
            if mute and self._suppression_store is not None:
                # 생성과 같은 락 안에서 저장해야 거절 중 새 제안이 끼지 않는다.
                self._suppression_store.mute(purpose)
            else:
                self._remember_locked(suggestion)
            self._suggestions.pop(suggestion_id)
            self._record(suggestion, "muted" if mute else "dismissed",
                         "user_mute" if mute else "user_skip")
            if mute:
                for sid in [
                    s.suggestion_id
                    for s in self._suggestions.values()
                    if self._is_muted(s.purpose, (purpose,))
                    and s.status is SuggestionStatus.PENDING
                ]:
                    related = self._suggestions.pop(sid)
                    self._record(related, "withdrawn", "routine_muted")

    def revision_options(self, suggestion_id: str) -> dict[str, tuple[str, ...]]:
        with self._state_lock:
            self._expire_locked()
            old = self._suggestions.get(suggestion_id)
            if old is None or old.status is not SuggestionStatus.PENDING:
                raise UnknownSuggestionError(suggestion_id)
            # Environmental eligibility is tied to the original action.
            if old.time_band == "환경":
                return {}
            options = getattr(self._executor, 'revision_options', lambda _: {})(old.appliance_id)
            return {name: steps for name, steps in options.items() if name != old.purpose}

    def revise(self, suggestion_id: str, purpose: str) -> ProactiveSuggestion:
        with self._state_lock:
            self._expire_locked()
            old = self._suggestions.get(suggestion_id)
            if old is None or old.status is not SuggestionStatus.PENDING:
                raise UnknownSuggestionError(suggestion_id)
            options = getattr(self._executor, 'revision_options', lambda _: {})(old.appliance_id)
            steps = options.get(purpose)
            if old.time_band == "환경" or not steps or purpose == old.purpose:
                raise UnknownIntentError('choose a different registered action')
            # Suppress recreation of the original candidate this time band only.
            # Save before removing it; failure leaves the original review intact.
            self._remember_locked(old)
            new = replace(old, suggestion_id=uuid4().hex, purpose=purpose,
                          steps=tuple(steps), occurrences=0, revised_from=old.suggestion_id,
                          reason='이번 요청에서 바꾼 동작이에요. 순서를 확인하고 다시 승인해 주세요.')
            self._suggestions.pop(suggestion_id)
            self._suggestions[new.suggestion_id] = new
            self._record(old, 'revised', 'user_changed_this_request')
            self._record(new, 'created', 'user_revision')
            return new

    def snooze(self, suggestion_id: str) -> None:
        """Pause this target/purpose/time-band for 30 minutes; never schedule execution.

        Persist before retiring the card. Future candidates pass the usual context
        gates and need a new approval; a stale approval cannot revive this card.
        """
        with self._state_lock:
            self._expire_locked()
            suggestion = self._suggestions.get(suggestion_id)
            if suggestion is None or suggestion.status is not SuggestionStatus.PENDING:
                raise UnknownSuggestionError(suggestion_id)
            now = self._clock.now()
            self._cooldowns.remember(self._key(suggestion), now + timedelta(minutes=30), now)
            self._suggestions.pop(suggestion_id)
            self._record(suggestion, "snoozed", "user_pause_30_minutes")

    def drop_for_appliance(self, appliance_id: str) -> int:
        """그 가전을 대상으로 하던 pending 제안을 내린다.

        가전을 지웠는데 그 가전의 제안 카드가 화면에 남아 있으면,
        사용자는 실행할 수 없는 것을 계속 권유받는다. 승인해도 이제는
        404로 거절되므로(R1) 카드 자체를 남길 이유가 없다.

        억제 목록에는 넣지 않는다 -- 사용자가 '그만 추천해'라고 한 게
        아니라 대상이 사라진 것이므로, 같은 가전을 다시 등록하면 제안도
        다시 나와야 한다.
        """
        with self._state_lock:
            doomed = [
                s.suggestion_id
                for s in self._suggestions.values()
                if s.appliance_id == appliance_id
                and s.status is SuggestionStatus.PENDING
            ]
            for sid in doomed:
                removed = self._suggestions.pop(sid)
                self._record(removed, "withdrawn", "appliance_removed")
        return len(doomed)

    def muted_purposes(self) -> tuple[str, ...]:
        """다시 추천 안 하는 루틴 목록(설정 화면용)."""
        if self._suppression_store is None:
            return ()
        # 옛 질문 문장은 지금 문장으로 보인다(10/18 쉬운 말 3차). 같은 제안이 두 줄로 보이지 않게 한 번만.
        return tuple(sorted({_current(m) for m in self._suppression_store.muted()}))

    def unmute(self, purpose: str) -> None:
        """억제 해제 -- 다시 제안 대상이 된다. 같은 제안의 옛 질문 문장 기록도 함께 푼다."""
        if self._suppression_store is not None:
            self._suppression_store.unmute(purpose)
            target = _current(purpose)
            for stored in self._suppression_store.muted():
                if stored != purpose and _current(stored) == target:
                    self._suppression_store.unmute(stored)

    def _preview_steps(self, purpose: str) -> tuple[str, ...]:
        """Preview shown on the card. Since 2026-09-29 (decision #1) a non-empty
        preview is also what the approval binds to: approve() still resolves again,
        but refuses to run a sequence that differs from this one (re-approval).

        A blank result here (no resolver injected, or resolution fails) just
        means the caller shows no highlight; it never blocks suggestion
        creation, since the occurrence count is still meaningful on its own.
        """
        if self._intent_resolver is None:
            return ()
        try:
            return self._intent_resolver.resolve(purpose)
        except UnknownIntentError:
            return ()

    def _purpose_commands(self, purpose: str, appliance_id) -> tuple[tuple, tuple[str, ...]]:
        """ThinQ 경로 가전이면 카드를 만들 때 **명령을 확정**한다(결정 #1).

        확정해 두면 승인이 ``commands`` 경로(지문 대조)로 흘러, 목적 문자열을
        승인 뒤에 다시 해석하지 않는다. 해석이 안 되는 목적이거나 실행기가
        ThinQ를 모르면 빈 튜플 -- 미리보기가 비어 있던 물리 카드와 같이
        **묶을 대상이 없는 상태**로 두고, 종전 목적 경로로 간다.
        """
        if appliance_id is None:
            return (), ()
        route_of = getattr(self._executor, "route_of", None)
        resolve = getattr(self._executor, "resolve_thinq_purpose", None)
        if route_of is None or resolve is None:
            return (), ()
        try:
            if getattr(route_of(appliance_id), "value", None) != "thinq":
                return (), ()
            command = resolve(purpose, appliance_id)
        except Exception:  # noqa: BLE001 -- 해석 실패는 카드 생성을 막지 않는다
            return (), ()
        summary = purpose.strip()
        summarize = getattr(self._executor, "summary_of", None)
        if summarize is not None:
            try:
                summary = summarize(command) or summary
            except Exception:  # noqa: BLE001
                pass
        return (command,), (summary,)

    def pending(self) -> tuple[ProactiveSuggestion, ...]:
        self._refresh_environment()
        with self._state_lock:
            # 조용한 동안 떠 있던 카드는 ``_expire_locked``가 내린다(사용자가 직접 요청한 카드만 남는다).
            self._expire_locked()
            return tuple(
                suggestion
                for suggestion in self._suggestions.values()
                if suggestion.status is SuggestionStatus.PENDING
            )

    def approve(self, suggestion_id: str) -> object:
        # 승인권 획득(원자적) 후 실행은 락 밖에서 — 물리 실행을 락 안에서
        # 돌리면 그동안 모든 제안 조작이 멈춘다.
        suggestion = self._claim_for_approval(suggestion_id)
        if suggestion.commands:
            try:
                result = self._approve_commands(suggestion, background=False)
                self._record(suggestion, "execution_returned", "controller_returned",
                             execution_status=result.status.value)
                return result
            except Exception as exc:
                self._fail_approval(suggestion, exc)
                raise
        try:
            result = self._executor.execute_purpose(
                suggestion.purpose, suggestion.appliance_id,
                usage_source=(UsageSource.DEMO if suggestion.time_band == "데모" or suggestion.is_demo
                              else UsageSource.SUGGESTION),
                **self._approval_options(suggestion),
            )
            status = getattr(getattr(result, "status", None), "value", None)
            self._record(suggestion, "execution_returned", "controller_returned",
                         execution_status=status)
            return result
        except Exception as exc:
            self._fail_approval(suggestion, exc)
            raise

    def approve_submit(self, suggestion_id: str) -> str:
        """approve의 비동기(job 모델) 버전 — 실행을 백그라운드로 제출하고
        job_id를 반환한다. 게이트 규칙은 approve와 동일: 실행 제출 전에
        1회용 승인 게이트를 닫는다. executor가 submit_purpose를 지원해야
        한다(SimpleLayService가 지원; 없으면 AttributeError로 즉시 드러남)."""
        # 화면이 보여준 대상 가전으로 실행한다 -- 전역 선택값이 그 사이
        # 바뀌어도 승인한 제안의 대상은 달라지지 않아야 한다.
        suggestion = self._claim_for_approval(suggestion_id)
        if suggestion.commands:
            try:
                result = self._approve_commands(suggestion, background=True)
                self._record(suggestion, "submitted", "job_accepted", job_id=result)
                return result
            except Exception as exc:
                self._fail_approval(suggestion, exc)
                raise
        try:
            result = self._executor.submit_purpose(
                suggestion.purpose, suggestion.appliance_id,
                usage_source=(UsageSource.DEMO if suggestion.time_band == "데모" or suggestion.is_demo
                              else UsageSource.SUGGESTION),
                **self._approval_options(suggestion),
            )
            self._record(suggestion, "submitted", "job_accepted", job_id=result)
            return result
        except Exception as exc:
            self._fail_approval(suggestion, exc)
            raise

    def _fail_approval(self, suggestion: ProactiveSuggestion, exc: Exception) -> None:
        """승인 실행 실패. 승인 내용 불일치·만료·무효는 카드를 **내린다**(재승인 필요)."""
        from rpi.commands import ApprovalError  # noqa: PLC0415

        reason = getattr(exc, "reason", None)
        self._record(suggestion, "approval_failed", reason or "executor_error")
        self._release_claim(
            suggestion.suggestion_id,
            retire=isinstance(exc, (UnknownSuggestionError, ApprovalError)),
            reason=reason,
        )

    def _release_claim(self, suggestion_id: str, *, retire: bool = False,
                       reason: str | None = None) -> None:
        """실행에 실패한 승인의 게이트를 되돌린다.

        게이트의 뜻은 '실행을 제출했다'이다. 대상 가전이 사라졌거나(404)
        서버가 다른 작업 중이라(409) **제출 자체가 안 됐으면** 소비되면
        안 된다 -- 카드만 사라지고 아무 일도 일어나지 않는다. 사용자는
        "끝난 뒤 다시 시도하세요"라는 안내를 받는데 정작 다시 시도할
        카드가 없어진다.

        되돌려도 이중 실행이 되지 않는 근거: 실행 제출은 executor 호출의
        마지막 단계이고, 여기 오는 예외는 모두 그 전에 난 것이다.
        """
        with self._state_lock:
            suggestion = self._suggestions.get(suggestion_id)
            if suggestion is not None:
                if suggestion.time_band != "데모":
                    self._cooldowns.forget(self._key(suggestion))
                if retire or not self._context_valid(
                    suggestion.purpose, suggestion.time_band, suggestion.appliance_id,
                ):
                    self._suggestions.pop(suggestion_id, None)
                    self._record(suggestion, "withdrawn",
                                 reason or self._withdrawal_reason(suggestion) or "approval_invalid")
                else:
                    self._suggestions[suggestion_id] = replace(
                        suggestion, status=SuggestionStatus.PENDING
                    )

    def _pending_for(
        self, purpose: str, time_band: str, appliance_id: str | None
    ) -> ProactiveSuggestion | None:
        return next(
            (
                suggestion
                for suggestion in self._suggestions.values()
                if suggestion.purpose == purpose
                and suggestion.time_band == time_band
                and suggestion.appliance_id == appliance_id
                and suggestion.status is SuggestionStatus.PENDING
            ),
            None,
        )

    def _key(self, suggestion: ProactiveSuggestion) -> str:
        return self._cooldowns.key(
            suggestion.purpose,
            "시연환경" if suggestion.is_demo and suggestion.time_band == "환경" else suggestion.time_band,
            suggestion.appliance_id,
        )

    def _remember_locked(self, suggestion: ProactiveSuggestion) -> None:
        # 데모는 명시적인 리허설 트리거라 생활 습관 억제에 섞지 않는다.
        if suggestion.time_band != "데모" and suggestion.expires_at is not None:
            self._cooldowns.remember(
                self._key(suggestion), suggestion.expires_at, self._clock.now()
            )

    def _withdrawal_reason(self, suggestion):
        now = self._clock.now()
        if suggestion.expires_at is not None and now >= suggestion.expires_at:
            return "validity_ended"
        # 정책 b(2026-10-14): 조용한 동안 떠 있던 제안은 버린다 — 끝난 뒤 한꺼번에 다시 알리지 않는다.
        if not suggestion.user_started and self.is_quiet():
            return "quiet_hours"
        if suggestion.time_band != "데모":
            if self._presence_gate is not None and not self._presence_gate():
                return "presence_absent"
            if suggestion.time_band == "환경":
                current = self._current_environment()
                if current is None:
                    return "environment_unavailable"
                if (current.purpose != suggestion.purpose
                        or current.appliance_id != suggestion.appliance_id
                        or getattr(current, "is_demo", False) != suggestion.is_demo):
                    return "environment_changed"
            if self._already_completed(suggestion.purpose, suggestion.time_band,
                                       suggestion.appliance_id, suggestion.steps):
                return "already_completed"
        return None

    def _expire_locked(self) -> None:
        now = self._clock.now()
        kept = {}
        for sid, suggestion in self._suggestions.items():
            if suggestion.status is SuggestionStatus.PENDING:
                reason = self._withdrawal_reason(suggestion)
                if reason is not None:
                    self._record(suggestion, "expired" if reason == "validity_ended" else "withdrawn", reason)
                    continue
                if suggestion.time_band == "환경":
                    current = self._current_environment()
                    if (current is None or current.purpose != suggestion.purpose
                            or current.appliance_id != suggestion.appliance_id
                            or getattr(current, "is_demo", False) != suggestion.is_demo):
                        self._record(suggestion, "withdrawn", "environment_changed")
                        continue
                    suggestion = replace(suggestion, reason=current.reason)
            elif suggestion.expires_at is not None and now >= suggestion.expires_at:
                # Cleaning up an approved card is not unanswered expiry.
                continue
            kept[sid] = suggestion
        self._suggestions = kept

    def _refresh_environment(self) -> None:
        if self._environmental is None:
            return
        # Sensor I/O must never hold the suggestion lock or the execution-start
        # lock: a slow/disconnected sensor must not delay emergency stop.
        with self._environment_read_lock:
            checked_at = self._clock.now()
            try:
                candidate = self._environmental.candidate()
            except Exception:
                log.exception("environment refresh failed; retiring environmental suggestions")
                candidate = None
            with self._environment_snapshot_lock:
                self._environment_snapshot = (candidate, checked_at)

    def _current_environment(self):
        with self._environment_snapshot_lock:
            candidate, checked_at = self._environment_snapshot
        if checked_at is None:
            return None
        age = (self._clock.now() - checked_at).total_seconds()
        return candidate if 0 <= age < 15 else None

    def _context_valid(self, purpose, band, appliance_id) -> bool:
        if band == "데모":
            return True
        if self._presence_gate is not None and not self._presence_gate():
            return False
        if band == "환경":
            current = self._current_environment()
            return (current is not None and current.purpose == purpose
                    and current.appliance_id == appliance_id)
        return True

    def _already_completed(self, purpose, band, appliance_id, steps) -> bool:
        if self._completed_actions is None or band == "데모":
            return False
        now = self._clock.now()
        since = (now - timedelta(minutes=15) if band == "환경"
                 else self._detector.band_start(band, now))
        return since is not None and self._completed_actions.contains(
            appliance_id, purpose, steps, since, now, include_since=band != "환경",
        )

    def _approval_options(self, suggestion):
        options = self._base_approval_options(suggestion)
        # 결정 #1(승인 고정): 카드가 구체적 시퀀스를 보여 줬으면 그 시퀀스에 묶는다.
        # 승인 뒤 해석이 달라지면 실행하지 않고 재승인(ApprovalMismatchError).
        # 미리보기가 비어 있던 카드(해석 실패·리졸버 없음)는 보여 준 명령이 없어
        # 묶을 대상이 없다 -- 종전 동작이다(devlog 2026-09-29 결정 표).
        if (suggestion.steps and not suggestion.commands
                and "expected_buttons" not in options
                and getattr(self._executor, "binds_approved_buttons", False) is True):
            options = {**options, "approved_buttons": tuple(suggestion.steps)}
        return options

    def _base_approval_options(self, suggestion):
        if suggestion.revised_from is not None:
            def revised_guard():
                reason = self._withdrawal_reason(suggestion)
                if reason is not None:
                    raise UnknownSuggestionError(suggestion.suggestion_id, reason=reason)
            return {"expected_buttons": suggestion.steps, "approval_guard": revised_guard}
        if suggestion.time_band == "데모":
            return {}
        if (self._completed_actions is None and self._presence_gate is None
                and suggestion.time_band != "환경"):
            return {}

        def guard():
            # Called under the executor's start lock; no sensor I/O here.
            reason = self._withdrawal_reason(suggestion)
            if reason is not None:
                raise UnknownSuggestionError(suggestion.suggestion_id, reason=reason)

        return {"approval_guard": guard}


def _aware(value) -> datetime | None:
    """오프셋이 붙은 ISO 시각만 받는다(어느 시각인지 확인할 수 없는 값은 None)."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.strip())
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None and parsed.utcoffset() is not None else None
