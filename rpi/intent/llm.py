"""LLM-backed intent resolution: validated model output with a rule-based fallback."""

import json
import urllib.request
from dataclasses import dataclass

from .base import IntentResolver
from .ports import LlmClient
from .rules import UnknownIntentError


class LlmOutputError(ValueError):
    """Raised when the model response is missing or is not valid JSON."""


class LlmSequenceValidationError(ValueError):
    """Raised when the proposed sequence is empty or names an unknown button."""


def _parse_sequence(raw: str) -> tuple[str, ...]:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise LlmOutputError(f"model output is not valid JSON: {raw!r}") from exc

    if not isinstance(payload, dict) or "sequence" not in payload:
        raise LlmOutputError(f"model output is missing a 'sequence' field: {raw!r}")

    sequence = payload["sequence"]
    is_valid_shape = isinstance(sequence, list) and all(
        isinstance(item, str) and item.strip() for item in sequence
    )
    if not is_valid_shape or not sequence:
        raise LlmSequenceValidationError(
            f"'sequence' must be a non-empty list of button names: {sequence!r}"
        )

    return tuple(item.strip() for item in sequence)


class LlmIntentResolver(IntentResolver):
    """Resolves free-form purposes through an LLM, with validation and fallback.

    The model is treated as untrusted input: its response must be valid JSON
    naming only buttons from ``known_buttons`` (when a non-empty vocabulary is
    supplied). Any failure -- malformed JSON, an unknown button, an empty
    sequence, or the client call itself raising -- falls back to ``fallback``
    when one was given, otherwise surfaces as ``UnknownIntentError`` so callers
    only ever have one exception type to handle.
    """

    def __init__(
        self,
        client: LlmClient,
        known_buttons: frozenset[str] = frozenset(),
        fallback: IntentResolver | None = None,
    ) -> None:
        self._client = client
        self._known_buttons = known_buttons
        self._fallback = fallback

    def resolve(self, purpose: str) -> tuple[str, ...]:
        normalized = purpose.strip()
        if not normalized:
            raise UnknownIntentError("purpose must not be blank")

        try:
            raw = self._client.complete(normalized, tuple(sorted(self._known_buttons)))
            sequence = _parse_sequence(raw)
            if self._known_buttons:
                unknown = [b for b in sequence if b not in self._known_buttons]
                if unknown:
                    raise LlmSequenceValidationError(
                        f"model named unknown buttons: {unknown}"
                    )
            return sequence
        except Exception as exc:  # model output/call is untrusted; fall back on any failure
            if self._fallback is not None:
                try:
                    return self._fallback.resolve(normalized)
                except UnknownIntentError:
                    pass
            raise UnknownIntentError(f"unsupported purpose: {normalized}") from exc


@dataclass(frozen=True)
class HttpLlmClientConfig:
    base_url: str
    api_key: str
    model: str
    timeout_seconds: float = 10.0


class HttpLlmClient(LlmClient):
    """Calls an OpenAI-compatible chat-completions endpoint for intent resolution."""

    _SYSTEM_PROMPT = (
        "You translate a home-appliance voice command into a button-press sequence. "
        'Respond with JSON only, in the exact shape {"sequence": ["<button label>", ...]}. '
        "Use only button labels from the provided list, in the order they must be pressed. "
        'If the command does not match any reasonable sequence, respond with {"sequence": []}.'
    )

    def __init__(self, config: HttpLlmClientConfig) -> None:
        self._config = config

    def complete(self, purpose: str, known_buttons: tuple[str, ...]) -> str:
        user_prompt = f"Available buttons: {list(known_buttons)}\nCommand: {purpose}"
        body = json.dumps(
            {
                "model": self._config.model,
                "messages": [
                    {"role": "system", "content": self._SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                "temperature": 0,
            }
        ).encode("utf-8")

        request = urllib.request.Request(
            f"{self._config.base_url.rstrip('/')}/chat/completions",
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._config.api_key}",
            },
        )
        try:
            with urllib.request.urlopen(
                request, timeout=self._config.timeout_seconds
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
            return payload["choices"][0]["message"]["content"]
        except Exception as exc:  # network/HTTP/shape errors all become one clear signal
            raise LlmOutputError(f"LLM request failed: {exc}") from exc
