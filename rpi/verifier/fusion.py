"""Combines current and audio evidence into a single VerificationResult.

Truth table (docs/sensor-spec.md §4):

  current ✅  audio ✅  → pressed=True,  confidence=1.0
  current ✅  audio ❌  → pressed=True,  confidence=0.7  (current dominates)
  current ❌  audio ✅  → pressed=True,  confidence=0.6  (audio alone, weaker)
  current ❌  audio ❌  → pressed=False, confidence=0.0
"""

from __future__ import annotations

from .base import VerificationResult
from .config import FusionConfig


def fuse(
    current_pressed: bool,
    current_delta_a: float,
    audio_pressed: bool,
    audio_ratio: float,
    config: FusionConfig,
) -> VerificationResult:
    """Compute a VerificationResult from two sensor signals.

    Args:
        current_pressed:  Whether the current sensor detected a press.
        current_delta_a:  Delta current above baseline (amperes).
        audio_pressed:    Whether the audio sensor detected a press sound.
        audio_ratio:      FFT band-energy ratio (0.0–1.0).
        config:           FusionConfig with weights and threshold.

    Returns:
        VerificationResult with pressed flag, confidence, and human-readable detail.
    """
    # Normalise each signal to a 0-1 confidence score.
    current_score = float(current_pressed)
    audio_score = float(audio_pressed)

    weighted = (
        config.current_weight * current_score
        + config.audio_weight * audio_score
    )
    pressed = weighted >= config.confidence_threshold

    detail = (
        f"current={'✅' if current_pressed else '❌'} Δ{current_delta_a * 1000:.1f}mA | "
        f"audio={'✅' if audio_pressed else '❌'} ratio={audio_ratio:.2f} | "
        f"weighted={weighted:.2f}"
    )

    return VerificationResult(
        pressed=pressed,
        confidence=round(weighted, 4),
        detail=detail,
    )
