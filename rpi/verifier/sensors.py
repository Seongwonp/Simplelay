"""SensorVerifier — wires CurrentSensor + AudioSensor through FusionConfig."""

from __future__ import annotations

import time
from collections.abc import Callable

from .audio_sensor import AudioReader, AudioSensor
from .base import SensorUnavailable, VerificationResult, Verifier
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

    **누름 관측 구간(2026-10-07):** `ClosedLoopController`가 누르기 직전에
    ``begin_press``를 부르고(전류 기준선 + 오래된 소리 버림), 누르는 동안 두 센서가
    시각과 함께 계속 모으며, ``verify``가 누름 뒤 구간을 닫아 판정한다. 누름이 실패하면
    ``cancel_press``. ``begin_press`` 없이 ``verify``만 부르면 그 자리에서 짧은 구간을
    열고 닫는다(지금 상태만 본다 — 누름 증거로는 약하다).

    어느 센서든 읽을 수 없으면(단절) `SensorUnavailable`을 낸다 — 무음·전류 0과
    구분하고, 한쪽만 살아 있어도 판정하지 않는다(fail closed).
    """

    def __init__(
        self,
        config: SensorConfig | None = None,
        current_reader: CurrentReader | None = None,
        audio_reader: AudioReader | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        cfg = config or SensorConfig()
        self._cfg = cfg
        self._clock = clock

        if current_reader is None:
            from .current_sensor import Ads1115Reader
            current_reader = Ads1115Reader(cfg.current)

        if audio_reader is None:
            from .audio_sensor import SounddeviceReader
            audio_reader = SounddeviceReader(cfg.audio)

        self._current = CurrentSensor(current_reader, cfg.current, clock=clock)
        self._audio = AudioSensor(audio_reader, cfg.audio, clock=clock)


    def begin_press(self, button: str) -> None:  # noqa: ARG002
        """누르기 직전 — 전류 기준선을 잡고, 그때까지 쌓인 소리를 버린다."""
        try:
            self._current.open_window()
            self._audio.open_window()
        except BaseException:
            self.cancel_press()
            raise

    def cancel_press(self) -> None:
        """판정 없이 구간을 닫는다(누름 명령 실패·중단)."""
        self._current.cancel_window()
        self._audio.cancel_window()

    # Verifier protocol

    def verify(self, button: str) -> VerificationResult:
        """누름 구간을 닫고 두 센서 증거를 합친다.

        The ``button`` argument is accepted for protocol compatibility but
        not used; the sensor reads the appliance state, not a specific button.
        """
        if not self._current.window_open:
            self.begin_press(button)
        ended_at = self._clock()
        current = audio = None
        faults: list[str] = []
        try:
            current = self._current.close_window(ended_at)
        except SensorUnavailable as exc:
            faults.append(str(exc))
        try:
            audio = self._audio.close_window(ended_at)
        except SensorUnavailable as exc:
            faults.append(str(exc))
        if faults or current is None or audio is None:
            raise SensorUnavailable("; ".join(faults) or "sensor window incomplete")

        result = fuse(
            current_pressed=current.pressed,
            current_delta_a=current.peak_delta_a,
            audio_pressed=audio.pressed,
            audio_ratio=audio.peak_ratio,
            config=self._cfg.fusion,
        )
        return VerificationResult(
            pressed=result.pressed,
            confidence=result.confidence,
            detail=(
                f"{result.detail} | window: current {current.above}/{current.samples} "
                f"base={current.baseline_a * 1000:.1f}mA, audio {audio.above}/{audio.frames}"
            ),
        )

    def close(self) -> None:
        """Release hardware resources."""
        self.cancel_press()
        self._audio.close()
