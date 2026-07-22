from .base import IntentResolver


class LlmIntentResolver(IntentResolver):
    """TODO(M4): implement after defining model output validation and fallback."""

    def resolve(self, purpose: str) -> tuple[str, ...]:
        raise NotImplementedError("LLM intent resolution is reserved for M4")
