"""누름 판정 융합(rpi/verifier/fusion.py)의 기본 설정 진리표를 고정한다.

기본 FusionConfig(전류 0.55·음향 0.45·임계 0.50)에서는 전류(L1) 판정이 필수이고
음향은 신뢰도를 보탤 뿐이다 — 음향만으로는 눌림으로 판정하지 않는다.
가중치·임계값을 바꾸면 이 시험과 fusion.py 머리말·제출 문서를 함께 고친다.
"""

from __future__ import annotations

import pytest

from rpi.verifier.config import FusionConfig
from rpi.verifier.fusion import fuse


@pytest.mark.parametrize(
    ("current", "audio", "pressed", "confidence"),
    [
        (True, True, True, 1.0),
        (True, False, True, 0.55),
        (False, True, False, 0.45),
        (False, False, False, 0.0),
    ],
)
def test_default_truth_table(current, audio, pressed, confidence):
    result = fuse(
        current_pressed=current,
        current_delta_a=0.02 if current else 0.0,
        audio_pressed=audio,
        audio_ratio=0.5 if audio else 0.0,
        config=FusionConfig(),
    )
    assert result.pressed is pressed
    assert result.confidence == pytest.approx(confidence)


def test_audio_alone_is_not_a_press():
    result = fuse(False, 0.0, True, 0.9, FusionConfig())
    assert result.pressed is False


def test_current_alone_is_a_press():
    result = fuse(True, 0.02, False, 0.0, FusionConfig())
    assert result.pressed is True
