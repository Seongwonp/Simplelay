from abc import ABC, abstractmethod


class IntentResolver(ABC):
    @abstractmethod
    def resolve(self, purpose: str) -> tuple[str, ...]:
        """Translate a user purpose without knowing coordinates or G-code."""

    def learning_purpose(self, purpose: str, buttons: tuple[str, ...]) -> str:
        """Conservative default: unknown/custom resolvers keep the original name."""
        return purpose.strip()
