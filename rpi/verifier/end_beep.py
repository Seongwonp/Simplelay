"""가전 종료음(세탁기 끝 알림음) 검출 — 위험 소리 감지와 같은 DSP, 다른 프로필(2026-10-06, 결정 D2).

위험 소리(`danger_sound.py`)와 같은 두 단계를 쓴다:
  1. 대역 에너지 비율(``_band_energy_ratio`` — 버튼음·경보음과 같은 FFT 함수)이 임계값을 넘는 프레임의
     상승 에지 = 삐 소리 하나의 시작(onset).
  2. 시작 간격의 규칙성(``_periodicity_score`` — 경보음과 같은 함수).
다른 점은 **패턴의 끝**이다. 경보음은 계속 반복되고(``min_cycles`` 이상이면 위험), 종료음은 몇 번 울리고
멈춘다. 그래서 마지막 시작 뒤 ``silence_after_s`` 동안 조용하면 그 묶음을 판정한다:
``min_beeps`` ≤ 개수 ≤ ``max_beeps``이고 간격이 [min_period_s, max_period_s] 안에서 고르면 종료음.
``max_beeps``를 넘으면 경보 쪽이다 — 여기서는 종료음으로 보지 않는다(위험 소리 경로가 따로 본다).

**프로필 값은 전부 측정 필요** — 세탁기 모델마다 종료음(단음 반복·멜로디)·주파수가 다르다. 멜로디라면
``max_relative_stddev``를 넓히거나(1.0 = 규칙성 확인 끔) 프로필을 다시 잡는다. 합성 음으로만 시험했다.
"""

from __future__ import annotations

import os
from collections.abc import Iterable, Mapping
from dataclasses import asdict, dataclass

import numpy as np

from .audio_sensor import _band_energy_ratio
from .danger_sound import _periodicity_score

#: 환경 변수 이름(전부 선택). 전부 측정 필요.
END_BEEP_ENV_NAMES = {
    "freq_low_hz": "SIMPLELAY_BEEP_FREQ_LOW_HZ",
    "freq_high_hz": "SIMPLELAY_BEEP_FREQ_HIGH_HZ",
    "band_energy_threshold": "SIMPLELAY_BEEP_BAND_THRESHOLD",
    "min_beeps": "SIMPLELAY_BEEP_MIN_COUNT",
    "max_beeps": "SIMPLELAY_BEEP_MAX_COUNT",
    "min_period_s": "SIMPLELAY_BEEP_MIN_PERIOD_S",
    "max_period_s": "SIMPLELAY_BEEP_MAX_PERIOD_S",
    "silence_after_s": "SIMPLELAY_BEEP_SILENCE_S",
    "max_relative_stddev": "SIMPLELAY_BEEP_MAX_REL_STDDEV",
}
_INT_FIELDS = ("freq_low_hz", "freq_high_hz", "min_beeps", "max_beeps")


