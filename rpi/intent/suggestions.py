"""Proactive suggestion lifecycle with a mandatory one-time approval gate."""

from dataclasses import replace
from datetime import datetime, timedelta

from .base import IntentResolver
from .models import ProactiveSuggestion, SuggestionStatus
from .patterns import PatternDetector
from .ports import Clock, PurposeExecutor
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
    ) -> None:
        self._detector = detector
        self._clock = clock
        self._executor = executor
        self._intent_resolver = intent_resolver
        self._suggestions: dict[str, ProactiveSuggestion] = {}
        self._next_id = 1
        self._dnd_until: datetime | None = None

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
        created: list[ProactiveSuggestion] = []
        for candidate in self._detector.candidates():
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
                steps=self._preview_steps(candidate.purpose),
            )
            self._next_id += 1
            self._suggestions[suggestion.suggestion_id] = suggestion
            created.append(suggestion)
        return tuple(created)

    def create_demo_suggestion(
        self, purpose: str, occurrences: int = 3
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
        existing = self._pending_for(purpose, "데모")
        if existing is not None:
            return existing
        suggestion = ProactiveSuggestion(
            suggestion_id=f"suggestion-{self._next_id}",
            purpose=purpose,
            time_band="데모",
            occurrences=occurrences,
            created_at=self._clock.now(),
            steps=self._preview_steps(purpose),
        )
        self._next_id += 1
        self._suggestions[suggestion.suggestion_id] = suggestion
        return suggestion

    def reject(self, suggestion_id: str) -> None:
        """실행 없이 pending에서 제거(dismiss). 없는 id이거나 이미 승인된
        제안이면 UnknownSuggestionError — 기존 라우터의 pending 전용
        404 의미를 그대로 보존한다."""
        suggestion = self._suggestions.get(suggestion_id)
        if suggestion is None or suggestion.status is not SuggestionStatus.PENDING:
            raise UnknownSuggestionError(suggestion_id)
        self._suggestions.pop(suggestion_id)

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
        return tuple(
            suggestion
            for suggestion in self._suggestions.values()
            if suggestion.status is SuggestionStatus.PENDING
        )

    def approve(self, suggestion_id: str) -> object:
        try:
            suggestion = self._suggestions[suggestion_id]
        except KeyError as exc:
            raise UnknownSuggestionError(suggestion_id) from exc
        if suggestion.status is not SuggestionStatus.PENDING:
            raise SuggestionAlreadyApprovedError(suggestion_id)

        # Close the one-time gate before execution so repeated approval cannot
        # trigger the physical path even if execution raises an exception.
        self._suggestions[suggestion_id] = replace(
            suggestion, status=SuggestionStatus.APPROVED
        )
        return self._executor.execute_purpose(suggestion.purpose)

    def approve_submit(self, suggestion_id: str) -> str:
        """approve의 비동기(job 모델) 버전 — 실행을 백그라운드로 제출하고
        job_id를 반환한다. 게이트 규칙은 approve와 동일: 실행 제출 전에
        1회용 승인 게이트를 닫는다. executor가 submit_purpose를 지원해야
        한다(SimpleLayService가 지원; 없으면 AttributeError로 즉시 드러남)."""
        try:
            suggestion = self._suggestions[suggestion_id]
        except KeyError as exc:
            raise UnknownSuggestionError(suggestion_id) from exc
        if suggestion.status is not SuggestionStatus.PENDING:
            raise SuggestionAlreadyApprovedError(suggestion_id)

        self._suggestions[suggestion_id] = replace(
            suggestion, status=SuggestionStatus.APPROVED
        )
        return self._executor.submit_purpose(suggestion.purpose)

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
