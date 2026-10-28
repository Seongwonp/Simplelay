"""다른 장치의 단조 시각을 허브의 단조 시계로 보수적으로 변환한다.

``clock_probe``를 보내기 직전의 허브 시각 L0와 ``clock_ref``의 원격 시각 R을
기준으로 원격 시각 x를 ``L0 + (x - R)``로 옮긴다. 이 값은 왕복 지연만큼
이르게 잡혀 사건 나이를 실제보다 짧게 계산하지 않는다.

기준점이 없거나 만료됐거나 ``clock_id``가 다르면 None을 반환해 자동 실행을
보류한다. 유효 기간 안에서도 설정한 상대 드리프트만큼 사건 시각을 앞당기며,
불확실성이 상한을 넘으면 보류한다. 실제 드리프트와 왕복 시간은 측정 전이다.
"""

from __future__ import annotations

import math
import os
import re
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Mapping
from uuid import uuid4

from rpi.verifier.done_fusion import CLOCK_ID as LOCAL_CLOCK_ID

#: 답을 기다리는 탐침 수 상한(오래된 것부터 버린다).
MAX_PENDING_PROBES = 8
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")

REF_MAX_AGE_ENV = "SIMPLELAY_EVENT_CLOCK_REF_MAX_AGE_S"
DRIFT_PPM_ENV = "SIMPLELAY_EVENT_CLOCK_DRIFT_PPM"
MAX_UNCERTAINTY_ENV = "SIMPLELAY_EVENT_CLOCK_MAX_UNCERTAINTY_S"
REFRESH_ENV = "SIMPLELAY_EVENT_CLOCK_REFRESH_S"
#: 기준점 유효 기간(초) — 측정 필요.
DEFAULT_REF_MAX_AGE_S = 600.0
#: 두 보드 단조 시계의 상대 드리프트 상한(ppm) — 설계값, 측정 필요.
DEFAULT_DRIFT_PPM = 500.0
#: 드리프트 불확실성 한계(초) — 넘으면 보류.
DEFAULT_MAX_UNCERTAINTY_S = 1.0
#: 연결이 유지되는 동안 다시 탐침하는 간격(초) — 유효 기간보다 충분히 짧게.
DEFAULT_REFRESH_S = 60.0


def _env_float(name: str, default: float, *, allow_zero: bool = False) -> float:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not math.isfinite(value) or value < 0 or (value == 0 and not allow_zero):
        raise RuntimeError(f"{name}는 0보다 커야 합니다: {raw!r}")
    return value


def refresh_interval_s() -> float:
    """다시 탐침하는 간격(초, ``SIMPLELAY_EVENT_CLOCK_REFRESH_S``)."""
    return _env_float(REFRESH_ENV, DEFAULT_REFRESH_S)


def _finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


class EventClock:
    def __init__(self, monotonic: Callable[[], float] = time.monotonic, *,
                 ref_max_age_s: float | None = None, drift_ppm: float | None = None,
                 max_uncertainty_s: float | None = None) -> None:
        self._mono = monotonic
        self._ref_max_age_s = ref_max_age_s if ref_max_age_s is not None else _env_float(
            REF_MAX_AGE_ENV, DEFAULT_REF_MAX_AGE_S)
        self._drift = (drift_ppm if drift_ppm is not None else _env_float(
            DRIFT_PPM_ENV, DEFAULT_DRIFT_PPM, allow_zero=True)) * 1e-6
        self._max_uncertainty_s = max_uncertainty_s if max_uncertainty_s is not None else _env_float(
            MAX_UNCERTAINTY_ENV, DEFAULT_MAX_UNCERTAINTY_S, allow_zero=True)
        #: 이 시계(이 프로세스)를 만든 순간의 단조 시각 — 재시작 전에 끝난 사건을 가르는 경계(4차 평가 M-N2).
        self.started_s = monotonic()
        self._lock = threading.Lock()
        self._probes: OrderedDict[str, float] = OrderedDict()
        #: (RPi4 clock_id, RPi4 기준 시각 초, RPi5 기준 시각 초) — 지금 링크 세션의 기준점.
        self._link: tuple[str, float, float] | None = None

    def monotonic(self) -> float:
        return self._mono()

    # 기준점
    def new_probe(self) -> str:
        """보낼 탐침. 보내기 직전에 부른다(그 순간의 RPi5 단조 시각을 적는다)."""
        probe = uuid4().hex[:16]
        with self._lock:
            self._probes[probe] = self._mono()
            while len(self._probes) > MAX_PENDING_PROBES:
                self._probes.popitem(last=False)
        return probe

    def on_clock_ref(self, doc: Mapping) -> bool:
        """RPi4 ``clock_ref`` 답. 우리가 보낸 탐침의 답이면 기준점을 바꾸고 True."""
        probe, clock_id, t_ns = doc.get("probe"), doc.get("clock_id"), doc.get("t_monotonic_ns")
        if not (isinstance(clock_id, str) and _ID.fullmatch(clock_id)) or not isinstance(t_ns, int) \
                or isinstance(t_ns, bool) or t_ns < 0:
            return False
        with self._lock:
            sent = self._probes.pop(probe, None) if isinstance(probe, str) else None
            if sent is None:
                return False
            self._link = (clock_id, t_ns / 1e9, sent)
        return True

    def link_down(self) -> None:
        """링크가 끊겼다 — 기준점과 기다리던 탐침을 버린다(다음 세션에서 다시 잡는다)."""
        with self._lock:
            self._link = None
            self._probes.clear()

    def link_clock_id(self) -> str | None:
        with self._lock:
            return self._link[0] if self._link is not None else None

    # 옮기기
    def end_local_s(self, record: Mapping) -> float | None:
        """사건 끝 시각(``at_s``)을 이 허브 단조 시계로 옮긴 값. 근거가 없으면 None(보류)."""
        clock_id, at_s = record.get("clock_id"), record.get("at_s")
        if not isinstance(clock_id, str) or not _finite(at_s):
            return None
        if clock_id == LOCAL_CLOCK_ID:
            return float(at_s)
        with self._lock:
            link = self._link
        if link is None or link[0] != clock_id:
            return None
        _, ref_remote, ref_local = link
        # 4차 평가 M-N1: 낡은 기준점은 쓰지 않고, 드리프트 상한만큼 이르게 옮긴다(나이를 길게). 한계를 넘으면 보류.
        if self._mono() - ref_local > self._ref_max_age_s:
            return None
        span = float(at_s) - ref_remote
        uncertainty = abs(span) * self._drift
        if uncertainty > self._max_uncertainty_s:
            return None
        return ref_local + span - uncertainty


_default = EventClock()
_default_lock = threading.Lock()


def get_event_clock() -> EventClock:
    return _default


def reset_event_clock(monotonic: Callable[[], float] | None = None) -> EventClock:
    """시험용 — 새 기준점 저장소(가짜 단조 시계 가능)."""
    global _default
    with _default_lock:
        _default = EventClock(monotonic or time.monotonic)
        return _default


__all__ = ["LOCAL_CLOCK_ID", "EventClock", "get_event_clock", "refresh_interval_s", "reset_event_clock"]
