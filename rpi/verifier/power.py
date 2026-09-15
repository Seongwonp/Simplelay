"""L3 동작 확인 — 가전 소비전력(CT 클램프)으로 "정말 동작을 시작/완료했는가"를 판정한다.

센서 구성(팀 하드웨어 계획):
  1단계  비접촉 CT 클램프 SCT-013-030(30 A → 1 V, 부담저항 내장)을 분리 코드
         구간의 **활선(L) 한 가닥에만** 물리고 ADS1115로 읽는다.
  2단계  패키징 단계에서 인라인 계량 IC(PZEM-004T 계열)로 교체 — 이 모듈 범위 밖.
         어느 쪽이든 ``PowerSensor`` 프로토콜만 맞추면 판정기는 그대로 쓴다.

예시 타임라인(전자레인지):
  대기 ≈3 W → 조리 ≈1,200 W  (L3 "조리 시작 확정")
            → 다시 ≈5 W     (L3 "완료 확정")

이 모듈은 **판정만** 돌려준다. L3 실패 시 자동 재시도하지 않고 멈춰서 사용자에게
알리는 정책은 호출하는 쪽에 있다.

``PowerConfig``의 모든 값은 실측 전 추정값이다 — config.py 머리말과 같은 원칙으로,
하드웨어 연결 후 실측값으로 교체한다. ADS1115 실제 배선·드라이버는 여기 없다
(``MockPowerSensor``로 테스트·리허설만 한다).

시각은 전부 샘플의 ``t_s``(단조 시각)에서 온다 — 판정기는 시스템 시계를 직접 읽지
않으므로 테스트에서 시간을 그대로 주입할 수 있다.
"""

from __future__ import annotations

import math
import statistics
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass
from enum import Enum
from typing import Protocol

import numpy as np

# 부동소수 시각 비교 여유 (10 Hz 샘플에서 1.0 s 유지가 0.9999…로 끊기지 않게)
_EPS_S = 1e-9

# 조작 시각 이후 관측 최대 전력을 구하려고 보관하는 샘플 수 상한
# (10 Hz 기준 1시간). 메모리가 무한히 늘지 않게 한다.
_HISTORY_MAX = 36_000


# ─────────────────────────────────────────────────────────────────────────────
# 샘플 · 센서 경계
# ─────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class PowerSample:
    """소비전력 샘플 한 개."""

    t_s: float  # 단조 시각(초)
    watts: float


class PowerSensor(Protocol):
    """하드웨어 경계 — CT 클램프(ADS1115)든 계량 IC든 샘플 한 개를 돌려준다."""

    def read(self) -> PowerSample: ...


@dataclass(frozen=True)
class PowerConfig:
    """전력 기반 L3 판정 파라미터.

    모두 추정값 — 실측 후 교체 (config.py 머리말과 같은 원칙).
    """

    # 상용 전원 전압 (V) — 추정값, 현장 실측 필요
    mains_voltage_v: float = 220.0

    # 역률 — 저항성 부하 가정. 전자레인지 인버터·모터 부하는 실측 필요
    power_factor: float = 1.0

    # SCT-013-030: 30 A 에서 1 V rms 출력
    ct_amps_per_volt: float = 30.0

    # 상승 직전 이 구간 샘플의 중앙값을 기준선으로 쓴다 (초)
    baseline_window_s: float = 2.0

    # 기준선 대비 최소 상승 (W)
    start_min_rise_w: float = 300.0

    # 기준선 대비 배율 (둘 다 만족해야 시작)
    start_rise_ratio: float = 5.0

    # 상승이 이만큼 유지돼야 확정 (돌입전류 순간값 배제, 초)
    start_confirm_s: float = 1.0

    # 버튼 조작 후 이 안에 시작이 확인돼야 함 (초)
    start_timeout_s: float = 5.0

    # 완료로 볼 전력 상한 (W)
    stop_max_w: float = 30.0

    # 완료 전력이 이만큼 유지돼야 확정 (초)
    stop_confirm_s: float = 2.0

    def __post_init__(self) -> None:
        if not self.mains_voltage_v > 0:
            raise ValueError("mains_voltage_v must be positive")
        if not 0.0 < self.power_factor <= 1.0:
            raise ValueError("power_factor must be in (0, 1]")
        if not self.ct_amps_per_volt > 0:
            raise ValueError("ct_amps_per_volt must be positive")
        if not self.baseline_window_s > 0:
            raise ValueError("baseline_window_s must be positive")
        if self.start_min_rise_w < 0 or self.start_rise_ratio < 1.0:
            raise ValueError("start_min_rise_w must be >= 0 and start_rise_ratio >= 1")
        if self.start_confirm_s < 0 or self.stop_confirm_s < 0:
            raise ValueError("confirm durations must be >= 0")
        if self.start_timeout_s < self.start_confirm_s:
            raise ValueError("start_timeout_s must be >= start_confirm_s")
        if self.stop_max_w < 0:
            raise ValueError("stop_max_w must be >= 0")


