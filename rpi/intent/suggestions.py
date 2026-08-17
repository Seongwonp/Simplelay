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
