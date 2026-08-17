"""Button press verification contracts and hardware-free test doubles."""

from .audio_sensor import AudioReader, AudioSensor, FakeAudioReader
from .base import VerificationResult, Verifier
from .config import (
    AudioSensorConfig,
    CurrentSensorConfig,
    DangerSoundConfig,
    FusionConfig,
    SensorConfig,
)
from .current_sensor import CurrentReader, CurrentSensor, FakeCurrentReader
from .danger_sound import DangerSoundDetector, DangerSoundResult
from .fusion import fuse
from .mock import MockVerifier
from .sensors import SensorVerifier

__all__ = [
    "AudioReader",
    "AudioSensor",
    "AudioSensorConfig",
    "CurrentReader",
    "CurrentSensor",
    "CurrentSensorConfig",
    "DangerSoundConfig",
    "DangerSoundDetector",
    "DangerSoundResult",
    "FakeAudioReader",
    "FakeCurrentReader",
    "FusionConfig",
    "MockVerifier",
    "SensorConfig",
    "SensorVerifier",
    "VerificationResult",
    "Verifier",
    "fuse",
]