# ─────────────────────────────────────────────────────────────────────────────
# 변환 (순수 함수)
# ─────────────────────────────────────────────────────────────────────────────


def rms(values: Sequence[float]) -> float:
    """실효값(RMS).

    CT 출력을 ADS1115로 읽을 때 중점 바이어스(DC 오프셋)를 걸었다면 그 제거는
    호출하는 쪽 책임이다 — 여기서는 받은 값 그대로 제곱평균제곱근만 계산한다.
    """
    if len(values) == 0:
        raise ValueError("rms requires at least one value")
    return math.sqrt(math.fsum(v * v for v in values) / len(values))


def ct_voltage_rms_to_watts(v_rms: float, config: PowerConfig = PowerConfig()) -> float:
    """CT 출력 전압(rms) → 유효전력 추정(W).

    P = V_ct × (A/V) × V_mains × PF. 전압·역률은 실측 전 추정값이라 결과도 추정이다.
    판정은 절대값보다 기준선 대비 변화에 기대므로 이 오차에 비교적 둔감하다.
    """
    if not math.isfinite(v_rms) or v_rms < 0:
        raise ValueError("v_rms must be a finite, non-negative number")
    amps = v_rms * config.ct_amps_per_volt
    return amps * config.mains_voltage_v * config.power_factor


# ─────────────────────────────────────────────────────────────────────────────
# 판정
# ─────────────────────────────────────────────────────────────────────────────


class OperationPhase(str, Enum):
    IDLE = "idle"  # 대기 — 기준선 수집 중
    STARTING = "starting"  # 상승 감지, 유지 확인 중
    RUNNING = "running"  # 시작 확정
    STOPPING = "stopping"  # 하강 감지, 유지 확인 중
    FINISHED = "finished"  # 완료 확정


@dataclass(frozen=True)
class L3Verdict:
    """L3(동작 확인) 판정 결과."""

    layer: str  # always "L3"
    confirmed: bool
    phase: OperationPhase
    baseline_w: float | None
    peak_w: float | None
    detail: str  # 사람이 읽을 사유 (예: "기준선 3.1W → 1,183W, 1.2초 유지")
    decided_at_s: float | None


def _fmt_w(watts: float) -> str:
    """사람이 읽는 전력 표기 — 100 W 미만은 소수 1자리, 이상은 천 단위 구분."""
    return f"{watts:.1f}W" if watts < 100 else f"{watts:,.0f}W"


