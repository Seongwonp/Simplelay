"""Placeholder boundary for the future physical sensor implementation."""

from .base import VerificationResult, Verifier


class SensorVerifier(Verifier):
    """TODO(M1): combine contact and current/audio evidence from real sensors."""

    def verify(self, button: str) -> VerificationResult:
        raise NotImplementedError(
            "Real sensor verification requires M1 hardware measurements and calibration"
        )
