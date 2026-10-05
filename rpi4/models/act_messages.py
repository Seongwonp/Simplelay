"""Typed representations of the RPi5 → RPi4 UART protocol (docs/protocol.md).

This is a *different* leg than models/messages.py (which covers ESP32 ↔
the Interpret side). Here RPi5 has already resolved a purpose into a button
sequence and just wants RPi4 to execute it — no intent resolution happens
on this leg.

Inbound (RPi5 → RPi4):
  execute        — already-resolved button sequence to run through the closed loop
                   (선택 ``hold``: 끝난 뒤 정지 버튼 위 대기·보관 위치, 2026-09-30)
  abort          — cancel; forwarded to the safety controller. 실행이 끝나고 정지 버튼
                   위에서 대기 중이면 **가전 정지**(정지 버튼 누름)로 처리한다.
                   ``scope:"drive"``면 구동부 정지만(누르지 않음)
  verify_pass    — 확인 주행: Z를 올린 채 좌표 위를 차례로 지나간다(누르지 않음)
  inject_failure — arm demo failure injection for the next execution (rehearsal)
  clear_failure  — disarm a previously armed injection
  estop_ack      — 사람이 비상정지 해제를 확인했다(2026-10-05). RPi4의 비상정지 걸림(estop_latched)을
                   풀어 달라는 요청 — 콘센트 모듈 버튼이 아직 눌려 있으면 풀지 않고 걸린 채로 답한다

Outbound (RPi4 → RPi5): plain dicts serialised by ActExecutor._send().
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field

from rpi.controller.models import ButtonTarget


@dataclass(frozen=True)
class HoldPlan:
    """실행이 끝난 뒤의 정지 대기·보관 계획(2026-09-30). 좌표는 갠트리 mm.

    RPi5가 가전 레지스트리(``stop_button``·``stop_presses``·``park_xy``)에서 만든다.
    """

    stop_button: str
    stop_x_mm: float
    stop_y_mm: float
    stop_presses: int
    park_x_mm: float
    park_y_mm: float
    press_ms: int | None = None
    appliance_id: str | None = None


@dataclass(frozen=True)
class ExecuteMsg:
    sequence_id: str
    buttons: tuple[str, ...]
    #: 선택 — 버튼 → 갠트리 좌표(mm)·누름 유지 시간. 보정된 버튼만 싣는다.
    #: 없으면 빈 dict(종전 메시지와 같다).
    targets: dict[str, ButtonTarget] = field(default_factory=dict)
    #: 선택 — 정지 대기·보관 계획. 없으면 종전처럼 실행만 한다.
    hold: HoldPlan | None = None


@dataclass(frozen=True)
class AbortMsg:
    #: "appliance"(기본): 실행 중이면 협조적 정지, 정지 대기 중이면 정지 버튼 누름.
    #: "drive": 구동부 정지만 — 정지 버튼을 누르지 않는다(가전 정지와 구분).
    scope: str = "appliance"


@dataclass(frozen=True)
class VerifyTarget:
    button: str
    x_mm: float
    y_mm: float
    #: "button" | "park"
    kind: str = "button"


@dataclass(frozen=True)
class VerifyPassMsg:
    """확인 주행 — Z를 올린 채 좌표 위를 차례로 지나간다. 누르지 않는다."""

    sequence_id: str
    targets: tuple[VerifyTarget, ...]


@dataclass(frozen=True)
class InjectFailureMsg:
    """리허설 실패 주입 무장 — POST /demo/inject-failure의 UART 전달판.
    검증이 RPi4에서 일어나는 UART 모드에서도 결선 핵심 장면("일부러
    실패시켜도 스스로 재시도")을 연출할 수 있게 한다."""

    button_index: int
    attempts: int


@dataclass(frozen=True)
class ClearFailureMsg:
    pass


@dataclass(frozen=True)
class EstopAckMsg:
    """비상정지 해제 확인(RPi5 ``POST /stop/ack``). 답은 ``estop_state`` 프레임이다."""


InboundActMsg = (
    ExecuteMsg | AbortMsg | InjectFailureMsg | ClearFailureMsg | VerifyPassMsg | EstopAckMsg
)

#: 정지 버튼 누름 횟수 상한(전자레인지: 1회 일시정지·2회 취소 등). 레지스트리와 같다.
STOP_PRESSES_RANGE = (1, 3)
#: 확인 주행 한 번의 좌표 수 상한.
MAX_VERIFY_TARGETS = 40


def parse_act_message(raw: str) -> InboundActMsg | None:
    """Parse one JSON line from the RPi5 serial stream.

    Returns None for malformed JSON, non-dict payloads, unknown ``type``
    fields, or structurally invalid known types (e.g. execute with no
    buttons). Never raises; callers can safely ignore a None return.
    """
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return None

    if not isinstance(doc, dict):
        return None

    msg_type = doc.get("type")

    if msg_type == "execute":
        seq_id = doc.get("sequence_id", "")
        buttons = doc.get("buttons", [])
        if not isinstance(seq_id, str) or not seq_id.strip():
            return None
        if not isinstance(buttons, list) or not buttons:
            return None
        if not all(isinstance(b, str) and b.strip() for b in buttons):
            return None
        targets = _parse_targets(doc.get("targets"), buttons)
        if targets is None:
            return None
        hold = None
        if doc.get("hold") is not None:
            hold = _parse_hold(doc.get("hold"))
            if hold is None:
                return None  # targets와 같은 규칙 — 이상한 계획으로 움직이지 않는다
        return ExecuteMsg(sequence_id=seq_id.strip(), buttons=tuple(buttons), targets=targets,
                          hold=hold)

    if msg_type == "abort":
        scope = doc.get("scope", "appliance")
        if scope not in ("appliance", "drive"):
            return None
        return AbortMsg(scope=scope)

    if msg_type == "verify_pass":
        seq_id = doc.get("sequence_id", "")
        raw_targets = doc.get("targets")
        if not isinstance(seq_id, str) or not seq_id.strip():
            return None
        if not isinstance(raw_targets, list) or not 1 <= len(raw_targets) <= MAX_VERIFY_TARGETS:
            return None
        parsed: list[VerifyTarget] = []
        for item in raw_targets:
            if not isinstance(item, dict):
                return None
            button, x, y = item.get("button"), item.get("x_mm"), item.get("y_mm")
            kind = item.get("kind", "button")
            if not isinstance(button, str) or not button.strip() or kind not in ("button", "park"):
                return None
            if not (_is_number(x) and _is_number(y)):
                return None
            parsed.append(VerifyTarget(button.strip(), float(x), float(y), kind))
        return VerifyPassMsg(sequence_id=seq_id.strip(), targets=tuple(parsed))

    if msg_type == "inject_failure":
        button_index = doc.get("button_index")
        attempts = doc.get("attempts")
        # 스키마(DemoInjectFailureRequest)와 같은 범위 — 링크 건너편이라고
        # 검증을 느슨하게 하지 않는다
        if not isinstance(button_index, int) or isinstance(button_index, bool):
            return None
        if not isinstance(attempts, int) or isinstance(attempts, bool):
            return None
        if button_index < 0 or not 1 <= attempts <= 10:
            return None
        return InjectFailureMsg(button_index=button_index, attempts=attempts)

    if msg_type == "clear_failure":
        return ClearFailureMsg()

    if msg_type == "estop_ack":
        return EstopAckMsg()

    return None  # unknown type — not an error, just silently ignored


def _is_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def _parse_targets(raw: object, buttons: list) -> dict[str, ButtonTarget] | None:
    """``targets``를 엄격하게 읽는다. 하나라도 이상하면 메시지 전체를 버린다(None).

    좌표 한 개가 틀린 채 실행되면 **엉뚱한 버튼을 누른다** — 일부만 받아들이지 않는다.
    시퀀스에 없는 버튼의 좌표도 거절한다(보낸 쪽과 받는 쪽이 다른 시퀀스를 보고 있다).
    """
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        return None
    wanted = set(buttons)
    targets: dict[str, ButtonTarget] = {}
    for name, value in raw.items():
        if name not in wanted or not isinstance(value, dict):
            return None
        x, y, press_ms = value.get("x_mm"), value.get("y_mm"), value.get("press_ms")
        if not (_is_number(x) and _is_number(y)):
            return None
        if press_ms is not None and (
            isinstance(press_ms, bool) or not isinstance(press_ms, int) or press_ms <= 0
        ):
            return None
        targets[name] = ButtonTarget(float(x), float(y), press_ms)
    return targets


def _parse_hold(raw: object) -> HoldPlan | None:
    """``hold``를 엄격하게 읽는다. 하나라도 이상하면 None(메시지 전체를 버린다)."""
    if not isinstance(raw, dict):
        return None
    button = raw.get("stop_button")
    presses = raw.get("stop_presses")
    press_ms = raw.get("press_ms")
    appliance_id = raw.get("appliance_id")
    numbers = [raw.get(k) for k in ("stop_x_mm", "stop_y_mm", "park_x_mm", "park_y_mm")]
    if not isinstance(button, str) or not button.strip():
        return None
    if isinstance(presses, bool) or not isinstance(presses, int):
        return None
    if not STOP_PRESSES_RANGE[0] <= presses <= STOP_PRESSES_RANGE[1]:
        return None
    if not all(_is_number(v) and v >= 0 for v in numbers):
        return None
    if press_ms is not None and (
        isinstance(press_ms, bool) or not isinstance(press_ms, int) or press_ms <= 0
    ):
        return None
    if appliance_id is not None and not isinstance(appliance_id, str):
        return None
    sx, sy, px, py = (float(v) for v in numbers)
    if (sx, sy) == (px, py):
        return None  # 보관 위치가 정지 버튼 위면 대기와 보관이 구분되지 않는다
    return HoldPlan(button.strip(), sx, sy, presses, px, py, press_ms, appliance_id)