class PowerSignatureDetector:
    """전력 샘플 흐름을 받아 동작 단계를 추적하는 상태 기계.

    규칙:
      * 기준선 = 상승 직전 ``baseline_window_s`` 구간 샘플의 중앙값(순간 튐에 강함).
      * 시작 후보 = (전력 − 기준선) ≥ ``start_min_rise_w`` **그리고**
        전력 ≥ 기준선 × ``start_rise_ratio``. 후보 조건이 ``start_confirm_s`` 동안
        끊김 없이 유지돼야 RUNNING — 돌입전류 한 번으로는 확정되지 않는다.
      * 완료 = RUNNING 이후 전력 ≤ ``stop_max_w`` 가 ``stop_confirm_s`` 동안 유지.
      * 유한하지 않거나 음수인 전력, 직전 샘플과 같거나 이전 시각의 샘플은 무시한다.

    한 인스턴스는 조작 한 번(시작→완료)을 추적한다. FINISHED 이후 입력은 단계를
    바꾸지 않으므로, 다음 조작에는 새 인스턴스를 만든다.
    """

    def __init__(self, config: PowerConfig | None = None) -> None:
        self._cfg = config or PowerConfig()
        self._phase = OperationPhase.IDLE
        self._last_t: float | None = None
        self._last_w: float | None = None

        # IDLE 동안의 최근 샘플 (기준선 계산용)
        self._idle: deque[PowerSample] = deque()
        # 조작 시각 이후 최대 전력 계산용
        self._history: deque[PowerSample] = deque(maxlen=_HISTORY_MAX)

        self._baseline_w: float | None = None  # 상승 시작 시점에 고정한 기준선
        self._rise_start_s: float | None = None
        self._started_at_s: float | None = None  # 시작 확정 시각
        self._peak_w: float | None = None  # 상승 시작 이후 최대 전력
        self._stop_start_s: float | None = None
        self._finished_at_s: float | None = None

    # ------------------------------------------------------------------
    # 입력
    # ------------------------------------------------------------------

    @property
    def phase(self) -> OperationPhase:
        return self._phase

    def feed(self, sample: PowerSample) -> OperationPhase:
        """샘플 한 개를 시각 순서대로 넣고 현재 단계를 돌려준다."""
        t, w = sample.t_s, sample.watts
        if not (_is_finite(t) and _is_finite(w)) or w < 0:
            return self._phase
        if self._last_t is not None and t <= self._last_t:
            return self._phase

        self._last_t, self._last_w = t, w
        self._history.append(sample)

        if self._phase is OperationPhase.IDLE:
            self._feed_idle(sample)
        elif self._phase is OperationPhase.STARTING:
            self._feed_starting(sample)
        elif self._phase is OperationPhase.RUNNING:
            self._feed_running(sample)
        elif self._phase is OperationPhase.STOPPING:
            self._feed_stopping(sample)
        # FINISHED: 종단 상태
        return self._phase

    def _feed_idle(self, sample: PowerSample) -> None:
        baseline = self._idle_baseline(sample.t_s)
        if baseline is not None and self._is_rise(sample.watts, baseline):
            self._phase = OperationPhase.STARTING
            self._baseline_w = baseline
            self._rise_start_s = sample.t_s
            self._peak_w = sample.watts
            if self._cfg.start_confirm_s <= _EPS_S:
                self._confirm_start(sample.t_s)
            return
        self._idle.append(sample)

    def _feed_starting(self, sample: PowerSample) -> None:
        assert self._baseline_w is not None and self._rise_start_s is not None
        if not self._is_rise(sample.watts, self._baseline_w):
            # 유지되지 않음(돌입전류 등) — 후보 폐기, 이 샘플부터 다시 대기
            self._phase = OperationPhase.IDLE
            self._baseline_w = None
            self._rise_start_s = None
            self._peak_w = None
            self._feed_idle(sample)
            return
        self._peak_w = max(self._peak_w or 0.0, sample.watts)
        if sample.t_s - self._rise_start_s >= self._cfg.start_confirm_s - _EPS_S:
            self._confirm_start(sample.t_s)

    def _confirm_start(self, t_s: float) -> None:
        self._phase = OperationPhase.RUNNING
        self._started_at_s = t_s
        self._idle.clear()

    def _feed_running(self, sample: PowerSample) -> None:
        if sample.watts <= self._cfg.stop_max_w:
            self._phase = OperationPhase.STOPPING
            self._stop_start_s = sample.t_s
            if self._cfg.stop_confirm_s <= _EPS_S:
                self._confirm_finish(sample.t_s)
            return
        self._peak_w = max(self._peak_w or 0.0, sample.watts)

    def _feed_stopping(self, sample: PowerSample) -> None:
        assert self._stop_start_s is not None
        if sample.watts > self._cfg.stop_max_w:
            self._phase = OperationPhase.RUNNING
            self._stop_start_s = None
            self._peak_w = max(self._peak_w or 0.0, sample.watts)
            return
        if sample.t_s - self._stop_start_s >= self._cfg.stop_confirm_s - _EPS_S:
            self._confirm_finish(sample.t_s)

    def _confirm_finish(self, t_s: float) -> None:
        self._phase = OperationPhase.FINISHED
        self._finished_at_s = t_s

    # ------------------------------------------------------------------
    # 판정 규칙
    # ------------------------------------------------------------------

    def _idle_baseline(self, now_s: float) -> float | None:
        """now_s 직전 baseline_window_s 구간 대기 샘플의 중앙값. 샘플이 없으면 None."""
        horizon = now_s - self._cfg.baseline_window_s - _EPS_S
        while self._idle and self._idle[0].t_s < horizon:
            self._idle.popleft()
        if not self._idle:
            return None
        return float(statistics.median(s.watts for s in self._idle))

    def _is_rise(self, watts: float, baseline: float) -> bool:
        rise_ok = watts - baseline >= self._cfg.start_min_rise_w
        ratio_ok = watts >= baseline * self._cfg.start_rise_ratio
        return rise_ok and ratio_ok

    def _peak_since(self, since_s: float) -> float | None:
        values = [s.watts for s in self._history if s.t_s >= since_s - _EPS_S]
        return max(values) if values else None

    # ------------------------------------------------------------------
    # 판정 결과
    # ------------------------------------------------------------------

    def verify_started(self, *, since_s: float) -> L3Verdict:
        """``since_s``(시작 버튼 조작 시각) 이후 동작 시작이 확인됐는지 판정한다.

        * 조작 이후 상승이 시작돼 제한 시간 안에 확정됐으면 confirmed=True.
        * 아직 ``start_timeout_s``가 지나지 않았으면 confirmed=False, detail "판정 대기".
        * 제한 시간이 지났는데 확정이 없으면 confirmed=False와 관측 최대 전력.

        상승이 조작 시각보다 먼저 시작됐다면 이번 조작의 결과로 보지 않는다.
        """
        cfg = self._cfg
        deadline = since_s + cfg.start_timeout_s
        now = self._last_t

        if self._started_at_s is not None:
            assert self._rise_start_s is not None and self._baseline_w is not None
            held = self._started_at_s - self._rise_start_s
            if self._rise_start_s < since_s - _EPS_S:
                return self._verdict(
                    confirmed=False,
                    detail=(
                        f"조작({since_s:.1f}초) 이전({self._rise_start_s:.1f}초)부터 "
                        "이미 동작 중 — 이번 조작의 결과로 볼 수 없음"
                    ),
                    decided_at_s=now,
                )
            if self._started_at_s <= deadline + _EPS_S:
                return self._verdict(
                    confirmed=True,
                    detail=(
                        f"기준선 {_fmt_w(self._baseline_w)} → {_fmt_w(self._peak_w or 0.0)}, "
                        f"{held:.1f}초 유지"
                    ),
                    decided_at_s=self._started_at_s,
                )
            # 확정이 제한 시간 뒤 — 아래 실패 경로로

        # 기준선은 상승 후보가 있으면 그 값, 없으면 조작 직전 구간의 중앙값
        # (지속된 소부하 변화가 대기 기준선에 섞여 들어가 사유를 흐리지 않게)
        baseline = (
            self._baseline_w if self._baseline_w is not None else self._baseline_before(since_s)
        )

        if now is None or now < deadline - _EPS_S:
            return self._verdict(
                confirmed=False,
                detail="판정 대기",
                decided_at_s=None,
                baseline_w=baseline,
            )

        peak = self._peak_since(since_s)
        parts = [f"기준선 {_fmt_w(baseline)}" if baseline is not None else "기준선 없음"]
        parts.append(f"관측 최대 {_fmt_w(peak)}" if peak is not None else "관측 샘플 없음")
        parts.append(f"제한 {cfg.start_timeout_s:.1f}초")
        return self._verdict(
            confirmed=False,
            detail=f"시작 전력 상승이 확인되지 않음 ({', '.join(parts)})",
            decided_at_s=deadline,
            baseline_w=baseline,
            peak_w=peak,
        )

    def verify_finished(self) -> L3Verdict:
        """시작 확정 이후 완료(전력 하강 유지)가 확인됐는지 판정한다.

        완료 제한 시간은 두지 않는다 — 조리 시간은 가전·메뉴마다 달라 호출하는 쪽이 정한다.
        """
        cfg = self._cfg
        phase = self._phase
        if phase is OperationPhase.FINISHED:
            assert self._stop_start_s is not None and self._finished_at_s is not None
            held = self._finished_at_s - self._stop_start_s
            return self._verdict(
                confirmed=True,
                detail=(
                    f"최대 {_fmt_w(self._peak_w or 0.0)} → {_fmt_w(cfg.stop_max_w)} 이하 "
                    f"{held:.1f}초 유지"
                ),
                decided_at_s=self._finished_at_s,
            )
        if phase is OperationPhase.RUNNING:
            detail = f"동작 중 (현재 {_fmt_w(self._last_w or 0.0)})"
        elif phase is OperationPhase.STOPPING:
            assert self._stop_start_s is not None and self._last_t is not None
            elapsed = self._last_t - self._stop_start_s
            detail = (
                f"전력 하강 확인 중 ({elapsed:.1f}/{cfg.stop_confirm_s:.1f}초, "
                f"현재 {_fmt_w(self._last_w or 0.0)})"
            )
        else:
            detail = "시작이 확인되지 않아 완료를 판정할 수 없음"
        return self._verdict(confirmed=False, detail=detail, decided_at_s=None)

    def _baseline_before(self, since_s: float) -> float | None:
        """since_s 직전 baseline_window_s 구간(수신 샘플 전체)의 중앙값. 샘플이 없으면 None."""
        lo = since_s - self._cfg.baseline_window_s - _EPS_S
        window = [s.watts for s in self._history if lo <= s.t_s < since_s - _EPS_S]
        return float(statistics.median(window)) if window else None

    _UNSET = object()

    def _verdict(
        self,
        *,
        confirmed: bool,
        detail: str,
        decided_at_s: float | None,
        baseline_w: float | None | object = _UNSET,
        peak_w: float | None | object = _UNSET,
    ) -> L3Verdict:
        return L3Verdict(
            layer="L3",
            confirmed=confirmed,
            phase=self._phase,
            baseline_w=self._baseline_w if baseline_w is self._UNSET else baseline_w,  # type: ignore[arg-type]
            peak_w=self._peak_w if peak_w is self._UNSET else peak_w,  # type: ignore[arg-type]
            detail=detail,
            decided_at_s=decided_at_s,
        )