@dataclass(frozen=True)
class EndBeepConfig:
    """세탁기 종료음 프로필 — **전부 측정 필요**(실측 전 추정값)."""

    sample_rate: int = 16_000
    #: 종료음 대역 추정(Hz). 측정 필요 — 피에조 부저는 대개 2~4 kHz.
    freq_low_hz: int = 1_800
    freq_high_hz: int = 4_200
    #: 대역 에너지 비율 임계값(0~1). 측정 필요 — 세탁기 소음·생활 소음 위에서 정한다.
    band_energy_threshold: float = 0.35
    #: 종료음 하나의 삐 개수 범위. 측정 필요.
    min_beeps: int = 3
    max_beeps: int = 12
    #: 삐 시작 간격 범위(초). 측정 필요.
    min_period_s: float = 0.2
    max_period_s: float = 1.5
    #: 마지막 삐 뒤 이만큼 조용하면 묶음을 판정(초). max_period_s보다 커야 한다. 측정 필요.
    silence_after_s: float = 3.0
    #: 간격 규칙성(상대 표준편차 상한). 위험 소리와 같은 0.25. 멜로디면 넓힌다. 측정 필요.
    max_relative_stddev: float = 0.25

    def __post_init__(self) -> None:
        if not 0 < self.freq_low_hz < self.freq_high_hz <= self.sample_rate / 2:
            raise ValueError("주파수 대역은 0 < low < high ≤ sample_rate/2 여야 합니다")
        if not 0 < self.band_energy_threshold < 1:
            raise ValueError("band_energy_threshold는 0~1 사이여야 합니다")
        if not 2 <= self.min_beeps <= self.max_beeps:
            raise ValueError("2 ≤ min_beeps ≤ max_beeps 여야 합니다(간격을 하나 이상 재야 한다)")
        if not 0 < self.min_period_s < self.max_period_s:
            raise ValueError("0 < min_period_s < max_period_s 여야 합니다")
        if self.silence_after_s <= self.max_period_s:
            raise ValueError("silence_after_s는 max_period_s보다 커야 합니다(묶음이 중간에 잘린다)")
        if self.max_relative_stddev <= 0:
            raise ValueError("max_relative_stddev는 0보다 커야 합니다")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "EndBeepConfig":
        src = os.environ if env is None else env
        values: dict[str, float | int] = {}
        for field_name, env_name in END_BEEP_ENV_NAMES.items():
            raw = (src.get(env_name) or "").strip()
            if not raw:
                continue
            try:
                values[field_name] = int(raw) if field_name in _INT_FIELDS else float(raw)
            except ValueError as exc:
                raise RuntimeError(f"{env_name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
        try:
            return cls(**values)
        except ValueError as exc:
            raise RuntimeError(f"종료음 프로필 설정이 잘못됐습니다: {exc}") from exc


@dataclass(frozen=True)
class EndBeepMatch:
    """종료음 한 묶음. 시각은 호출하는 쪽 시계(``timestamp``) 축."""

    first_onset_s: float
    last_onset_s: float
    detected_at_s: float
    beeps: int
    mean_period_s: float
    peak_ratio: float

    def as_dict(self) -> dict:
        doc = {k: (round(v, 3) if isinstance(v, float) else v) for k, v in asdict(self).items()}
        doc["detail"] = f"종료음 {self.beeps}번(간격 {self.mean_period_s:.2f}초)"
        return doc


class EndBeepDetector:
    """연속 프레임을 받아 종료음 묶음을 찾는다. 묶음을 판정하면(맞든 아니든) 비우고 다음을 본다."""

    def __init__(self, config: EndBeepConfig | None = None) -> None:
        self._cfg = config or EndBeepConfig()
        self._onsets: list[float] = []
        self._count = 0  # 묶음 안 시작 수(목록은 max_beeps+1개까지만 둔다)
        self._was_above = False
        self._peak = 0.0
        #: 마지막으로 버린 묶음의 사유(확인용).
        self.last_rejection: str | None = None

    def process_frame(self, pcm: np.ndarray, timestamp: float) -> EndBeepMatch | None:
        cfg = self._cfg
        ratio = _band_energy_ratio(pcm, cfg.sample_rate, cfg.freq_low_hz, cfg.freq_high_hz)
        above = ratio >= cfg.band_energy_threshold
        if above:
            self._peak = max(self._peak, ratio)
        if above and not self._was_above:
            self._count += 1
            if len(self._onsets) <= cfg.max_beeps:
                self._onsets.append(timestamp)
        self._was_above = above
        if (not above and self._onsets
                and timestamp - self._onsets[-1] >= cfg.silence_after_s):
            return self._close(timestamp)
        return None

    def reset(self) -> None:
        self._onsets = []
        self._count = 0
        self._was_above = False
        self._peak = 0.0

    def _close(self, now: float) -> EndBeepMatch | None:
        cfg = self._cfg
        onsets, count, peak = self._onsets, self._count, self._peak
        self.reset()
        if not cfg.min_beeps <= count <= cfg.max_beeps:
            self.last_rejection = f"삐 {count}번 — 범위 {cfg.min_beeps}~{cfg.max_beeps} 밖"
            return None
        intervals = [b - a for a, b in zip(onsets, onsets[1:])]
        periodic, mean_period = _periodicity_score(
            intervals, cfg.min_period_s, cfg.max_period_s, cfg.max_relative_stddev)
        if not periodic:
            self.last_rejection = "간격이 범위 밖이거나 고르지 않음"
            return None
        self.last_rejection = None
        return EndBeepMatch(first_onset_s=onsets[0], last_onset_s=onsets[-1], detected_at_s=now,
                            beeps=count, mean_period_s=mean_period, peak_ratio=peak)


def detect_end_beeps(frames: Iterable[tuple[np.ndarray, float]],
                     config: EndBeepConfig | None = None) -> list[EndBeepMatch]:
    """``(pcm, 시각)`` 프레임열 전체에서 종료음 묶음을 찾는다(순수 함수 — 녹음 사후 분석·시험용)."""
    detector = EndBeepDetector(config)
    return [m for pcm, t in frames if (m := detector.process_frame(pcm, t)) is not None]
