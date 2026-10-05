"""가전 사이클 끝 판정 — 콘센트 모듈 CT 전력이 '운전'을 지나 '대기'로 돌아와 머물면 끝(2026-10-06, 결정 D2).

**판정 기준은 전부 측정 필요**(세탁기 실측 전 설계 초기값). 합성 곡선으로만 시험했다.

세탁기는 운전 중에도 전력이 크게 오르내린다(급수·담금·헹굼·탈수 사이 정지). 그래서 '전력이 한 번
내려감'을 끝으로 보지 않는다:

  운전 후보   전력 ≥ ``run_min_w`` 샘플이 처음 나온 시각(started_at_s)부터.
  운전 확정   후보가 살아 있는 채 ``min_run_s``가 지나고 다시 ≥ ``run_min_w`` 샘플이 오면(running_at_s).
              그 전에 대기가 ``settle_s`` 이어지면 후보를 버린다(문 잠금·표시창 같은 짧은 튐).
  대기 띠     전력 ≤ ``standby_max_w``. 그 사이 값(대기 상한 초과·운전 하한 미만)은 대기도 운전도 아니며
              대기 연속을 끊는다.
  끝          운전 확정 뒤 대기 띠 샘플이 ``settle_s`` 동안 끊김 없이 이어지면 끝. ``settle_s``가 곧
              '최소 하강 지속 시간'이다 — 그보다 짧은 하강(담금·정지)은 ``dips``로 셀 뿐 끝이 아니다.
              **담금 정지가 settle_s보다 길면 끝으로 잘못 본다** — 실측으로 정한다.
  끊김        샘플 간격이 ``max_gap_s``를 넘거나 `note_gap()`(센서 끊김)이면 대기 연속을 처음부터 다시 센다.
              보지 못한 시간을 대기로 세지 않는다.

시각은 샘플의 ``t_s``(호스트 단조 시각에 맞춘 값)만 쓴다. 시스템 시계를 읽지 않는다. 끝을 낸 뒤에는
처음 상태로 돌아가 다음 사이클을 본다. 이 모듈은 **릴레이를 건드리지 않는다**(세탁기는 CT 계측만).
"""

from __future__ import annotations

import math
import os
import re
import statistics
from collections.abc import Iterable, Mapping
from dataclasses import asdict, dataclass

from .power import PowerSample

_EPS_S = 1e-9

#: 환경 변수 이름(전부 선택). 값은 W·초. 전부 측정 필요.
CYCLE_ENV_NAMES = {
    "run_min_w": "SIMPLELAY_CYCLE_RUN_MIN_W",
    "min_run_s": "SIMPLELAY_CYCLE_MIN_RUN_S",
    "standby_max_w": "SIMPLELAY_CYCLE_STANDBY_MAX_W",
    "settle_s": "SIMPLELAY_CYCLE_SETTLE_S",
    "max_gap_s": "SIMPLELAY_CYCLE_MAX_GAP_S",
}


