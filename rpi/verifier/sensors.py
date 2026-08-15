"""SensorVerifier — wires CurrentSensor + AudioSensor through FusionConfig."""

from __future__ import annotations

from .audio_sensor import AudioReader, AudioSensor
from .base import VerificationResult, Verifier
from .config import SensorConfig
from .current_sensor import CurrentReader, CurrentSensor
from .fusion import fuse


class SensorVerifier(Verifier):
    """Real sensor verification: current + audio → fused VerificationResult.

    Dependency-inject readers so the class is fully testable without hardware:

        verifier = SensorVerifier(
            current_reader=FakeCurrentReader([2.5, 2.5, ..., 2.57]),
            audio_reader=FakeAudioReader([FakeAudioReader.tone(1200)]),
            config=SensorConfig(),
        )

    On real hardware leave readers as None and the class constructs
    Ads1115Reader and SounddeviceReader automatically.
    """

    def __init__(
        self,
        config: SensorConfig | None = None,
        current_reader: CurrentReader | None = None,
        audio_reader: AudioReader | None = None,
    ) -> None:
        cfg = config or SensorConfig()
        self._cfg = cfg

        if current_reader is None:
            from .current_sensor import Ads1115Reader
            current_reader = Ads1115Reader(cfg.current)

        if audio_reader is None:
            from .audio_sensor import SounddeviceReader
            audio_reader = SounddeviceReader(cfg.audio)

        self._current = CurrentSensor(current_reader, cfg.current)
        self._audio = AudioSensor(audio_reader, cfg.audio)

    # ------------------------------------------------------------------
    # Verifier protocol
    # ------------------------------------------------------------------

    def verify(self, button: str) -> VerificationResult:  # noqa: ARG002
        """Sample both sensors once and return a fused result.

        The ``button`` argument is accepted for protocol compatibility but
        not used; the sensor reads the appliance state, not a specific button.
        """
        current_pressed, current_delta = self._current.is_pressed()
        audio_pressed, audio_ratio = self._audio.is_pressed()

        return fuse(
            current_pressed=current_pressed,
            current_delta_a=current_delta,
            audio_pressed=audio_pressed,
            audio_ratio=audio_ratio,
            config=self._cfg.fusion,
        )

    def close(self) -> None:
        """Release hardware resources."""
        self._audio.close()
