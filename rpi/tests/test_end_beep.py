"""세탁기 종료음 검출기(rpi/verifier/end_beep.py) 시험 — 합성 음(실측 아님)."""

from __future__ import annotations

import numpy as np
import pytest

from rpi.verifier.audio_sensor import FakeAudioReader
from rpi.verifier.end_beep import (
    END_BEEP_ENV_NAMES,
    EndBeepConfig,
    EndBeepDetector,
    detect_end_beeps,
)

RATE, CHUNK = 16_000, 512
FRAME_S = CHUNK / RATE  # 32 ms
CFG = EndBeepConfig(freq_low_hz=2000, freq_high_hz=3000, min_beeps=3, max_beeps=6,
                    min_period_s=0.3, max_period_s=1.2, silence_after_s=2.0)


def _tone(hz=2500.0):
    return FakeAudioReader.tone(hz, CHUNK, RATE)


def _silence():
    return np.zeros(CHUNK, dtype=np.float32)


def _pattern(beeps, *, period_s=0.6, on_s=0.2, hz=2500.0, tail_s=3.0, jitter=None):
    """beeps번 울리고 tail_s 조용한 프레임열 [(pcm, t)]."""
    frames, t = [], 0.0
    for i in range(beeps):
        start = i * period_s + (jitter[i] if jitter else 0.0)
        while t < start:
            frames.append((_silence(), t))
            t += FRAME_S
        end = start + on_s
        while t < end:
            frames.append((_tone(hz), t))
            t += FRAME_S
    stop = t + tail_s
    while t < stop:
        frames.append((_silence(), t))
        t += FRAME_S
    return frames


def test_three_steady_beeps_then_silence_match():
    (match,) = detect_end_beeps(_pattern(3), CFG)
    assert match.beeps == 3
    assert match.mean_period_s == pytest.approx(0.6, abs=0.05)
    assert match.last_onset_s == pytest.approx(1.2, abs=0.05)
    assert match.as_dict()["beeps"] == 3


def test_wrong_frequency_is_not_a_match():
    assert detect_end_beeps(_pattern(3, hz=800.0), CFG) == []


def test_too_few_beeps_is_not_a_match():
    assert detect_end_beeps(_pattern(2), CFG) == []


def test_alarm_that_keeps_repeating_is_not_an_end_beep():
    # 계속 반복되는 소리(경보)는 max_beeps를 넘는다 — 종료음이 아니다(위험 소리 경로의 몫).
    assert detect_end_beeps(_pattern(12), CFG) == []


def test_irregular_intervals_are_not_a_match():
    assert detect_end_beeps(_pattern(4, jitter=[0.0, 0.0, 0.5, -0.0]), CFG) == []


def test_continuous_tone_is_not_a_match():
    frames = [(_tone(), i * FRAME_S) for i in range(100)] + \
             [(_silence(), (100 + i) * FRAME_S) for i in range(100)]
    assert detect_end_beeps(frames, CFG) == []


def test_streaming_detector_reports_once_after_silence():
    detector = EndBeepDetector(CFG)
    hits = [m for pcm, t in _pattern(4) if (m := detector.process_frame(pcm, t)) is not None]
    assert len(hits) == 1 and hits[0].beeps == 4


def test_regularity_check_can_be_relaxed_for_melodies():
    relaxed = EndBeepConfig(freq_low_hz=2000, freq_high_hz=3000, min_beeps=3, max_beeps=6,
                            min_period_s=0.3, max_period_s=1.2, silence_after_s=2.0,
                            max_relative_stddev=1.0)
    assert len(detect_end_beeps(_pattern(4, jitter=[0.0, 0.0, 0.25, 0.0]), relaxed)) == 1


def test_config_validation_and_env():
    with pytest.raises(ValueError):
        EndBeepConfig(min_beeps=5, max_beeps=3)
    with pytest.raises(ValueError):
        EndBeepConfig(max_period_s=3.0, silence_after_s=2.0)
    cfg = EndBeepConfig.from_env({END_BEEP_ENV_NAMES["freq_low_hz"]: "1500",
                                  END_BEEP_ENV_NAMES["min_beeps"]: "4"})
    assert cfg.freq_low_hz == 1500 and cfg.min_beeps == 4
    with pytest.raises(RuntimeError):
        EndBeepConfig.from_env({END_BEEP_ENV_NAMES["max_beeps"]: "x"})
