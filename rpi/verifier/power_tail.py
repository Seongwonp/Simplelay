"""잔여 전류 꼬리(피드백 ③) — 완료 판정 뒤 대기 전력으로 돌아오기까지를 잰다. **판정 기준은 전부 측정 필요.**

L3는 '동작 시작'을 확인하면 결과를 보낸다. 그 뒤 가전이 끝나고(전력 하강 유지 = 완료 판정) 나서도
팬·조명·대기 회로 때문에 전류가 바로 대기값으로 돌아오지 않을 수 있다. 이 모듈은 그 꼬리를 기록용
숫자로 만든다 — **판정이 아니라 기록**이다. 결과를 근거로 자동 동작을 하지 않는다.

정의(샘플 시각 ``t_s`` 기준, 시스템 시계를 읽지 않는다):
  pre_baseline_w   사용 전 기준선. L3 판정기가 상승 직전에 잡은 대기 전력 중앙값을 받는다.
  완료 판정        전력 ≤ ``off_max_w``가 ``off_confirm_s`` 동안 끊김 없이 유지된 시각(finished_at_s).
                   `PowerSignatureDetector`의 완료 규칙과 같은 모양이다.
  기준선 띠        |전력 − pre_baseline_w| ≤ max(``band_abs_w``, ``band_ratio`` × pre_baseline_w).
  복귀             완료 판정 뒤 띠 안의 샘플이 ``settle_s`` 동안 끊김 없이 이어지면, 그 연속 구간의
                   첫 샘플 시각이 returned_at_s다.
  tail_s           returned_at_s − finished_at_s (복귀 못 하면 None).
  tail_mean_w/max  완료 판정 뒤 ~ 복귀 직전(복귀 못 하면 관찰 끝까지) 샘플의 평균·최대.
  post_baseline_w  복귀 구간(settle_s) 샘플의 중앙값. 복귀 못 하면 마지막 settle_s 구간의 중앙값.

``status``: returned(복귀) · timeout(``max_wait_s`` 안에 복귀 못 함) · no_finish(완료 판정 전에 끝남) ·
no_baseline(사용 전 기준선 없음) · stale(센서 끊김) · stopped(관찰 중단).
"""

from __future__ import annotations

import math
import os
import statistics
from collections.abc import Iterable, Mapping
from dataclasses import asdict, dataclass

from .power import PowerSample

_EPS_S = 1e-9

TAIL_STATUSES = ("returned", "timeout", "no_finish", "no_baseline", "stale", "stopped")

#: 환경 변수 이름(전부 선택). 값은 W·초.
TAIL_ENV_NAMES = {
    "off_max_w": "SIMPLELAY_TAIL_OFF_MAX_W",
    "off_confirm_s": "SIMPLELAY_TAIL_OFF_CONFIRM_S",
    "band_abs_w": "SIMPLELAY_TAIL_BAND_W",
    "band_ratio": "SIMPLELAY_TAIL_BAND_RATIO",
    "settle_s": "SIMPLELAY_TAIL_SETTLE_S",
    "max_wait_s": "SIMPLELAY_TAIL_MAX_WAIT_S",
    "max_run_s": "SIMPLELAY_TAIL_MAX_RUN_S",
}


