"""사건 신선도 근거(3차 평가 M1, 2026-10-14) — 다른 장치의 단조 시각을 이 허브(RPi5) 단조 시계로 옮기는 기준점.

**서로 다른 장치의 monotonic 값은 그대로 비교하지 않는다.** RPi4가 보낸 ``appliance_done``의 끝 시각(``at_s``)과
프레임 시각(``t_monotonic_ns``)은 RPi4 프로세스의 단조 시계(``clock_id``로 식별)다. 예전 판정(``t_monotonic_ns - at_s``)은
프레임을 **내기까지**만 셌고, 보낸 뒤 링크·버퍼에서 늦어진 시간은 0으로 봤다.

기준점 — 링크 세션마다 한 번(``act_info.clock_protocol`` ≥ 1인 RPi4만):

1. RPi5가 ``clock_probe {probe}``를 보낸다. 보내기 **직전** RPi5 단조 시각 ``L0``을 적는다.
2. RPi4가 ``clock_ref {probe, clock_id, t_monotonic_ns: R}``로 답한다. RPi4가 R을 읽은 실제 순간은 RPi5 시계로
   ``L0`` 이후다(``L0 ≤ t* ≤ 받은 시각``).
3. 그 RPi4 프로세스의 단조 시각 ``x``는 RPi5 시각 ``L0 + (x - R)``로 옮긴다. 실제(``t* + (x - R)``)보다 **이르거나 같으므로**
   사건 나이는 실제보다 길게(최대 왕복 시간만큼) 잡힌다 — 보수적(더 많이 보류).

근거가 없으면 None — 자동 실행은 **보류**가 기본이다: 기준점이 없음(옛 RPi4·아직 답 없음), 프레임의 ``clock_id``가
지금 링크 세션의 것과 다름(RPi4 재시작·세션 바뀜), 링크가 끊겨 기준점을 버림. 같은 프로세스(RPi5 모의 주입)에서 만든
프레임은 ``clock_id``가 이 프로세스의 것이라 그대로 같은 시계다.

**기준점 유효 기간·상대 드리프트(4차 평가 M-N1).** 위 '보수적' 증명은 두 시계 속도가 같다는 전제다. 실제로는 상대 속도 차
δ가 있어, 옮긴 값의 오차가 기준점과 사건 사이 간격 ``|x − R|``에 비례해 쌓인다(RPi4가 빠르면 사건을 늦게 옮겨 나이를
짧게 잡는다). 그래서:

- 기준점은 잡은 뒤 ``SIMPLELAY_EVENT_CLOCK_REF_MAX_AGE_S``(기본 600초)까지만 쓴다. 넘기면 근거 없음(보류). RPi5는 연결이
  유지되는 동안 ``SIMPLELAY_EVENT_CLOCK_REFRESH_S``(기본 60초)마다 다시 탐침한다(``rpi/services/act_client.py``).
- 그 안에서는 상대 드리프트 상한 ``SIMPLELAY_EVENT_CLOCK_DRIFT_PPM``(기본 500ppm — 리눅스 NTP 최대 보정 속도 수준의
  설계값, **측정 필요**) × ``|x − R|``만큼 끝 시각을 더 이르게(나이를 길게) 옮긴다. 상대 드리프트가 이 상한 안이면 나이를
  실제보다 짧게 잡지 않는다.
- 그 불확실성이 ``SIMPLELAY_EVENT_CLOCK_MAX_UNCERTAINTY_S``(기본 1초)를 넘으면 보류한다.

두 보드 사이 실제 드리프트·왕복 시간은 아직 재지 않았다.
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

    # ── 기준점 ────────────────────────────────────────────────────────────
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

    # ── 옮기기 ────────────────────────────────────────────────────────────
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
