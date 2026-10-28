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
                   ``scope:"drive"``면 구동부 정지만(누르지 않음). ``stop_id``가 있으면 정지 확인 단계를
                   ``stop_report``로 답한다(2026-10-13, 정지 보고 규약 1)
  verify_pass    — 확인 주행: Z를 올린 채 좌표 위를 차례로 지나간다(누르지 않음)
  inject_failure — arm demo failure injection for the next execution (rehearsal)
  clear_failure  — disarm a previously armed injection
  hello          — RPi5가 (다시) 연결했다(2026-10-06 평가 C1·B3). 답은 act_info와 estop_state
  rehearsal      — 리허설 주입(2026-10-06): RPi4가 가짜 콘센트·모의 모션일 때만 받는다. 답은 rehearsal_result
  estop_ack      — 사람이 비상정지 해제를 확인했다(2026-10-05). RPi4의 비상정지 걸림(estop_latched)을
                   풀어 달라는 요청 — 콘센트 모듈 버튼이 아직 눌려 있으면 풀지 않고 걸린 채로 답한다
  dev_motion     — 개발자 조작(2026-10-10, 개발자 조작 규약 1): ``op`` home·jog·press·status·stop 한 번.
                   답은 ``dev_motion_result {request_id, ok, …}`` 하나. 실제 모션 어댑터가 물린 RPi4만
                   받는다(``act_info.dev_motion_protocol``) — rpi4/services/dev_motion.py
  heartbeat      — 실행 중 생존 신호(2026-10-16, 안전 보고 G5, 링크 생존 신호 규약 1). 답하지 않는다. ``execute``에
                   ``heartbeat_s``가 실린 실행·확인 주행(10/19)에서 인증된 줄이 제한 시간 넘게 없으면 RPi4가 스스로 멈춘다
                   (rpi/services/link_heartbeat.py)

Outbound (RPi4 → RPi5): plain dicts serialised by ActExecutor._send().
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field, replace

from rpi.controller.models import ButtonTarget, button_behavior
from rpi.services.link_heartbeat import parse_declared_period


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
    #: 선택 — RPi5가 정한 실행 표지(2026-10-15 G2). 같은 표지의 abort를 실행 시작 전에 받았으면 누르지 않는다.
    #: 없거나 모양이 틀리면 None(종전과 같다).
    run_ref: str | None = None
    #: 선택 — RPi5가 이 실행 동안 ``heartbeat``를 보내는 주기(초, 2026-10-16 G5). 있으면 RPi4가 링크 침묵을 감시해 스스로
    #: 멈춘다. 없거나 모양이 틀리면 None — 감시하지 않는다(옛 RPi5와 같다).
    heartbeat_s: float | None = None
    button_behaviors: dict[str, str] = field(default_factory=dict)


def _run_ref(doc: dict) -> str | None:
    """실행 표지(2026-10-15 G2) — 1~64자 문자열만. 모양이 틀리면 없는 것으로 본다(실행·정지는 그대로 한다)."""
    value = doc.get("run_ref")
    return value if isinstance(value, str) and 0 < len(value) <= 64 else None


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
    #: 정지 보고 짝(2026-10-13, 정지 보고 규약 1). 있으면 RPi4가 ``stop_report {stop_id, target, stop_level, ack_ms}``로
    #: 답한다. 없으면(옛 RPi5) 종전처럼 답하지 않는다. 모양이 틀려도 정지는 그대로 하고 보고만 하지 않는다.
    stop_id: str | None = None
    #: 실행 표지(2026-10-15 G2). 쉬는 중에 받으면 RPi4가 기억했다가 같은 표지의 execute를 누르지 않는다.
    #: 없으면(옛 RPi5) 종전처럼 쉬는 중 abort는 버린다.
    run_ref: str | None = None


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
    #: 선택 — 실행(execute)과 같은 생존 신호 주기(초, 10/19). 있으면 RPi4가 링크 침묵에 스스로 멈춘다. 없으면 None(옛 RPi5).
    heartbeat_s: float | None = None
    #: 확인 주행에는 실행 표지가 없다 — 생존 신호 감시가 실행과 같은 모양을 쓰게 둔다.
    run_ref: str | None = None


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


@dataclass(frozen=True)
class HeartbeatMsg:
    """실행 중 생존 신호(2026-10-16 G5). 답하지 않는다 — 받은 것 자체가 링크가 살아 있다는 근거다.

    ``sequence_id``(RPi5는 처음부터 실었다): 2026-10-19부터 RPi4는 **지금 실행 번호와 같은** 생존 신호만 센다."""

    sequence_id: str | None = None


@dataclass(frozen=True)
class ClockProbeMsg:
    """사건 신선도 기준점 탐침(3차 평가 M1). RPi4는 ``clock_ref {probe, clock_id, t_monotonic_ns}``로 곧바로 답한다."""

    probe: str


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


#: 개발자 조작 동작(2026-10-10). stop은 언제나 받는다.
DEV_MOTION_OPS = ("status", "home", "jog", "press", "press_here", "trace", "stop")
DEV_MOTION_AXES = ("x", "y", "z")