@dataclass(frozen=True)
class TailConfig:
    """꼬리 측정 파라미터 — **전부 측정 필요**(실측 전 설계 초기값)."""

    #: 완료로 볼 전력 상한(W). PowerConfig.stop_max_w와 같은 초기값.
    off_max_w: float = 30.0
    #: 완료 전력이 이만큼 유지돼야 완료 판정(초). PowerConfig.stop_confirm_s와 같은 초기값.
    off_confirm_s: float = 2.0
    #: 기준선 띠 절대 폭(W).
    band_abs_w: float = 5.0
    #: 기준선 띠 비율(기준선 × 이 값). 둘 중 큰 쪽을 쓴다.
    band_ratio: float = 0.5
    #: 띠 안에 이만큼 머물러야 '복귀'(초).
    settle_s: float = 3.0
    #: 완료 판정 뒤 꼬리를 보는 최대 시간(초).
    max_wait_s: float = 120.0
    #: 결과 뒤 완료 판정을 기다리는 최대 시간(초). 넘으면 no_finish.
    max_run_s: float = 3600.0

    def __post_init__(self) -> None:
        for name in ("off_max_w", "band_abs_w", "band_ratio", "off_confirm_s", "settle_s"):
            value = getattr(self, name)
            if not (math.isfinite(value) and value >= 0):
                raise ValueError(f"{name}는 0 이상의 유한한 수여야 합니다: {value!r}")
        for name in ("max_wait_s", "max_run_s"):
            value = getattr(self, name)
            if not (math.isfinite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 커야 합니다: {value!r}")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "TailConfig":
        src = os.environ if env is None else env
        values: dict[str, float] = {}
        for field_name, env_name in TAIL_ENV_NAMES.items():
            raw = (src.get(env_name) or "").strip()
            if not raw:
                continue
            try:
                values[field_name] = float(raw)
            except ValueError as exc:
                raise RuntimeError(f"{env_name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
        try:
            return cls(**values)
        except ValueError as exc:
            raise RuntimeError(f"잔여 전류 설정이 잘못됐습니다: {exc}") from exc


@dataclass(frozen=True)
class TailMetrics:
    status: str
    pre_baseline_w: float | None
    post_baseline_w: float | None
    finished_at_s: float | None
    returned_at_s: float | None
    tail_s: float | None
    tail_mean_w: float | None
    tail_max_w: float | None
    band_w: float | None
    samples: int
    #: 판정 입력이 실물(real)인지 합성(mock)인지 — 호출하는 쪽이 채운다.
    source: str = "real"

    def as_dict(self) -> dict:
        doc = asdict(self)
        for key, value in doc.items():
            if isinstance(value, float):
                doc[key] = round(value, 3)
        doc["detail"] = self.detail
        return doc

    @property
    def detail(self) -> str:
        prefix = "모의 전력 — " if self.source != "real" else ""
        if self.status == "returned":
            return (f"{prefix}완료 뒤 {self.tail_s:.1f}초 만에 대기 전력으로 돌아옴 "
                    f"(사용 전 {_w(self.pre_baseline_w)} → 사용 후 {_w(self.post_baseline_w)}, "
                    f"꼬리 평균 {_w(self.tail_mean_w)}·최대 {_w(self.tail_max_w)})")
        if self.status == "timeout":
            return (f"{prefix}완료 뒤 관찰 시간 안에 대기 전력으로 돌아오지 않음 "
                    f"(사용 전 {_w(self.pre_baseline_w)}, 마지막 {_w(self.post_baseline_w)}, "
                    f"꼬리 평균 {_w(self.tail_mean_w)}·최대 {_w(self.tail_max_w)})")
        return {
            "no_finish": f"{prefix}완료(전력 하강 유지)를 관찰 시간 안에 확인하지 못해 꼬리를 재지 않음",
            "no_baseline": f"{prefix}사용 전 기준선이 없어 꼬리를 잴 수 없음",
            "stale": f"{prefix}전력 센서가 끊겨 꼬리 측정을 끝내지 못함",
            "stopped": f"{prefix}꼬리 측정을 중단함(새 실행·종료)",
        }.get(self.status, f"{prefix}{self.status}")


def _w(value: float | None) -> str:
    if value is None:
        return "—"
    return f"{value:.1f}W" if value < 100 else f"{value:,.0f}W"


class PowerTailTracker:
    """샘플을 시각 순서로 받아 완료 판정 → 꼬리 → 복귀를 추적한다. 한 번의 사용만 본다."""

    def __init__(self, pre_baseline_w: float | None, config: TailConfig | None = None) -> None:
        self._cfg = config or TailConfig()
        self._pre = pre_baseline_w if pre_baseline_w is None or math.isfinite(pre_baseline_w) else None
        self.phase = "running"  # running → tail → done
        self._status: str | None = None
        self._first_t: float | None = None
        self._last_t: float | None = None
        self._off_start: float | None = None
        self._finished_at: float | None = None
        self._tail: list[PowerSample] = []  # 완료 판정 뒤 모든 샘플
        self._run_start_idx: int | None = None  # 띠 안 연속 구간의 시작(_tail 안 위치)
        self._returned_at: float | None = None
        self._post: float | None = None

    @property
    def done(self) -> bool:
        return self.phase == "done"

    @property
    def band_w(self) -> float | None:
        if self._pre is None:
            return None
        return max(self._cfg.band_abs_w, self._cfg.band_ratio * self._pre)

    def feed(self, sample: PowerSample) -> str:
        t, w = sample.t_s, sample.watts
        if self.done or not (math.isfinite(t) and math.isfinite(w)) or w < 0:
            return self.phase
        if self._last_t is not None and t <= self._last_t:
            return self.phase
        self._last_t = t
        if self._first_t is None:
            self._first_t = t
        if self.phase == "running":
            self._feed_running(t, w)
        elif self.phase == "tail":
            self._feed_tail(sample)
        return self.phase

    def _feed_running(self, t: float, w: float) -> None:
        cfg = self._cfg
        if w > cfg.off_max_w:
            self._off_start = None
            if t - (self._first_t or t) >= cfg.max_run_s - _EPS_S:
                self._finish("no_finish")
            return
        if self._off_start is None:
            self._off_start = t
        if t - self._off_start >= cfg.off_confirm_s - _EPS_S:
            self._finished_at = t
            if self._pre is None:
                self._finish("no_baseline")
                return
            self.phase = "tail"

    def _feed_tail(self, sample: PowerSample) -> None:
        cfg = self._cfg
        assert self._finished_at is not None and self._pre is not None
        self._tail.append(sample)
        band = self.band_w or 0.0
        if abs(sample.watts - self._pre) <= band + 1e-9:
            if self._run_start_idx is None:
                self._run_start_idx = len(self._tail) - 1
            start = self._tail[self._run_start_idx]
            if sample.t_s - start.t_s >= cfg.settle_s - _EPS_S:
                run = self._tail[self._run_start_idx:]
                self._returned_at = start.t_s
                self._post = float(statistics.median(s.watts for s in run))
                self._finish("returned")
                return
        else:
            self._run_start_idx = None
        if sample.t_s - self._finished_at >= cfg.max_wait_s - _EPS_S:
            self._finish("timeout")

    def _finish(self, status: str) -> None:
        self.phase = "done"
        self._status = status

    def metrics(self, status: str | None = None, *, source: str = "real") -> TailMetrics:
        """지금까지의 측정값. 끝나지 않았으면 ``status``(기본: 단계에 맞는 미완료 사유)로 닫는다."""
        if status is None:
            status = self._status or ("timeout" if self.phase == "tail" else "no_finish")
        returned = status == "returned"
        if self._finished_at is None:
            window: list[PowerSample] = []
        elif returned and self._run_start_idx is not None:
            window = self._tail[: self._run_start_idx]
        else:
            window = list(self._tail)
        post = self._post
        if post is None and self._tail and self._last_t is not None:
            recent = [s.watts for s in self._tail if s.t_s >= self._last_t - self._cfg.settle_s - _EPS_S]
            post = float(statistics.median(recent)) if recent else None
        return TailMetrics(
            status=status,
            pre_baseline_w=self._pre,
            post_baseline_w=post,
            finished_at_s=self._finished_at,
            returned_at_s=self._returned_at if returned else None,
            tail_s=(self._returned_at - self._finished_at)
            if returned and self._returned_at is not None and self._finished_at is not None else None,
            tail_mean_w=(math.fsum(s.watts for s in window) / len(window)) if window else None,
            tail_max_w=max((s.watts for s in window), default=None),
            band_w=self.band_w,
            samples=len(self._tail),
            source=source,
        )


def measure_tail(samples: Iterable[PowerSample], pre_baseline_w: float | None,
                 config: TailConfig | None = None, *, source: str = "real") -> TailMetrics:
    """샘플 묶음 전체로 꼬리를 잰다(순수 함수 — 기록 파일 사후 분석·시험용)."""
    tracker = PowerTailTracker(pre_baseline_w, config)
    for sample in samples:
        if tracker.feed(sample) == "done":
            break
    return tracker.metrics(source=source)
