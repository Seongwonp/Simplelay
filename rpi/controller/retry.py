"""Retry policy derived from docs/closed-loop-design.md."""

from abc import ABC, abstractmethod

from .models import Correction


class RetryPolicy(ABC):
    @property
    @abstractmethod
    def max_attempts(self) -> int:
        """Maximum total press attempts, including the first attempt."""

    @abstractmethod
    def correction_for(self, retry_number: int) -> Correction:
        """Describe the correction for retry 1, 2, ..."""


class DocumentedRetryPolicy(RetryPolicy):
    """Request XY adjustment and deeper Z pressing, capped at three attempts.

    Distances are deliberately absent: a measured hardware profile must convert
    this qualitative request into values that respect the Z soft limit.
    """

    def __init__(self, max_attempts: int = 3) -> None:
        if max_attempts < 1:
            raise ValueError("max_attempts must be at least 1")
        self._max_attempts = max_attempts

    @property
    def max_attempts(self) -> int:
        return self._max_attempts

    def correction_for(self, retry_number: int) -> Correction:
        if retry_number < 1:
            raise ValueError("retry_number must be at least 1")
        return Correction(
            retry_number=retry_number,
            xy_adjustment_required=True,
            increase_press_depth=True,
        )