def _is_finite(value: float) -> bool:
    try:
        return math.isfinite(value)
    except TypeError:
        return False


# ─────────────────────────────────────────────────────────────────────────────
# 테스트·리허설용
# ─────────────────────────────────────────────────────────────────────────────


class MockPowerSensor:
    """미리 준 샘플을 순서대로 돌려준다(테스트·리허설용). 소진 시 마지막 샘플 반복."""

    def __init__(self, samples: Sequence[PowerSample]) -> None:
        if len(samples) == 0:
            raise ValueError("MockPowerSensor requires at least one sample")
        self._samples = list(samples)
        self._index = 0

    def read(self) -> PowerSample:
        if self._index >= len(self._samples):
            return self._samples[-1]  # hold last value
        sample = self._samples[self._index]
        self._index += 1
        return sample


def microwave_profile(
    *,
    idle_w: float = 3.0,
    run_w: float = 1200.0,
    run_s: float = 30.0,
    hz: float = 10.0,
    start_at_s: float = 1.0,
    noise_w: float = 0.0,
    seed: int = 0,
    tail_s: float = 5.0,
) -> list[PowerSample]:
    """리허설·테스트용 합성 전자레인지 파형.

    [0, start_at_s) 대기 → [start_at_s, start_at_s + run_s) 조리 → tail_s 동안 대기.
    ``noise_w``는 표준편차(W)인 가우시안 잡음(seed 고정), 음수는 0으로 자른다.
    실제 인버터 전자레인지는 출력 단계에 따라 전력이 주기적으로 오르내릴 수 있어
    이 사각파와 다를 수 있다 — 실측 파형으로 교체할 것.
    """
    if hz <= 0:
        raise ValueError("hz must be positive")
    total_s = start_at_s + run_s + tail_s
    n = int(round(total_s * hz))
    rng = np.random.default_rng(seed)
    noise = rng.normal(0.0, noise_w, n) if noise_w > 0 else np.zeros(n)
    run_end_s = start_at_s + run_s

    samples: list[PowerSample] = []
    for i in range(n):
        t = i / hz
        base = run_w if start_at_s - _EPS_S <= t < run_end_s - _EPS_S else idle_w
        samples.append(PowerSample(t_s=t, watts=max(0.0, base + float(noise[i]))))
    return samples
