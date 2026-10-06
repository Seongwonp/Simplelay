"""가전 완료 융합 — CT 전력 하강(1순위) + 종료음(교차 확인)(2026-10-06, 사용자 결정 D2).

상태(``DONE_STATES``):
  done_confirmed   두 입력이 ``window_s`` 안에서 모두 끝을 알렸다 → "세탁이 끝났어요"라고 말해도 된다.
  done_power_only  전력 하강만 — "끝난 것 같아요, 확인해 주세요"(끝났다고 단정하지 않는다).
  done_beep_only   종료음만 — 위와 같다.

시각:
  ``at_s``   입력이 가리키는 **물리 시각**(전력: 대기로 내려간 첫 샘플, 종료음: 마지막 삐 시작). 창 비교에 쓴다.
  ``now_s``  융합이 그 입력을 받은 시각. 전력 끝은 대기에 ``settle_s`` 머문 뒤에야 오므로, 먼저 온 입력은
             ``wait_s``만큼 짝을 기다린 뒤 단일 입력으로 낸다(``poll``).
한 번 낸 뒤 ``cooldown_s`` 안에 든 입력은 같은 끝의 늦은 증거라 다시 알리지 않고 ``ignored``에만 남긴다.
쿨다운은 **가전마다** 다르다(2026-10-06 평가 B2): 전자레인지는 몇 분 간격으로 다시 돌릴 수 있어 짧게(설계 초기값
60 s), 세탁기는 길게(900 s). `DoneFusionConfig.for_appliance` — ``SIMPLELAY_DONE_<가전>_COOLDOWN_S`` →
``SIMPLELAY_DONE_COOLDOWN_S`` → 가전별 기본 → 900 s. 전부 측정 필요.

출처(``source``): 입력 중 하나라도 모의(mock)면 mock, 리허설 주입이면 injected — **실물(real)로 보이지 않게**.
이 모듈은 판단만 한다. 가전을 움직이지 않고 릴레이를 건드리지 않는다. 기준값은 전부 측정 필요.
"""

from __future__ import annotations

import math
import os
import re
from collections import deque
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field

DONE_STATES = ("done_confirmed", "done_power_only", "done_beep_only")
DONE_INPUTS = ("power", "beep")
DONE_SOURCES = ("real", "mock", "injected")
#: 세탁기 끝의 루틴 이벤트 이름(템플릿 '세탁 끝 알림'의 트리거와 같다).
DEFAULT_DONE_EVENT = "wash_complete"
#: 가전별 끝 이벤트 이름(2026-10-06, CT 두 채널). 전자레인지 끝이 '세탁 끝 알림' 루틴을 깨우지 않게 나눈다.
DONE_EVENTS = {"washer": DEFAULT_DONE_EVENT, "microwave": "heat_complete"}


def done_event_for(appliance_id: str) -> str:
    """가전의 끝 이벤트 이름. 표에 없으면 ``<가전 ID>_done``(소문자·밑줄로 다듬음)."""
    known = DONE_EVENTS.get(appliance_id)
    if known is not None:
        return known
    slug = re.sub(r"[^a-z0-9_]", "_", appliance_id.lower()).strip("_") or "appliance"
    if not slug[0].isalpha():
        slug = "a_" + slug
    return f"{slug[:58]}_done"

FUSION_ENV_NAMES = {
    "window_s": "SIMPLELAY_DONE_FUSION_WINDOW_S",
    "wait_s": "SIMPLELAY_DONE_FUSION_WAIT_S",
    "cooldown_s": "SIMPLELAY_DONE_COOLDOWN_S",
}


