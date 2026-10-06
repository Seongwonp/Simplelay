"""Typed representations of the RPi5 → RPi4 UART protocol (docs/protocol.md).

This is a *different* leg than models/messages.py (which covers ESP32 ↔
the Interpret side). Here RPi5 has already resolved a purpose into a button
sequence and just wants RPi4 to execute it — no intent resolution happens
on this leg.

Inbound (RPi5 → RPi4):
  execute        — already-resolved button sequence to run through the closed loop
                   (선택 ``hold``: 끝난 뒤 정지 버튼 위 대기·보관 위치, 2026-09-30).
                   **대상 가전 ``appliance_id`` 필수(2026-10-07, 평가 H3)** — RPi4가 그 대상의 CT 채널로
                   L3·정지 확인을 고른다. 대상이 없는 옛 프레임은 실행하지 않고
                   ``error {reason:"target_required"}``로 답한다(`ExecuteRefusedMsg`)
  abort          — cancel; forwarded to the safety controller. 실행이 끝나고 정지 버튼
                   위에서 대기 중이면 **가전 정지**(정지 버튼 누름)로 처리한다.
                   ``scope:"drive"``면 구동부 정지만(누르지 않음)
  verify_pass    — 확인 주행: Z를 올린 채 좌표 위를 차례로 지나간다(누르지 않음)
  inject_failure — arm demo failure injection for the next execution (rehearsal)
  clear_failure  — disarm a previously armed injection
  hello          — RPi5가 (다시) 연결했다(2026-10-06 평가 C1·B3). 답은 act_info와 estop_state
  rehearsal      — 리허설 주입(2026-10-06): RPi4가 가짜 콘센트·모의 모션일 때만 받는다. 답은 rehearsal_result
  estop_ack      — 사람이 비상정지 해제를 확인했다(2026-10-05). RPi4의 비상정지 걸림(estop_latched)을
                   풀어 달라는 요청 — 콘센트 모듈 버튼이 아직 눌려 있으면 풀지 않고 걸린 채로 답한다

Outbound (RPi4 → RPi5): plain dicts serialised by ActExecutor._send().
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field, replace

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
    #: 필수 — 실행 대상 가전 ID(2026-10-07). L3 전력 채널·정지 확인 채널을 이 대상으로 고른다.
    appliance_id: str
    #: 선택 — 버튼 → 갠트리 좌표(mm)·누름 유지 시간. 보정된 버튼만 싣는다.
    #: 없으면 빈 dict(종전 메시지와 같다).
    targets: dict[str, ButtonTarget] = field(default_factory=dict)
    #: 선택 — 정지 대기·보관 계획. 없으면 종전처럼 실행만 한다.
    hold: HoldPlan | None = None


#: execute 프레임 규약 판(2026-10-07). 2 = ``appliance_id`` 필수. ``act_info.execute_protocol``로 알린다.
EXECUTE_PROTOCOL = 2

#: 대상 없는 execute의 거절 사유.
TARGET_REQUIRED = "target_required"
HOLD_TARGET_MISMATCH = "hold_target_mismatch"
TARGET_REQUIRED_DETAIL = (
    "실행 대상 가전(appliance_id)이 없는 실행 요청이라 누르지 않았어요 — "
    "RPi5와 RPi4를 같은 판으로 배포해 주세요(execute 규약 2)"
)


@dataclass(frozen=True)
class ExecuteRefusedMsg:
    """모양은 execute인데 실행할 수 없는 프레임 — 조용히 버리지 않고 ``error``로 답한다.

    대상(``appliance_id``)이 없는 옛 RPi5 프레임(``target_required``)과 정지 대기 대상이 실행 대상과 다른
    프레임(``hold_target_mismatch``)을 이렇게 읽는다. 버리면 RPi5가 응답 제한시간까지
    기다렸다가 '응답 없음'으로 끝나 원인이 숨는다.
    """

    sequence_id: str
    reason: str
    detail: str


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


@dataclass(frozen=True)
class HelloMsg:
    """RPi5 연결 알림. RPi4는 act_info(끝 관찰 가전·리허설 가능 여부)와 estop_state로 답한다."""


#: 리허설 주입 동작 — 콘센트 비상 버튼 누름·풀기, 가전 끝 주입.
REHEARSAL_ACTIONS = ("outlet_estop", "outlet_estop_release", "appliance_done")


@dataclass(frozen=True)
class RehearsalMsg:
    """리허설 주입(시연 장면 ④⑤를 보드에서). RPi4가 실물 모듈·모터에 붙어 있으면 거절한다."""

    action: str
    request_id: str
    hold_button: bool = False
    appliance_id: str = "washer"
    inputs: tuple[str, ...] = ()
    event: str | None = None


InboundActMsg = (
    ExecuteMsg | ExecuteRefusedMsg | AbortMsg | InjectFailureMsg | ClearFailureMsg | VerifyPassMsg | EstopAckMsg
    | HelloMsg | RehearsalMsg
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
        target = doc.get("appliance_id")
        if target is None:
            # 옛 RPi5(대상 없음) — 전자레인지로 가정하지 않는다. 거절을 답한다(2026-10-07, 평가 H3).
            return ExecuteRefusedMsg(seq_id.strip(), TARGET_REQUIRED, TARGET_REQUIRED_DETAIL)
        if not isinstance(target, str) or not _APPLIANCE_ID.fullmatch(target):
            return None
        hold = None
        if doc.get("hold") is not None:
            hold = _parse_hold(doc.get("hold"))
            if hold is None:
                return None  # targets와 같은 규칙 — 이상한 계획으로 움직이지 않는다
            if hold.appliance_id is None:
                hold = replace(hold, appliance_id=target)
            elif hold.appliance_id != target:
                # 다른 가전의 정지 버튼·전력으로 대기하지 않는다 — 버리지 않고 거절로 답한다(교차 리뷰 92876bd).
                return ExecuteRefusedMsg(
                    seq_id.strip(), HOLD_TARGET_MISMATCH,
                    f"정지 대기 대상({hold.appliance_id})이 실행 대상({target})과 달라 누르지 않았어요")
        return ExecuteMsg(sequence_id=seq_id.strip(), buttons=tuple(buttons), appliance_id=target,
                          targets=targets, hold=hold)

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

    if msg_type == "hello":
        return HelloMsg()

    if msg_type == "rehearsal":
        return _parse_rehearsal(doc)

    return None  # unknown type — not an error, just silently ignored


_REHEARSAL_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
#: 가전 ID 모양(RPi5 스키마·SIMPLELAY_OUTLET_CHANNELS와 같다).
_APPLIANCE_ID = _REHEARSAL_ID
_REHEARSAL_EVENT = re.compile(r"[a-z][a-z0-9_]{0,63}")


def _parse_rehearsal(doc: dict) -> RehearsalMsg | None:
    """리허설 주입을 엄격하게 읽는다(RPi5 스키마 DemoApplianceDoneRequest와 같은 범위)."""
    action, request_id = doc.get("action"), doc.get("request_id")
    if action not in REHEARSAL_ACTIONS or not isinstance(request_id, str) or not _REHEARSAL_ID.fullmatch(request_id):
        return None
    if action != "appliance_done":
        hold = doc.get("hold_button", False)
        if not isinstance(hold, bool):
            return None
        return RehearsalMsg(action, request_id, hold_button=hold)
    appliance, inputs, event = doc.get("appliance_id"), doc.get("inputs"), doc.get("event")
    if not isinstance(appliance, str) or not _REHEARSAL_ID.fullmatch(appliance):
        return None
    if (not isinstance(inputs, list) or not 1 <= len(inputs) <= 2
            or any(i not in ("power", "beep") for i in inputs)):
        return None
    if event is not None and (not isinstance(event, str) or not _REHEARSAL_EVENT.fullmatch(event)):
        return None
    return RehearsalMsg(action, request_id, appliance_id=appliance, inputs=tuple(inputs), event=event)


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
