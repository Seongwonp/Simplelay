"""실행 대상 ↔ CT 채널·L3·정지 확인 결속(2026-10-07, 인계 노트북-3 §B, 평가 HIGH H3).

전에는 L3 판정기·잔여 전류 꼬리·정지 대기 전력 확인이 모두 전자레인지 채널(``OUTLET_PRESS_APPLIANCE``)로
고정이라, 세탁기·인터폰 실행이나 정지가 **전자레인지 전력 변화로 확인될 수 있었다.** 이제 execute의 대상
(``appliance_id``, 필수)마다 고른다.

대상의 CT 채널:
- ``SIMPLELAY_OUTLET_CHANNELS``가 있으면 거기 적힌 채널만. 없는 대상은 채널 없음.
- 대응이 비면(CT 하나 시절) 채널 0은 **누르는 가전(전자레인지) 것**이다. 다른 대상은 채널 없음.

대상별 정책:
- L3 ``off`` → 판정 없음(``operation_confirmed`` null). ``mock`` → 합성 전력(``mock`` 표시, 대상 무관).
- L3 ``real`` → 대상 채널의 전력으로 판정. 채널 없는 대상은 **실행 전 거절**(``target_unbound``).
  단 ``SIMPLELAY_L3_NONE_TARGETS``에 적은 대상(전력으로 동작을 볼 수 없는 가전, 예: 인터폰)은
  거절 대신 판정 없음으로 실행한다 — 사람이 정한 예외이고 결과에 null로 드러난다.
- 정지 대기 전력 확인 → 대기 계획 대상(= 실행 대상)의 채널. 채널이 없으면 '모름'(정지는 미확인으로만 끝).
- L2(수용 판정) → 운영 경로에 판정기 없음(모든 대상 같음). `ClosedLoopController`의 L2 분기는 타지 않는다.

**가짜 출력으로만 시험했다 — 실물 CT·세탁기·인터폰 미검증.**
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

log = logging.getLogger(__name__)

#: 전력 L3를 하지 않는 대상(쉼표 목록). L3 real에서 채널 없는 대상의 거절을 이 대상만 면한다.
L3_NONE_TARGETS_ENV = "SIMPLELAY_L3_NONE_TARGETS"
#: 대상 채널이 없어 실행 전 거절할 때의 사유.
TARGET_UNBOUND = "target_unbound"


class TargetRefused(Exception):
    """이 대상은 지금 구성으로 실행할 수 없다(누르기 전 거절)."""

    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


@dataclass(frozen=True)
class TargetBinding:
    """한 번의 실행에 쓸 대상별 부품."""

    appliance_id: str
    #: L3 판정기(없으면 None — 판정 없음).
    operation: Any
    #: "off" | "mock" | "real" | "none"(L3_NONE_TARGETS)
    l3: str
    #: 대상 CT 채널(없으면 None).
    ct_channel: int | None
    #: 결과 뒤 훅(잔여 전류 꼬리, 없으면 None). ``ActExecutor(after_result=…)``와 같은 모양.
    after_result: Any = None


def parse_l3_none_targets(raw: str | None) -> frozenset[str]:
    from rpi4.models.act_messages import _APPLIANCE_ID

    names = [part.strip() for part in (raw or "").split(",") if part.strip()]
    bad = [n for n in names if not _APPLIANCE_ID.fullmatch(n)]
    if bad:
        raise RuntimeError(f"{L3_NONE_TARGETS_ENV} 형식은 '<가전 ID>[,…]'입니다: {raw!r}")
    return frozenset(names)


class TargetBinder:
    """대상 가전 → `TargetBinding`. 판정기·채널 보기는 대상마다 한 번 만들어 둔다(실행은 한 번에 하나).

    ``outlet``: 콘센트 링크(`OutletLink`, 없으면 None). ``channels``: `OutletChannelMap`.
    ``make_operation(view, ch)``: 대상 채널 보기로 L3 real 판정기를 만든다.
    ``make_tail(view, operation)``: 잔여 전류 꼬리 훅(선택).
    ``mock_operation``: L3 mock일 때 모든 대상이 쓰는 합성 판정기.
    """

    def __init__(
        self,
        *,
        l3_mode: str,
        outlet: Any,
        channels: Any,
        press_appliance: str,
        make_operation: "Callable[[Any, int], Any] | None" = None,
        make_tail: "Callable[[Any, Any], Any] | None" = None,
        mock_operation: Any = None,
        l3_none_targets: "frozenset[str] | None" = None,
    ) -> None:
        if l3_mode not in ("off", "mock", "real"):
            raise ValueError(f"unknown L3 mode {l3_mode!r}")
        self.l3_mode = l3_mode
        self._outlet = outlet
        self._channels = channels
        self._press_appliance = press_appliance
        self._make_operation = make_operation
        self._make_tail = make_tail
        self._mock_operation = mock_operation
        self._none = l3_none_targets or frozenset()
        self._cache: dict[str, TargetBinding] = {}

    # 채널

    def channel_for(self, appliance_id: str | None) -> int | None:
        """대상의 CT 채널(없으면 None). 대응이 비면 누르는 가전만 채널 0."""
        if appliance_id is None:
            return None
        by_appliance: Mapping[str, int] = getattr(self._channels, "by_appliance", {}) or {}
        if by_appliance:
            return by_appliance.get(appliance_id)
        return 0 if appliance_id == self._press_appliance else None

    def view_for(self, appliance_id: str | None) -> Any:
        """대상 CT 채널의 전력 보기(콘센트가 없거나 채널이 없으면 None)."""
        if self._outlet is None:
            return None
        ch = self.channel_for(appliance_id)
        if ch is None:
            return None
        channel = getattr(self._outlet, "channel", None)
        return channel(ch) if callable(channel) else self._outlet

    # 실행 결속

    def bind(self, appliance_id: str) -> TargetBinding:
        cached = self._cache.get(appliance_id)
        if cached is not None:
            return cached
        binding = self._build(appliance_id)
        self._cache[appliance_id] = binding
        log.info("target %s bound: L3=%s ct_channel=%s", appliance_id, binding.l3, binding.ct_channel)
        return binding

    def _build(self, appliance_id: str) -> TargetBinding:
        ch = self.channel_for(appliance_id) if self._outlet is not None else None
        if self.l3_mode == "off":
            return TargetBinding(appliance_id, None, "off", ch)
        if self.l3_mode == "mock":
            return TargetBinding(appliance_id, self._mock_operation, "mock", ch)
        if appliance_id in self._none:
            return TargetBinding(appliance_id, None, "none", ch)
        view = self.view_for(appliance_id)
        if view is None or ch is None or self._make_operation is None:
            raise TargetRefused(
                TARGET_UNBOUND,
                f"'{appliance_id}'의 CT 채널이 SIMPLELAY_OUTLET_CHANNELS에 없어 동작 확인(L3 real)을 할 수 "
                f"없어 누르지 않았어요(지금 대응: {self._describe()}). 채널을 적거나, 전력으로 볼 수 없는 "
                f"가전이면 {L3_NONE_TARGETS_ENV}에 적어 주세요")
        operation = self._make_operation(view, ch)
        tail = self._make_tail(view, operation) if self._make_tail is not None else None
        return TargetBinding(appliance_id, operation, "real", ch, tail)

    def _describe(self) -> str:
        describe = getattr(self._channels, "describe", None)
        if callable(describe) and getattr(self._channels, "by_appliance", None):
            return describe()
        return f"비어 있음 — 채널 0은 {self._press_appliance}만"

    def probe_for(self, appliance_id: str | None, make_probe: "Callable[[Any], Any]") -> Any:
        """정지 대기 전력 확인 — 대상 채널 보기로 ``make_probe``, 채널이 없으면 '모름'(NoRunProbe)."""
        from .stop_hold import NoRunProbe

        view = self.view_for(appliance_id)
        if view is None:
            log.warning("stop hold for %s: no CT channel — stop judgement stays 'unconfirmed'", appliance_id)
            return NoRunProbe()
        return make_probe(view)


def l3_mode_from_env(env: "Mapping[str, str] | None" = None) -> str:
    src = os.environ if env is None else env
    return (src.get("SIMPLELAY_L3_MODE", "off") or "off").strip().lower() or "off"