@dataclass(frozen=True)
class DevMotionMsg:
    """개발자 조작 한 번(2026-10-10). RPi5 개발자 API가 실물 모드일 때만 보낸다.

    ``jog``는 ``axis``와 ``delta_mm``(부호 있는 상대 이동, 0 아님)를, ``press``는 기록용 ``label``(버튼 id)을,
    ``stop``은 기록용 ``reason``을 싣는다. 재전송·자동 재개는 없다 — 요청 하나에 답 하나.
    """

    request_id: str
    op: str
    axis: str | None = None
    delta_mm: float | None = None
    label: str | None = None
    reason: str | None = None


@dataclass(frozen=True)
class DevMotionRefusedMsg:
    """모양이 틀린 dev_motion — id가 있으면 버리지 않고 ``bad_args``로 답한다(RPi5가 기한까지 기다리지 않게)."""

    request_id: str
    op: str | None
    reason: str
    detail: str


InboundActMsg = (
    ExecuteMsg | ExecuteRefusedMsg | AbortMsg | InjectFailureMsg | ClearFailureMsg | VerifyPassMsg | EstopAckMsg
    | HelloMsg | ClockProbeMsg | RehearsalMsg | DevMotionMsg | DevMotionRefusedMsg | HeartbeatMsg
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
                # 다른 가전의 정지 버튼이나 전력 상태로 대기하지 않고 거절로 답한다.
                return ExecuteRefusedMsg(
                    seq_id.strip(), HOLD_TARGET_MISMATCH,
                    f"정지 대기 대상({hold.appliance_id})이 실행 대상({target})과 달라 누르지 않았어요")
        return ExecuteMsg(sequence_id=seq_id.strip(), buttons=tuple(buttons), appliance_id=target,
                          targets=targets, hold=hold, run_ref=_run_ref(doc),
                          heartbeat_s=parse_declared_period(doc.get("heartbeat_s")),
                          button_behaviors={b: button_behavior(doc["button_behaviors"].get(b)) for b in buttons}
                          if isinstance(doc.get("button_behaviors"), dict) else {})

    if msg_type == "abort":
        scope = doc.get("scope", "appliance")
        if scope not in ("appliance", "drive"):
            return None
        stop_id = doc.get("stop_id")
        if not (isinstance(stop_id, str) and 0 < len(stop_id) <= 64):
            stop_id = None
        return AbortMsg(scope=scope, stop_id=stop_id, run_ref=_run_ref(doc))

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
        return VerifyPassMsg(sequence_id=seq_id.strip(), targets=tuple(parsed),
                             heartbeat_s=parse_declared_period(doc.get("heartbeat_s")))

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

    if msg_type == "heartbeat":
        seq = doc.get("sequence_id")
        return HeartbeatMsg(seq if isinstance(seq, str) and seq else None)

    if msg_type == "clock_probe":
        probe = doc.get("probe")
        if not isinstance(probe, str) or not 1 <= len(probe) <= 64:
            return None
        return ClockProbeMsg(probe)

    if msg_type == "rehearsal":
        return _parse_rehearsal(doc)

    if msg_type == "dev_motion":
        return _parse_dev_motion(doc)

    return None  # 알 수 없는 형식은 오류 없이 무시한다.


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


def _parse_dev_motion(doc: dict) -> DevMotionMsg | DevMotionRefusedMsg | None:
    """개발자 조작을 엄격하게 읽는다. id가 없으면 None(답할 곳이 없다), id가 있고 모양이 틀리면 거절 메시지."""
    request_id = doc.get("request_id")
    if not isinstance(request_id, str) or not _REHEARSAL_ID.fullmatch(request_id):
        return None
    op = doc.get("op")
    op_name = op if isinstance(op, str) and op in DEV_MOTION_OPS else None

    def bad(detail: str) -> DevMotionRefusedMsg:
        return DevMotionRefusedMsg(request_id, op_name, "bad_args", detail)

    if op_name is None:
        return bad(f"모르는 개발자 조작이에요: {op!r}")
    if op_name == "jog":
        axis, delta = doc.get("axis"), doc.get("delta_mm")
        if axis not in DEV_MOTION_AXES:
            return bad("조그 축은 x·y·z 중 하나여야 해요")
        if not _is_number(delta) or float(delta) == 0.0:
            return bad("조그 거리(delta_mm)는 0이 아닌 유한한 수여야 해요")
        return DevMotionMsg(request_id, "jog", axis=axis, delta_mm=float(delta))
    if op_name == "press":
        label = doc.get("label")
        if label is not None and (not isinstance(label, str) or not _REHEARSAL_ID.fullmatch(label)):
            return bad("누름 이름(label) 모양이 틀렸어요")
        return DevMotionMsg(request_id, "press", label=label)
    if op_name == "stop":
        reason = doc.get("reason")
        reason = reason if isinstance(reason, str) and _REHEARSAL_EVENT.fullmatch(reason) else None
        return DevMotionMsg(request_id, "stop", reason=reason)
    return DevMotionMsg(request_id, op_name)


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
