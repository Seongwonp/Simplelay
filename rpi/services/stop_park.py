"""정지 대기·보관 — 허브(RPi5) 쪽 절반(2026-09-30). **모의로만 검증, 실물 미검증.**

- ``validate_stop_park``: 가전 등록의 ``stop_button``·``stop_presses``·``park_xy`` 검증.
  갠트리 소프트 리밋(``SIMPLELAY_MOTION_X_MIN_MM`` 등)이 설정돼 있으면 그 안인지 보고,
  없으면 받아 두되 ``unverified``("미확인")로 표시한다. 행정 한계는 RPi4 모션 어댑터가
  움직이기 전에 한 번 더 거절한다.
- ``hold_plan_for``: 실행 직전에 RPi4로 보낼 ``hold`` 계획(정지 버튼 mm·횟수·보관 mm).
  정지 버튼 mm나 보관 위치가 없으면 None — 대기 없이 종전처럼 실행만 한다.
- ``simulated_hold_plan``(2026-10-06, 시연 v3 갭 M3): **시뮬레이터 전용.** 정지 버튼만 등록돼
  있어도 빠진 mm를 모의 위치로 채워 대기·보관을 흉내 낸다. UART·실물 경로는 쓰지 않는다.
- ``hold_status_fields``·``hold_view``: RPi4가 보낸 ``progress``(phase ``hold``)를 /status·
  트윈에 옮긴다. 판정(정지됨/미확인)은 RPi4가 한다 — 여기서 지어내지 않는다.

임계값(보관 위치와 버튼 사이 거리)은 **설계 초기값**이다(추측/측정 필요).
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from rpi.josa import quoted_josa, with_josa

#: 정지 버튼 누름 횟수 범위. RPi4 메시지 검증(act_messages.STOP_PRESSES_RANGE)과 같다.
STOP_PRESSES_RANGE = (1, 3)
#: 보관 위치와 보정된 버튼 중심 사이 최소 거리(mm). 설계 초기값 — 캐리지가 버튼을 가리지 않게.
PARK_CLEARANCE_MM = 15.0
#: 보관 위치의 화면 이름 — 폰 가전 추가 화면의 말과 같다(panel_mapping·확인 주행도 이 이름을 쓴다).
PARK_LABEL = "기다리는 자리"


@dataclass(frozen=True)
class StopParkCheck:
    """``ok``: 소프트 리밋 안 확인. ``unverified``: 리밋 미설정이라 범위 미확인(저장은 함).
    ``incomplete``: 정지 버튼 mm 또는 보관 위치가 없어 대기를 하지 않는다. ``none``: 설정 없음."""

    status: str
    notes: tuple[str, ...] = field(default_factory=tuple)

    def as_dict(self) -> dict:
        return {"status": self.status, "notes": list(self.notes)}


#: 누름 장치가 움직일 수 있는 범위를 설치 때 정하지 않았다 — 저장은 하되 닿는지는 아직 모른다(폰에 보인다).
UNCHECKED_RANGE_NOTE = ("누름 장치가 움직일 수 있는 범위가 아직 정해지지 않아, 고른 자리에 닿는지는 확인하지 못했어요 "
                        "— 자리 확인을 해서 누름 장치가 고른 자리에 닿는지 봐 주세요")


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
    """정지·보관 필드를 검증한다. 틀리면 ``ValueError``(사용자에게 보일 한국어 문장).

    거절 문장과 ``notes``는 폰에 그대로 보인다 — 갠트리·소프트 리밋·mm 좌표 같은 속말과 '이(가)' 같은 겹친 조사를
    쓰지 않고, 다음에 할 일을 함께 적는다(첫 사용 점검 2026-10-19)."""
    from rpi.services.appliance_registry import MM_RANGE, ButtonKind  # noqa: PLC0415

    presses = appliance.stop_presses
    if isinstance(presses, bool) or not isinstance(presses, int) or not (
        STOP_PRESSES_RANGE[0] <= presses <= STOP_PRESSES_RANGE[1]
    ):
        raise ValueError(f"정지 버튼 누름 횟수는 {STOP_PRESSES_RANGE[0]}~{STOP_PRESSES_RANGE[1]}번 중에서 골라 주세요")
    stop = None
    if appliance.stop_button is not None:
        stop = next((b for b in appliance.buttons if b.id == appliance.stop_button), None)
        if stop is None:
            raise ValueError(f"정지 버튼으로 고른 {quoted_josa(appliance.stop_button, '이', '가')} 이 가전의 버튼에 없어요 "
                             "— 정지 버튼을 다시 골라 주세요")
        if stop.kind is not ButtonKind.BUTTON:
            raise ValueError(f"{quoted_josa(stop.label, '은', '는')} 돌리는 다이얼이라 정지 버튼으로 쓸 수 없어요 "
                             "— 누르는 버튼을 골라 주세요")
    park = None
    if appliance.park_xy is not None:
        park = _finite_pair(appliance.park_xy)
        lo, hi = MM_RANGE
        if park is None or not all(lo <= v <= hi for v in park):
            raise ValueError(f"{with_josa(PARK_LABEL, '이', '가')} 누름 장치가 갈 수 없는 곳이에요 "
                             "— 버튼판 네 귀퉁이 안쪽에서 다시 골라 주세요")
        for b in appliance.buttons:
            if b.calibrated and math.dist(park, (b.x_mm, b.y_mm)) < PARK_CLEARANCE_MM:
                raise ValueError(
                    f"{with_josa(PARK_LABEL, '이', '가')} 버튼 {quoted_josa(b.label, '과', '와')} 너무 가까워요 "
                    f"— 버튼에서 {PARK_CLEARANCE_MM / 10:g}cm 넘게 떨어진 곳을 골라 주세요"
                )
        if stop is not None and stop.calibrated and park == (stop.x_mm, stop.y_mm):
            raise ValueError(f"{with_josa(PARK_LABEL, '과', '와')} 정지 버튼이 같은 곳이에요 "
                             "— 버튼을 가리지 않는 다른 곳을 골라 주세요")
    if stop is None and park is None:
        return StopParkCheck("none")
    notes: list[str] = []
    if stop is None:
        notes.append("정지 버튼을 고르지 않아, 가전이 움직이는 동안 정지 버튼 위에서 기다리지 않아요")
    elif not stop.calibrated:
        notes.append("정지 버튼 자리를 아직 정하지 않아 정지 버튼 위에서 기다리지 않아요 "
                     "— 사진에서 정지 버튼을 골라 주세요")
    if park is None:
        notes.append(f"{with_josa(PARK_LABEL, '을', '를')} 고르지 않아 정지 버튼 위에서 기다리지 않아요 "
                     "— 사진에서 기다리는 자리를 골라 주세요")
    limits = _soft_limits(env)
    points = []
    if park is not None:
        points.append((PARK_LABEL, park))
    if stop is not None and stop.calibrated:
        points.append((f"정지 버튼 '{stop.label}'", (stop.x_mm, stop.y_mm)))
    if limits is None:
        notes.append(UNCHECKED_RANGE_NOTE)
    else:
        for label, (x, y) in points:
            if not (limits.x_min_mm <= x <= limits.x_max_mm and limits.y_min_mm <= y <= limits.y_max_mm):
                raise ValueError(
                    f"{with_josa(label, '이', '가')} 누름 장치의 이동 범위 밖이에요 "
                    "— 버튼판 안쪽에서 누름 장치가 닿는 곳으로 다시 골라 주세요"
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


#: 시뮬레이터 모의 위치(mm, 2026-10-06 시연 v3 갭 M3). **실물 좌표가 아니다** — 정지 버튼 mm나
#: 보관 위치가 없는 가전을 전부 모의 등급에서 리허설할 때 트윈에 그릴 자리일 뿐이다.
MOCK_STOP_XY = (150.0, 100.0)
MOCK_PARK_XY = (20.0, 180.0)

#: 시뮬레이터가 대기 계획을 만들지 못한 이유 → 화면 문장.
HOLD_UNAVAILABLE_DETAILS = {
    "no_appliance": "가전이 정해지지 않아 정지 버튼 위 대기를 하지 않아요",
    "no_stop_button": "정지 버튼이 등록되지 않아 정지 버튼 위 대기를 하지 않아요 — 가전 편집에서 정지 버튼을 정해 주세요",
    "no_park_position": "버튼과 충분히 떨어진 모의 보관 위치를 찾지 못해 정지 버튼 위 대기를 하지 않아요",
}

#: 모의 보관 위치를 찾을 때 훑는 격자 간격(mm).
_PARK_SEARCH_STEP_MM = 5.0


def _mock_park_position(preferred: tuple[float, float], stop_xy: tuple[float, float],
                        buttons: Any) -> tuple[float, float] | None:
    """범위(MM_RANGE, 소프트 리밋이 있으면 그 안) 안이고 정지 위치·보정된 모든 버튼에서
    ``PARK_CLEARANCE_MM`` 이상 떨어진 보관 위치. ``preferred``가 맞으면 그대로, 아니면 격자에서
    가장 가까운 자리. 없으면 None(2026-10-06 교차 리뷰 — 예전엔 x+15mm로만 비켜 범위·여유를 어겼다)."""
    from rpi.services import appliance_registry  # noqa: PLC0415

    lo, hi = appliance_registry.MM_RANGE
    x_lo, x_hi, y_lo, y_hi = lo, hi, lo, hi
    limits = _soft_limits()
    if limits is not None:
        x_lo, x_hi = max(x_lo, limits.x_min_mm), min(x_hi, limits.x_max_mm)
        y_lo, y_hi = max(y_lo, limits.y_min_mm), min(y_hi, limits.y_max_mm)
    obstacles = [stop_xy] + [(float(b.x_mm), float(b.y_mm)) for b in buttons if b.calibrated]

    def ok(p: tuple[float, float]) -> bool:
        return (x_lo <= p[0] <= x_hi and y_lo <= p[1] <= y_hi
                and all(math.dist(p, o) >= PARK_CLEARANCE_MM for o in obstacles))

    if ok(preferred):
        return preferred
    if x_lo > x_hi or y_lo > y_hi:
        return None

    def axis(a: float, b: float) -> list[float]:
        n = int((b - a) // _PARK_SEARCH_STEP_MM)
        values = [a + i * _PARK_SEARCH_STEP_MM for i in range(n + 1)]
        return values + ([b] if values[-1] < b else [])

    best: tuple[float, tuple[float, float]] | None = None
    for x in axis(x_lo, x_hi):
        for y in axis(y_lo, y_hi):
            if ok((x, y)):
                d = math.dist((x, y), preferred)
                if best is None or d < best[0]:
                    best = (d, (x, y))
    return None if best is None else best[1]


def simulated_hold_plan(registry: Any, appliance_id: str | None) -> tuple[dict | None, str | None]:
    """시뮬레이터 전용 대기 계획(시연 v3 갭 M3). ``(계획, 없는 이유)``를 돌려준다.

    - 정지 버튼 mm·보관 위치가 다 있으면 ``hold_plan_for``와 같은 계획(``position_source``
      ``calibrated``).
    - 정지 버튼만 등록돼 있으면 빠진 좌표를 모의 위치(``MOCK_STOP_XY``·``MOCK_PARK_XY``)로 채운다
      (``position_source`` ``mock``). 판정을 지어내지 않도록 시뮬레이터가 모의 가전을 정지 버튼에
      반응하지 않게 둔다(``SimulatorController``).
    - 정지 버튼이 없으면 ``(None, "no_stop_button")`` — 대기하지 않는다.
    - 모의로 채울 때 보관 위치는 범위 안·정지 위치와 보정된 버튼 모두에서 ``PARK_CLEARANCE_MM`` 밖으로
      고른다. 그런 자리가 없으면 ``(None, "no_park_position")``.

    UART·실물 경로는 이 함수를 쓰지 않는다(``hold_plan_for`` 그대로).
    """
    if registry is None or appliance_id is None:
        return None, "no_appliance"
    appliance = registry.get(appliance_id)
    if appliance is None:
        return None, "no_appliance"
    stop = None
    if appliance.stop_button is not None:
        stop = next((b for b in appliance.buttons if b.id == appliance.stop_button), None)
    if stop is None:
        return None, "no_stop_button"
    calibrated = hold_plan_for(registry, appliance_id)
    if calibrated is not None:
        return {**calibrated, "position_source": "calibrated"}, None
    stop_xy = (float(stop.x_mm), float(stop.y_mm)) if stop.calibrated else MOCK_STOP_XY
    park_xy = (
        (float(appliance.park_xy[0]), float(appliance.park_xy[1]))
        if appliance.park_xy is not None else MOCK_PARK_XY
    )
    # 대기와 보관이 구분돼야 하고(RPi4 메시지 검증) 보관 위치는 범위 안·모든 버튼에서 여유 거리 밖이어야 한다.
    park_xy = _mock_park_position(park_xy, stop_xy, appliance.buttons)
    if park_xy is None:
        return None, "no_park_position"
    plan: dict = {
        "appliance_id": appliance_id,
        "stop_button": stop.label,
        "stop_x_mm": stop_xy[0],
        "stop_y_mm": stop_xy[1],
        "stop_presses": int(appliance.stop_presses),
        "park_x_mm": park_xy[0],
        "park_y_mm": park_xy[1],
        "position_source": "mock",
    }
    if stop.press_ms is not None:
        plan["press_ms"] = int(stop.press_ms)
    return plan, None


_HOLD_KEYS = ("hold_state", "stop_outcome", "detail", "stop_button", "stop_presses", "presses_done",
              "stop", "park", "target", "park_reason", "appliance_id", "probe_source", "execution_mode",
              "position_source", "unavailable_reason")


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
        # 시뮬레이터만 채운다(M3) — 위치 출처(mock | calibrated)·가전 켜짐 근거·대기 안 한 이유.
        "hold_position_source": view.get("position_source"),
        "hold_probe_source": view.get("probe_source"),
        "hold_unavailable_reason": view.get("unavailable_reason"),
    }


def latest_hold_frame(frames: list[dict]) -> dict | None:
    """프레임 탭에서 마지막 hold 보고(RPi4 → RPi5 progress phase ``hold``)."""
    for frame in reversed(frames):
        msg = frame.get("message") or {}
        if (frame.get("direction") == "act_to_hub" and msg.get("type") == "progress"
                and msg.get("phase") == "hold"):
            return msg
    return None
