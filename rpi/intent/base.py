from abc import ABC, abstractmethod


class IntentResolver(ABC):
    @abstractmethod
    def resolve(self, purpose: str) -> tuple[str, ...]:
        """Translate a user purpose without knowing coordinates or G-code."""
