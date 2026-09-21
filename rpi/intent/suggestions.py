"""Proactive suggestion lifecycle with a mandatory one-time approval gate."""

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


log = logging.getLogger(__name__)


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
    ) -> None:
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
        self._dnd_until: datetime | None = None
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
            try:
                return rules.learning_purpose(value, rules.resolve(value))
            except UnknownIntentError:
                return value.strip()
        return key(purpose) in {key(value) for value in muted}

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

    def set_dnd_for(self, minutes: int) -> datetime:
        until = self._clock.now() + timedelta(minutes=minutes)
        self._dnd_until = until
        return until

    def clear_dnd(self) -> None:
        self._dnd_until = None

    def is_dnd(self) -> bool:
        if self._dnd_until is None:
            return False
        return self._clock.now() < self._dnd_until

    def dnd_until(self) -> datetime | None:
        return self._dnd_until if self.is_dnd() else None

    def create_suggestions(self) -> tuple[ProactiveSuggestion, ...]:
        self._refresh_environment()
        with self._state_lock:
            self._expire_locked()
        if self.is_dnd():
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
                    reason=(f"최근 {candidate.window_days}일 동안 "
                            f"{candidate.time_band} 시간에 "
                            f"{candidate.distinct_days}일 사용하셨어요."),
                )
                self._next_id += 1
                self._suggestions[suggestion.suggestion_id] = suggestion
                self._record(suggestion, "created", "habit_pattern")
            created.append(suggestion)
        # 온습도 기반 제안 -- 지금 공간이 더우면 냉방을 선제 제안한다.
        env = self._current_environment()
        if env is not None and not self._is_muted(env.purpose, muted):
            steps = self._preview_steps(env.purpose)
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
        if self.is_dnd():
            return None
        steps = self._preview_steps(purpose)
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
            )
            self._next_id += 1
            self._suggestions[suggestion.suggestion_id] = suggestion
            self._record(suggestion, "created", "explicit_demo")
            return suggestion

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
        return tuple(sorted(self._suppression_store.muted()))

    def unmute(self, purpose: str) -> None:
        """억제 해제 -- 다시 제안 대상이 된다."""
        if self._suppression_store is not None:
            self._suppression_store.unmute(purpose)

    def _preview_steps(self, purpose: str) -> tuple[str, ...]:
        """Best-effort preview only -- approve() re-resolves for real execution.

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

    def pending(self) -> tuple[ProactiveSuggestion, ...]:
        self._refresh_environment()
        with self._state_lock:
            self._expire_locked()
            if self.is_dnd():
                return ()
            return tuple(
                suggestion
                for suggestion in self._suggestions.values()
                if suggestion.status is SuggestionStatus.PENDING
            )

    def approve(self, suggestion_id: str) -> object:
        # 승인권 획득(원자적) 후 실행은 락 밖에서 — 물리 실행을 락 안에서
        # 돌리면 그동안 모든 제안 조작이 멈춘다.
        suggestion = self._claim_for_approval(suggestion_id)
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
            reason = getattr(exc, "reason", None)
            self._record(suggestion, "approval_failed", reason or "executor_error")
            self._release_claim(suggestion_id, retire=isinstance(exc, UnknownSuggestionError),
                                reason=reason)
            raise

    def approve_submit(self, suggestion_id: str) -> str:
        """approve의 비동기(job 모델) 버전 — 실행을 백그라운드로 제출하고
        job_id를 반환한다. 게이트 규칙은 approve와 동일: 실행 제출 전에
        1회용 승인 게이트를 닫는다. executor가 submit_purpose를 지원해야
        한다(SimpleLayService가 지원; 없으면 AttributeError로 즉시 드러남)."""
        # 화면이 보여준 대상 가전으로 실행한다 -- 전역 선택값이 그 사이
        # 바뀌어도 승인한 제안의 대상은 달라지지 않아야 한다.
        suggestion = self._claim_for_approval(suggestion_id)
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
            reason = getattr(exc, "reason", None)
            self._record(suggestion, "approval_failed", reason or "executor_error")
            self._release_claim(suggestion_id, retire=isinstance(exc, UnknownSuggestionError),
                                reason=reason)
            raise

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