@dataclass(frozen=True)
class CycleEndConfig:
    """사이클 끝 판정 기준 — **전부 측정 필요**(세탁기 실측 전 설계 초기값)."""

    #: 이 이상이면 운전 중(W). 측정 필요 — 급수·담금 때 전력이 낮은 모델이 있다.
    run_min_w: float = 100.0
    #: 운전으로 인정할 최소 시간(초). 측정 필요.
    min_run_s: float = 300.0
    #: 이 이하면 대기(W). 측정 필요 — 표시창·대기 회로 전력.
    standby_max_w: float = 15.0
    #: 대기에 이만큼 머물러야 끝(초) = 최소 하강 지속. 측정 필요 — 담금 정지보다 길어야 한다.
    settle_s: float = 180.0
    #: 샘플 간격이 이보다 크면 끊김(초). 콘센트 모듈 보고 주기(10 Hz)의 여유. 측정 필요.
    max_gap_s: float = 5.0

    def __post_init__(self) -> None:
        for name in ("run_min_w", "min_run_s", "standby_max_w", "settle_s", "max_gap_s"):
            value = getattr(self, name)
            if not (isinstance(value, (int, float)) and math.isfinite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")
        if self.standby_max_w >= self.run_min_w:
            raise ValueError(
                f"standby_max_w({self.standby_max_w})는 run_min_w({self.run_min_w})보다 작아야 합니다")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "CycleEndConfig":
        src = os.environ if env is None else env
        values: dict[str, float] = {}
        for field_name, env_name in CYCLE_ENV_NAMES.items():
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
            raise RuntimeError(f"사이클 끝 판정 설정이 잘못됐습니다: {exc}") from exc

    @classmethod
    def for_appliance(cls, appliance_id: str, env: Mapping[str, str] | None = None) -> "CycleEndConfig":
        """가전 하나의 기준(CT 두 채널, 2026-10-06). 앞선 것이 이긴다:
        ``SIMPLELAY_CYCLE_<가전>_<항목>``(예: ``SIMPLELAY_CYCLE_MICROWAVE_SETTLE_S``) → ``SIMPLELAY_CYCLE_<항목>``
        → 가전별 설계 초기값(`APPLIANCE_CYCLE_DEFAULTS`) → 기본값(세탁기 기준). 전부 측정 필요."""
        src = os.environ if env is None else env
        prefix = _appliance_env_prefix(appliance_id)
        values: dict[str, float] = dict(APPLIANCE_CYCLE_DEFAULTS.get(appliance_id, {}))
        for field_name, env_name in CYCLE_ENV_NAMES.items():
            for name in (prefix + env_name.removeprefix("SIMPLELAY_CYCLE_"), env_name):
                raw = (src.get(name) or "").strip()
                if not raw:
                    continue
                try:
                    values[field_name] = float(raw)
                except ValueError as exc:
                    raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
                break
        try:
            return cls(**values)
        except ValueError as exc:
            raise RuntimeError(f"'{appliance_id}' 사이클 끝 판정 설정이 잘못됐습니다: {exc}") from exc


#: 가전별 설계 초기값(2026-10-06, CT 두 채널) — **전부 측정 필요**. 전자레인지는 가열이 몇 분이고 끝나면 표시창
#: 대기로 바로 돌아온다. 출력 조절(마그네트론 켜짐/꺼짐) 중에도 팬·조명·회전판 전력이 대기 상한보다 높다는 가정이다.
APPLIANCE_CYCLE_DEFAULTS: dict[str, dict[str, float]] = {
    "microwave": {"run_min_w": 100.0, "min_run_s": 10.0, "standby_max_w": 15.0, "settle_s": 10.0, "max_gap_s": 5.0},
}


def _appliance_env_prefix(appliance_id: str) -> str:
    return "SIMPLELAY_CYCLE_" + re.sub(r"[^A-Z0-9]", "_", appliance_id.upper()) + "_"


@dataclass(frozen=True)
class CycleEndEvent:
    """한 사이클의 끝 — 시각은 샘플 ``t_s`` 축, 전력은 측정값(보정 전 추정 W)."""

    started_at_s: float
    running_at_s: float
    standby_from_s: float
    done_at_s: float
    run_s: float
    peak_w: float
    mean_run_w: float
    standby_w: float
    dips: int
    samples: int

    def as_dict(self) -> dict:
        doc = {k: (round(v, 3) if isinstance(v, float) else v) for k, v in asdict(self).items()}
        doc["detail"] = self.detail
        return doc

    @property
    def detail(self) -> str:
        return (f"운전 {self.run_s / 60:.1f}분(최대 {self.peak_w:,.0f}W·평균 {self.mean_run_w:,.0f}W, "
                f"중간 하강 {self.dips}번) 뒤 대기 {self.standby_w:.1f}W로 돌아옴")


class CycleEndTracker:
    """샘플을 시각 순서로 받아 운전 → 끝을 찾는다. 끝을 내면 처음 상태로 돌아간다."""

    def __init__(self, config: CycleEndConfig | None = None) -> None:
        self._cfg = config or CycleEndConfig()
        self.phase = "idle"  # idle → candidate → running
        self._last_t: float | None = None
        self._reset_cycle()

    def _reset_cycle(self) -> None:
        self.phase = "idle"
        self._started: float | None = None
        self._running_at: float | None = None
        self._peak = 0.0
        self._sum = 0.0
        self._count = 0
        self._dips = 0
        self._standby_since: float | None = None
        self._standby: list[float] = []

    def note_gap(self) -> None:
        """센서 끊김 — 대기 연속을 처음부터 다시 센다(보지 못한 시간을 대기로 세지 않는다)."""
        self._drop_standby_run(count_dip=False)

    def snapshot(self) -> dict:
        return {"phase": self.phase, "started_at_s": self._started, "running_at_s": self._running_at,
                "standby_since_s": self._standby_since, "dips": self._dips}

    def feed(self, sample: PowerSample) -> CycleEndEvent | None:
        t, w = sample.t_s, sample.watts
        if not (math.isfinite(t) and math.isfinite(w)) or w < 0:
            return None
        if self._last_t is not None:
            if t <= self._last_t:
                return None
            if t - self._last_t > self._cfg.max_gap_s:
                self._drop_standby_run(count_dip=False)
        self._last_t = t
        cfg = self._cfg
        if self.phase == "idle":
            if w >= cfg.run_min_w:
                self.phase = "candidate"
                self._started = t
                self._add_run(w)
            return None
        if w <= cfg.standby_max_w:
            if self._standby_since is None:
                self._standby_since = t
                self._standby = []
            self._standby.append(w)
            if t - self._standby_since >= cfg.settle_s - _EPS_S:
                if self.phase == "running":
                    return self._finish(t)
                self._reset_cycle()  # 짧은 튐 — 운전이 아니었다
            return None
        # 대기 띠 밖: 진행 중이던 하강은 끝이 아니었다.
        self._drop_standby_run(count_dip=self.phase == "running")
        self._add_run(w)
        if (self.phase == "candidate" and w >= cfg.run_min_w and self._started is not None
                and t - self._started >= cfg.min_run_s - _EPS_S):
            self.phase = "running"
            self._running_at = t
        return None

    def _add_run(self, w: float) -> None:
        self._peak = max(self._peak, w)
        self._sum += w
        self._count += 1

    def _drop_standby_run(self, *, count_dip: bool) -> None:
        if self._standby_since is None:
            return
        if count_dip:
            self._dips += 1
        for w in self._standby:  # 끝이 아니었던 하강은 운전 구간의 일부다
            self._add_run(w)
        self._standby_since = None
        self._standby = []

    def _finish(self, t: float) -> CycleEndEvent:
        assert self._started is not None and self._running_at is not None
        assert self._standby_since is not None
        event = CycleEndEvent(
            started_at_s=self._started,
            running_at_s=self._running_at,
            standby_from_s=self._standby_since,
            done_at_s=t,
            run_s=self._standby_since - self._started,
            peak_w=self._peak,
            mean_run_w=self._sum / self._count if self._count else 0.0,
            standby_w=float(statistics.median(self._standby)),
            dips=self._dips,
            samples=self._count + len(self._standby),
        )
        self._reset_cycle()
        return event


def detect_cycle_ends(samples: Iterable[PowerSample],
                      config: CycleEndConfig | None = None) -> list[CycleEndEvent]:
    """샘플 묶음 전체에서 사이클 끝을 모두 찾는다(순수 함수 — 기록 파일 사후 분석·시험용)."""
    tracker = CycleEndTracker(config)
    return [event for sample in samples if (event := tracker.feed(sample)) is not None]
