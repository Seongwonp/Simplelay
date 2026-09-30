"""정지 대기·보관 — 허브(RPi5) 쪽 절반(2026-09-30). **모의로만 검증, 실물 미검증.**

- ``validate_stop_park``: 가전 등록의 ``stop_button``·``stop_presses``·``park_xy`` 검증.
  갠트리 소프트 리밋(``SIMPLELAY_MOTION_X_MIN_MM`` 등)이 설정돼 있으면 그 안인지 보고,
  없으면 받아 두되 ``unverified``("미확인")로 표시한다. 행정 한계는 RPi4 모션 어댑터가
  움직이기 전에 한 번 더 거절한다.
- ``hold_plan_for``: 실행 직전에 RPi4로 보낼 ``hold`` 계획(정지 버튼 mm·횟수·보관 mm).
  정지 버튼 mm나 보관 위치가 없으면 None — 대기 없이 종전처럼 실행만 한다.
- ``hold_status_fields``·``hold_view``: RPi4가 보낸 ``progress``(phase ``hold``)를 /status·
  트윈에 옮긴다. 판정(정지됨/미확인)은 RPi4가 한다 — 여기서 지어내지 않는다.

임계값(보관 위치와 버튼 사이 거리)은 **설계 초기값**이다(추측/측정 필요).
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

#: 정지 버튼 누름 횟수 범위. RPi4 메시지 검증(act_messages.STOP_PRESSES_RANGE)과 같다.
STOP_PRESSES_RANGE = (1, 3)
#: 보관 위치와 보정된 버튼 중심 사이 최소 거리(mm). 설계 초기값 — 캐리지가 버튼을 가리지 않게.
PARK_CLEARANCE_MM = 15.0


@dataclass(frozen=True)
class StopParkCheck:
    """``ok``: 소프트 리밋 안 확인. ``unverified``: 리밋 미설정이라 범위 미확인(저장은 함).
    ``incomplete``: 정지 버튼 mm 또는 보관 위치가 없어 대기를 하지 않는다. ``none``: 설정 없음."""

    status: str
    notes: tuple[str, ...] = field(default_factory=tuple)

    def as_dict(self) -> dict:
        return {"status": self.status, "notes": list(self.notes)}


def _soft_limits(env: Mapping[str, str] | None = None):
    """설정된 소프트 리밋(CoreXYConfig) 또는 None(하나라도 비었거나 설정 오류)."""
    from rpi.controller.kinematics import CoreXYConfig  # noqa: PLC0415

    try:
        config = CoreXYConfig.from_env(env)
    except ValueError:
        return None
    if config.missing(("x_min_mm", "x_max_mm", "y_min_mm", "y_max_mm")):
        return None
    return config


def _finite_pair(value: object) -> tuple[float, float] | None:
    try:
        x, y = value  # type: ignore[misc]
        x, y = float(x), float(y)
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(x) and math.isfinite(y)):
        return None
    return x, y


def validate_stop_park(appliance: Any, env: Mapping[str, str] | None = None) -> StopParkCheck:
    """정지·보관 필드를 검증한다. 틀리면 ``ValueError``(사용자에게 보일 한국어 문장)."""
    from rpi.services.appliance_registry import MM_RANGE, ButtonKind  # noqa: PLC0415

    presses = appliance.stop_presses
    if isinstance(presses, bool) or not isinstance(presses, int) or not (
        STOP_PRESSES_RANGE[0] <= presses <= STOP_PRESSES_RANGE[1]
    ):
        raise ValueError(f"정지 버튼 누름 횟수는 {STOP_PRESSES_RANGE[0]}~{STOP_PRESSES_RANGE[1]}번이어야 해요")
    stop = None
    if appliance.stop_button is not None:
        stop = next((b for b in appliance.buttons if b.id == appliance.stop_button), None)
        if stop is None:
            raise ValueError(f"정지 버튼 '{appliance.stop_button}'이 이 가전의 버튼에 없어요")
        if stop.kind is not ButtonKind.BUTTON:
            raise ValueError(f"'{stop.label}'은 다이얼이라 정지 버튼으로 쓸 수 없어요")
    park = None
    if appliance.park_xy is not None:
        park = _finite_pair(appliance.park_xy)
        lo, hi = MM_RANGE
        if park is None or not all(lo <= v <= hi for v in park):
            raise ValueError(f"보관 위치는 {lo:g}~{hi:g}mm 안의 좌표여야 해요")
        for b in appliance.buttons:
            if b.calibrated and math.dist(park, (b.x_mm, b.y_mm)) < PARK_CLEARANCE_MM:
                raise ValueError(
                    f"보관 위치가 버튼 '{b.label}'과 너무 가까워요({PARK_CLEARANCE_MM:g}mm 이상 떨어뜨려 주세요)"
                )
        if stop is not None and stop.calibrated and park == (stop.x_mm, stop.y_mm):
            raise ValueError("보관 위치와 정지 버튼 위치가 같아요")
    if stop is None and park is None:
        return StopParkCheck("none")
    notes: list[str] = []
    if stop is None:
        notes.append("정지 버튼이 없어 정지 대기를 하지 않아요")
    elif not stop.calibrated:
        notes.append("정지 버튼 좌표(mm)가 없어 정지 대기를 하지 않아요 — 사진 매핑 먼저")
    if park is None:
        notes.append("보관 위치가 없어 정지 대기를 하지 않아요")
    limits = _soft_limits(env)
    points = []
    if park is not None:
        points.append(("보관 위치", park))
    if stop is not None and stop.calibrated:
        points.append((f"정지 버튼 '{stop.label}'", (stop.x_mm, stop.y_mm)))
    if limits is None:
        notes.append("갠트리 이동 범위(소프트 리밋)가 설정되지 않아 범위는 미확인이에요")
    else:
        for label, (x, y) in points:
            if not (limits.x_min_mm <= x <= limits.x_max_mm and limits.y_min_mm <= y <= limits.y_max_mm):
                raise ValueError(
                    f"{label}({x:g}, {y:g}mm)가 갠트리 이동 범위 "
                    f"X {limits.x_min_mm:g}~{limits.x_max_mm:g}, Y {limits.y_min_mm:g}~{limits.y_max_mm:g}mm 밖이에요"
                )
    if stop is None or not stop.calibrated or park is None:
        return StopParkCheck("incomplete", tuple(notes))
    return StopParkCheck("unverified" if limits is None else "ok", tuple(notes))


def hold_plan_for(registry: Any, appliance_id: str | None) -> dict | None:
    """RPi4 ``execute``에 실을 ``hold`` 계획. 정지 버튼 mm·보관 위치가 모두 있을 때만."""
    if registry is None or appliance_id is None:
        return None
    appliance = registry.get(appliance_id)
    if appliance is None or appliance.stop_button is None or appliance.park_xy is None:
        return None
    stop = next((b for b in appliance.buttons if b.id == appliance.stop_button), None)
    if stop is None or not stop.calibrated:
        return None
    plan: dict = {
        "appliance_id": appliance_id,
        "stop_button": stop.label,
        "stop_x_mm": float(stop.x_mm),
        "stop_y_mm": float(stop.y_mm),
        "stop_presses": int(appliance.stop_presses),
        "park_x_mm": float(appliance.park_xy[0]),
        "park_y_mm": float(appliance.park_xy[1]),
    }
    if stop.press_ms is not None:
        plan["press_ms"] = int(stop.press_ms)
    return plan


_HOLD_KEYS = ("hold_state", "stop_outcome", "detail", "stop_button", "stop_presses", "presses_done",
              "stop", "park", "target", "park_reason", "appliance_id", "probe_source", "execution_mode")


def hold_view(doc: Mapping[str, Any] | None) -> dict | None:
    """RPi4 hold 프레임 → 화면용 요약(없으면 None)."""
    if not doc:
        return None
    view = {k: doc.get(k) for k in _HOLD_KEYS}
    view["sequence_id"] = doc.get("sequence_id")
    return view


def hold_status_fields(doc: Mapping[str, Any] | None) -> dict:
    """/status에 붙는 평평한 필드. 대기 보고가 없으면 전부 None."""
    view = hold_view(doc) or {}
    return {
        "hold_state": view.get("hold_state"),
        "hold_stop_outcome": view.get("stop_outcome"),
        "hold_detail": view.get("detail"),
        "hold_appliance_id": view.get("appliance_id"),
        "hold_stop_button": view.get("stop_button"),
        "hold_execution_mode": view.get("execution_mode"),
    }


def latest_hold_frame(frames: list[dict]) -> dict | None:
    """프레임 탭에서 마지막 hold 보고(RPi4 → RPi5 progress phase ``hold``)."""
    for frame in reversed(frames):
        msg = frame.get("message") or {}
        if (frame.get("direction") == "act_to_hub" and msg.get("type") == "progress"
                and msg.get("phase") == "hold"):
            return msg
    return None
