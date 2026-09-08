"""Proactive suggestion lifecycle with a mandatory one-time approval gate."""

import threading
from dataclasses import replace
from datetime import datetime, timedelta

from .base import IntentResolver
from .models import ProactiveSuggestion, SuggestionStatus
from .patterns import PatternDetector
from .ports import Clock, PurposeExecutor, SuppressionStore
from .rules import UnknownIntentError


class UnknownSuggestionError(KeyError):
    pass


class SuggestionAlreadyApprovedError(RuntimeError):
    pass


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
    ) -> None:
        self._detector = detector
        self._clock = clock
        self._executor = executor
        self._intent_resolver = intent_resolver
        self._suggestions: dict[str, ProactiveSuggestion] = {}
        self._next_id = 1
        self._dnd_until: datetime | None = None
        # 승인은 워커 스레드(asyncio.to_thread), 거부·생성은 이벤트 루프
        # 스레드에서 온다 — 상태 확인+전이를 원자화하지 않으면 "폰에서
        # 거부했는데 키오스크 승인이 되살려 실행"되는 레이스가 가능하다.
        self._state_lock = threading.Lock()
        # 공간 맥락 게이트(선택) — False를 돌려주는 동안 자동 제안 생성을
        # 보류한다(부재 중인 공간에 제안을 띄우지 않기). None이면 무시.
        # 수동 트리거(create_demo_suggestion)와 이미 만들어진 pending 노출은
        # 게이트 대상이 아니다 — 데모·기존 제안 흐름을 건드리지 않는다.
        self._presence_gate = presence_gate
        # "다시 추천 안 함"으로 내린 루틴 억제 목록. None이면 억제 없음.
        self._suppression_store = suppression_store
        # 온습도 기반 제안기(선택). None이면 환경 제안 없음.
        self._environmental = environmental

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
            if candidate.purpose in muted:
                continue  # 사용자가 이 루틴을 "다시 추천 안 함"으로 내렸다
            # 미리보기 해석(느릴 수 있음)은 락 밖에서
            steps = self._preview_steps(candidate.purpose)
            with self._state_lock:
                existing = self._pending_for(candidate.purpose, candidate.time_band)
                if existing is not None:
                    created.append(existing)
                    continue
                suggestion = ProactiveSuggestion(
                    suggestion_id=f"suggestion-{self._next_id}",
                    purpose=candidate.purpose,
                    time_band=candidate.time_band,
                    occurrences=candidate.occurrences,
                    created_at=self._clock.now(),
                    steps=steps,
                    appliance_id=candidate.appliance_id,
                )
                self._next_id += 1
                self._suggestions[suggestion.suggestion_id] = suggestion
            created.append(suggestion)
        # 온습도 기반 제안 -- 지금 공간이 더우면 냉방을 선제 제안한다.
        env = self._environmental.candidate() if self._environmental else None
        if env is not None and env.purpose not in muted:
            steps = self._preview_steps(env.purpose)
            with self._state_lock:
                existing = self._pending_for(env.purpose, "환경")
                if existing is not None:
                    created.append(existing)
                else:
                    env_suggestion = ProactiveSuggestion(
                        suggestion_id=f"suggestion-{self._next_id}",
                        purpose=env.purpose,
                        time_band="환경",
                        occurrences=0,
                        created_at=self._clock.now(),
                        steps=steps,
                        reason=env.reason,
                        appliance_id=env.appliance_id,
                    )
                    self._next_id += 1
                    self._suggestions[env_suggestion.suggestion_id] = (
                        env_suggestion
                    )
                    created.append(env_suggestion)
        return tuple(created)

    def _claim_for_approval(self, suggestion_id: str) -> ProactiveSuggestion:
        """승인권을 원자적으로 획득 — 상태 확인과 APPROVED 전이를 한 임계구역
        에서 수행한다. 거부가 먼저 pop했으면 KeyError → 404, 이미 승인됐으면
        AlreadyApproved → 409. '거부됐는데 승인 스레드가 되살리는' 레이스 차단."""
        with self._state_lock:
            try:
                suggestion = self._suggestions[suggestion_id]
            except KeyError as exc:
                raise UnknownSuggestionError(suggestion_id) from exc
            if suggestion.status is not SuggestionStatus.PENDING:
                raise SuggestionAlreadyApprovedError(suggestion_id)
            self._suggestions[suggestion_id] = replace(
                suggestion, status=SuggestionStatus.APPROVED
            )
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
            existing = self._pending_for(purpose, "데모")
            if existing is not None:
                return existing
            suggestion = ProactiveSuggestion(
                suggestion_id=f"suggestion-{self._next_id}",
                purpose=purpose,
                time_band="데모",
                occurrences=occurrences,
                created_at=self._clock.now(),
                steps=steps,
                appliance_id=appliance_id,
            )
            self._next_id += 1
            self._suggestions[suggestion.suggestion_id] = suggestion
            return suggestion

    def reject(self, suggestion_id: str, mute: bool = False) -> None:
        """실행 없이 pending에서 제거(dismiss). 없는 id이거나 이미 승인된
        제안이면 UnknownSuggestionError — 기존 라우터의 pending 전용
        404 의미를 그대로 보존한다. 확인+제거가 락 안이라 승인과 원자적.

        mute=True면 "다시 추천 안 함" — 그 purpose를 억제 목록에 넣어 패턴이
        다시 만들지 않게 하고, 같은 루틴의 다른 pending 카드도 함께 내린다
        (한쪽에서 "그만"을 눌렀는데 다른 밴드 카드가 남아 있으면 모순)."""
        with self._state_lock:
            suggestion = self._suggestions.get(suggestion_id)
            if (
                suggestion is None
                or suggestion.status is not SuggestionStatus.PENDING
            ):
                raise UnknownSuggestionError(suggestion_id)
            purpose = suggestion.purpose
            self._suggestions.pop(suggestion_id)
            if mute:
                for sid in [
                    s.suggestion_id
                    for s in self._suggestions.values()
                    if s.purpose == purpose
                    and s.status is SuggestionStatus.PENDING
                ]:
                    self._suggestions.pop(sid, None)
        if mute and self._suppression_store is not None:
            self._suppression_store.mute(purpose)

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
        if self.is_dnd():
            return ()
        with self._state_lock:
            return tuple(
                suggestion
                for suggestion in self._suggestions.values()
                if suggestion.status is SuggestionStatus.PENDING
            )

    def approve(self, suggestion_id: str) -> object:
        # 승인권 획득(원자적) 후 실행은 락 밖에서 — 물리 실행을 락 안에서
        # 돌리면 그동안 모든 제안 조작이 멈춘다.
        suggestion = self._claim_for_approval(suggestion_id)
        return self._executor.execute_purpose(
            suggestion.purpose, suggestion.appliance_id
        )

    def approve_submit(self, suggestion_id: str) -> str:
        """approve의 비동기(job 모델) 버전 — 실행을 백그라운드로 제출하고
        job_id를 반환한다. 게이트 규칙은 approve와 동일: 실행 제출 전에
        1회용 승인 게이트를 닫는다. executor가 submit_purpose를 지원해야
        한다(SimpleLayService가 지원; 없으면 AttributeError로 즉시 드러남)."""
        # 화면이 보여준 대상 가전으로 실행한다 -- 전역 선택값이 그 사이
        # 바뀌어도 승인한 제안의 대상은 달라지지 않아야 한다.
        suggestion = self._claim_for_approval(suggestion_id)
        return self._executor.submit_purpose(
            suggestion.purpose, suggestion.appliance_id
        )

    def _pending_for(
        self, purpose: str, time_band: str
    ) -> ProactiveSuggestion | None:
        return next(
            (
                suggestion
                for suggestion in self._suggestions.values()
                if suggestion.purpose == purpose
                and suggestion.time_band == time_band
                and suggestion.status is SuggestionStatus.PENDING
            ),
            None,
        )