@dataclass(frozen=True)
class DoneFusionConfig:
    """융합 박자 — **전부 측정 필요**."""

    #: 두 입력의 물리 시각 차이 허용(초). 종료음과 전력 하강이 얼마나 떨어져 오는지 실측으로 정한다.
    window_s: float = 120.0
    #: 먼저 온 입력이 짝을 기다리는 시간(초). 전력 끝은 settle_s 늦게 오므로 wait_s ≥ settle_s + window_s 권장.
    wait_s: float = 300.0
    #: 한 번 알린 뒤 같은 가전의 입력을 무시하는 시간(초).
    cooldown_s: float = 900.0

    def __post_init__(self) -> None:
        for name in ("window_s", "wait_s", "cooldown_s"):
            value = getattr(self, name)
            if not (isinstance(value, (int, float)) and math.isfinite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None, **defaults: float) -> "DoneFusionConfig":
        src = os.environ if env is None else env
        values: dict[str, float] = dict(defaults)
        for field_name, env_name in FUSION_ENV_NAMES.items():
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
            raise RuntimeError(f"완료 융합 설정이 잘못됐습니다: {exc}") from exc

    @classmethod
    def for_appliance(cls, appliance_id: str, env: Mapping[str, str] | None = None,
                      **defaults: float) -> "DoneFusionConfig":
        """가전 하나의 융합 박자. 앞선 것이 이긴다: ``SIMPLELAY_DONE_<가전>_<항목>`` → 공통 env(`FUSION_ENV_NAMES`)
        → 호출자 기본(``defaults``) → 가전별 설계 초기값(`APPLIANCE_FUSION_DEFAULTS`) → 기본값. 전부 측정 필요."""
        src = os.environ if env is None else env
        values: dict[str, float] = {**APPLIANCE_FUSION_DEFAULTS.get(appliance_id, {}), **defaults}
        base = cls.from_env(src, **values)
        out = {name: getattr(base, name) for name in FUSION_ENV_NAMES}
        for field_name in FUSION_ENV_NAMES:
            name = _appliance_fusion_env(appliance_id, field_name)
            raw = (src.get(name) or "").strip()
            if not raw:
                continue
            try:
                out[field_name] = float(raw)
            except ValueError as exc:
                raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
        try:
            return cls(**out)
        except ValueError as exc:
            raise RuntimeError(f"'{appliance_id}' 완료 융합 설정이 잘못됐습니다: {exc}") from exc


#: 가전별 융합 설계 초기값(2026-10-06 평가 B2) — **전부 측정 필요**. 전자레인지는 두 번째 가열 끝을 버리지 않게
#: 쿨다운을 한 사이클(최소 가동 10 s + 대기 확인 10 s)보다 조금 길게만 둔다.
APPLIANCE_FUSION_DEFAULTS: dict[str, dict[str, float]] = {"microwave": {"cooldown_s": 60.0}}


def _appliance_fusion_env(appliance_id: str, field_name: str) -> str:
    """``SIMPLELAY_DONE_<가전>_<항목>``(예: SIMPLELAY_DONE_MICROWAVE_COOLDOWN_S)."""
    slug = re.sub(r"[^A-Z0-9]", "_", appliance_id.upper())
    suffix = FUSION_ENV_NAMES[field_name].removeprefix("SIMPLELAY_DONE_").removeprefix("FUSION_")
    return f"SIMPLELAY_DONE_{slug}_{suffix}"


@dataclass(frozen=True)
class _Input:
    kind: str
    at_s: float
    now_s: float
    evidence: dict
    source: str


@dataclass(frozen=True)
class ApplianceDoneEvent:
    appliance_id: str
    event: str
    state: str
    inputs: tuple[str, ...]
    expected: tuple[str, ...]
    at_s: float
    gap_s: float | None
    source: str
    window_s: float
    evidence: dict = field(default_factory=dict)

    @property
    def confidence(self) -> str:
        return "confirmed" if self.state == "done_confirmed" else "probable"

    def to_frame(self, t_monotonic_ns: int | None = None) -> dict:
        """RPi4 → RPi5 ``appliance_done`` 프레임(docs/protocol.md)."""
        doc = {
            "type": "appliance_done",
            "appliance_id": self.appliance_id,
            "event": self.event,
            "state": self.state,
            "confidence": self.confidence,
            "inputs": list(self.inputs),
            "expected_inputs": list(self.expected),
            "source": self.source,
            "at_s": round(self.at_s, 3),
            "gap_s": round(self.gap_s, 3) if self.gap_s is not None else None,
            "fusion_window_s": self.window_s,
            "evidence": dict(self.evidence),
        }
        if t_monotonic_ns is not None:
            doc["t_monotonic_ns"] = t_monotonic_ns
        return doc


def _merge_source(sources: Iterable[str]) -> str:
    sources = set(sources)
    if "injected" in sources:
        return "injected"
    if "mock" in sources or not sources <= {"real"}:
        return "mock"
    return "real"


class ApplianceDoneFusion:
    """가전 하나의 완료 입력을 모은다. ``note``·``poll``·``flush``가 알릴 사건을 돌려준다(없으면 None)."""

    def __init__(self, appliance_id: str, *, expected: Iterable[str] = DONE_INPUTS,
                 config: DoneFusionConfig | None = None, event: str = DEFAULT_DONE_EVENT) -> None:
        expected = tuple(dict.fromkeys(expected))
        if not expected or any(kind not in DONE_INPUTS for kind in expected):
            raise ValueError(f"expected는 {DONE_INPUTS}의 부분집합이어야 합니다: {expected!r}")
        self.appliance_id = appliance_id
        self.expected = expected
        self.event = event
        self._cfg = config or DoneFusionConfig()
        self._pending: _Input | None = None
        self._last_emit_at: float | None = None
        #: 쿨다운 안이라 알리지 않은 입력(증거 대장용 기록).
        self.ignored: deque[dict] = deque(maxlen=20)
        #: 낸 사건(최근 20개).
        self.history: deque[ApplianceDoneEvent] = deque(maxlen=20)

    @property
    def config(self) -> DoneFusionConfig:
        return self._cfg

    def note(self, kind: str, *, at_s: float, now_s: float, evidence: Mapping | None = None,
             source: str = "real") -> ApplianceDoneEvent | None:
        if kind not in DONE_INPUTS:
            raise ValueError(f"알 수 없는 완료 입력: {kind!r}")
        if source not in DONE_SOURCES:
            raise ValueError(f"알 수 없는 출처: {source!r}")
        item = _Input(kind, float(at_s), float(now_s), dict(evidence or {}), source)
        if kind not in self.expected:
            self.ignored.append({"kind": kind, "at_s": at_s, "reason": "not_expected"})
            return None
        if self._last_emit_at is not None and abs(item.at_s - self._last_emit_at) <= self._cfg.cooldown_s:
            self.ignored.append({"kind": kind, "at_s": at_s, "reason": "cooldown"})
            return None
        if len(self.expected) == 1:
            return self._emit([item])
        pending = self._pending
        if pending is None:
            self._pending = item
            return None
        if pending.kind == kind:
            self.ignored.append({"kind": kind, "at_s": at_s, "reason": "duplicate"})
            return None
        if abs(item.at_s - pending.at_s) <= self._cfg.window_s:
            self._pending = None
            return self._emit([pending, item])
        # 창 밖: 먼저 온 것은 단일 입력으로 내고, 이번 것은 (쿨다운 안이면) 버린다.
        self._pending = None
        out = self._emit([pending])
        self.note(kind, at_s=at_s, now_s=now_s, evidence=evidence, source=source)
        return out

    def poll(self, now_s: float) -> ApplianceDoneEvent | None:
        pending = self._pending
        if pending is None or now_s - pending.now_s < self._cfg.wait_s:
            return None
        self._pending = None
        return self._emit([pending])

    def flush(self, now_s: float) -> ApplianceDoneEvent | None:
        """기다리지 않고 지금 낸다(리허설 주입 전용 — 실물 경로는 ``poll``)."""
        pending = self._pending
        if pending is None:
            return None
        self._pending = None
        return self._emit([pending])

    def _emit(self, items: list[_Input]) -> ApplianceDoneEvent:
        kinds = tuple(item.kind for item in items)
        if set(kinds) >= {"power", "beep"}:
            state = "done_confirmed"
        else:
            state = "done_power_only" if kinds == ("power",) else "done_beep_only"
        at_s = min(item.at_s for item in items)
        gap = abs(items[0].at_s - items[1].at_s) if len(items) == 2 else None
        event = ApplianceDoneEvent(
            appliance_id=self.appliance_id, event=self.event, state=state, inputs=kinds,
            expected=self.expected, at_s=at_s, gap_s=gap,
            source=_merge_source(item.source for item in items), window_s=self._cfg.window_s,
            evidence={item.kind: item.evidence for item in items},
        )
        self._last_emit_at = at_s
        self.history.append(event)
        return event


def rehearsal_done_event(appliance_id: str, inputs: Iterable[str], *, now_s: float,
                         event: str | None = None) -> ApplianceDoneEvent:
    """리허설 주입(시연 v3 갭 S8) — 같은 융합 규칙에 주입 입력을 넣고 곧바로 낸다. 출처는 injected.
    ``event``가 없으면 가전의 끝 이벤트(`done_event_for`, 세탁기 = wash_complete·전자레인지 = heat_complete)."""
    event = event or done_event_for(appliance_id)
    kinds = list(dict.fromkeys(inputs))
    if not kinds:
        raise ValueError("주입할 입력이 하나 이상 있어야 합니다(power·beep)")
    fusion = ApplianceDoneFusion(appliance_id, config=DoneFusionConfig(), event=event)
    out = None
    for kind in kinds:
        out = fusion.note(kind, at_s=now_s, now_s=now_s,
                          evidence={"injected": True, "detail": "시연 주입 — 측정값 아님"},
                          source="injected") or out
    out = out or fusion.flush(now_s)
    assert out is not None
    return out
