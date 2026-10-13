"""개발자 모드 실물 어댑터 — RPi5 개발자 API → RPi4(``dev_motion`` 프레임) → 모션 MCU. 2026-10-10, **실물 미검증**.

켜는 조건(셋 다):
1. RPi5 ``SIMPLELAY_DEV_MODE=1`` (개발자 API 자체)
2. RPi5 ``SIMPLELAY_DEV_REAL_MOTION=1`` (이 어댑터를 문다 — 없으면 지금과 똑같이 모의)
3. RPi4가 ``act_info``로 실제 모션 링크(``motion:"serial"``)와 개발자 조작 규약(``dev_motion_protocol`` ≥ 1)을 알림
   — 아니면 명령마다 움직이기 전에 거절한다(`DevAdapterRefused`)

이 어댑터가 RPi4에 **보내기 전에** 거절하는 것: RPi4 링크 없음(ACT_MODE가 uart 아님)·끊김, RPi4 모의 모션, 옛 RPi4
(개발자 조작 규약 없음), 비상정지 걸림·상태 모름, 한 번 조그 상한(`max_step_mm`) 초과. 일반 실행과의 배타는
매니저의 ControlArbiter가, 정지 대기·확인 주행 중 거절은 RPi4가 한다.

조그 TTL: 모의 어댑터의 jog TTL(누르고 있는 동안만 움직임)은 여기서 쓰지 않는다. 실물 조그는 MCU가 보고한 현재
위치에서 ``±amount_mm`` 떨어진 **절대 목표 한 번**이라 스스로 끝나고, 크기가 상한으로 묶인다. 요청 하나에 답 하나,
재전송·자동 재개는 없다.

정지: RPi4가 개발자 조작 규약을 알리면 ``dev_motion stop``을 보낸다. RPi4가 답한 정지 확인 단계(2026-10-13,
규약 2 — ``sent``·``mcu_ack``·``verified``)를 돌려주고, API의 ``confirmed``는 ``mcu_ack`` 이상일 때만 참이다(최종 권한은
물리 E-STOP). 옛 RPi4·모의 모션이면 ``abort {scope:"drive"}``를 보내고 ``sent``다(그런 RPi4에는 개발자 이동이 애초에
가지 않았다). 링크가 끊겼으면 예외 — 매니저가 정지 미확인(fault)으로 잠근다.
"""

from __future__ import annotations

import logging
import math
import os
from collections.abc import Callable

from .developer_session import MAX_JOG_MM, DevAdapterRefused, DevAxis

log = logging.getLogger(__name__)

DEV_REAL_MOTION_ENV = "SIMPLELAY_DEV_REAL_MOTION"
DEV_REAL_MAX_STEP_ENV = "SIMPLELAY_DEV_REAL_MAX_STEP_MM"
#: 실물 조그 한 번 기본 상한(mm) — 하드웨어 첫날 작은 조그(1 mm) 기준. 실측 뒤 env로 늘린다.
DEFAULT_REAL_MAX_STEP_MM = 1.0
#: 설정해도 넘지 않는 상한(mm). 개발자 명령 파서 상한(MAX_JOG_MM)과 같고 10 mm 이하다.
#: RPi4도 따로 10 mm 울타리를 둔다(rpi4/services/dev_motion.py DEV_JOG_STEP_CEILING_MM).
REAL_MAX_STEP_CEILING_MM = MAX_JOG_MM
#: RPi4가 act_info로 알려야 하는 개발자 조작 규약 판.
DEV_MOTION_PROTOCOL_REQUIRED = 1

#: 조작별 응답 기한(초). 원점 복귀는 펌웨어 HOME_MAX_MS(70 s)보다 길게. 호스트 박자 — 측정 필요.
HOME_TIMEOUT_S = 90.0
MOVE_TIMEOUT_S = 20.0
STATUS_TIMEOUT_S = 5.0
STOP_TIMEOUT_S = 3.0


def dev_real_motion_requested() -> bool:
    return os.environ.get(DEV_REAL_MOTION_ENV, "").strip().lower() in {"1", "true"}


def real_max_step_from_env() -> float:
    """``SIMPLELAY_DEV_REAL_MAX_STEP_MM``(기본 1 mm). 상한을 넘으면 상한으로 묶고 경고, 0 이하·숫자 아님은 거절."""
    raw = os.environ.get(DEV_REAL_MAX_STEP_ENV, "").strip()
    if not raw:
        return DEFAULT_REAL_MAX_STEP_MM
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{DEV_REAL_MAX_STEP_ENV} 값을 숫자로 읽을 수 없어요: {raw!r}") from exc
    if not math.isfinite(value) or value <= 0:
        raise RuntimeError(f"{DEV_REAL_MAX_STEP_ENV}는 0보다 큰 수여야 해요: {raw!r}")
    if value > REAL_MAX_STEP_CEILING_MM:
        log.warning("%s=%s exceeds the ceiling — capped to %g mm", DEV_REAL_MAX_STEP_ENV, raw,
                    REAL_MAX_STEP_CEILING_MM)
        return REAL_MAX_STEP_CEILING_MM
    return value


class DevAdapterFailed(RuntimeError):
    """움직였을 수 있는 실패(알람·기한 초과·링크 끊김). 매니저가 정지로 정리하고 ``detail``을 덧붙인다."""

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail


class ActDevMotionAdapter:
    """개발자 매니저의 `MotionAdapter` 실물판 — RPi4 링크(ActClientController)로 보낸다.

    ``link_provider``는 지금의 RPi4 링크(``dev_motion_link``·``dev_motion``·``request_drive_stop``을 가진 것)
    또는 None을 돌려준다. 서비스가 늦게 만들어져도 되게 매번 묻는다.
    """

    is_mock = False

    def __init__(self, link_provider: Callable[[], object | None], *,
                 max_step_mm: float = DEFAULT_REAL_MAX_STEP_MM) -> None:
        if not (math.isfinite(max_step_mm) and 0 < max_step_mm <= REAL_MAX_STEP_CEILING_MM):
            raise ValueError(f"max_step_mm는 0보다 크고 {REAL_MAX_STEP_CEILING_MM:g} 이하여야 해요: {max_step_mm!r}")
        self._link_provider = link_provider
        self._max_step_mm = float(max_step_mm)

    @property
    def max_step_mm(self) -> float:
        return self._max_step_mm

    # ── 준비 확인 ───────────────────────────────────────────────────────────

    def _link(self):
        try:
            link = self._link_provider()
        except Exception as exc:  # noqa: BLE001 - 서비스 생성 실패도 '링크 없음'으로
            log.exception("developer real motion: link provider failed")
            raise DevAdapterRefused("act_link_unavailable", f"RPi4 링크를 열지 못했어요: {exc}") from exc
        if link is None or not callable(getattr(link, "dev_motion", None)):
            raise DevAdapterRefused(
                "act_link_unavailable",
                "RPi4 링크가 없어요 — RPi5를 SIMPLELAY_ACT_MODE=uart로 켜야 실제 장치를 움직여요",
            )
        return link

    @staticmethod
    def _snapshot(link) -> dict:
        snap = link.dev_motion_link()
        return snap if isinstance(snap, dict) else {}

    @staticmethod
    def _supports_dev(snap: dict) -> bool:
        info = snap.get("act_info") or {}
        protocol = info.get("dev_motion_protocol")
        return info.get("motion") == "serial" and type(protocol) is int and protocol >= DEV_MOTION_PROTOCOL_REQUIRED

    def _problem(self, link) -> tuple[str, str] | None:
        snap = self._snapshot(link)
        if not snap.get("link_up"):
            reason = snap.get("link_reason")
            if isinstance(reason, str) and reason.startswith("RPi4 인증"):
                return "link_down", reason  # 짝 키가 맞지 않음(2026-10-12) — 기다려도 이어지지 않는다
            return "link_down", "RPi4 연결이 끊겨 있어요 — 다시 이어진 뒤 조작해 주세요"
        info = snap.get("act_info") or {}
        if not info:
            return "act_info_unknown", "RPi4 구성을 아직 받지 못했어요 — 잠시 뒤 다시 시도해 주세요"
        if info.get("motion") != "serial":
            return "motion_mock", f"RPi4가 모의 모션이에요(motion={info.get('motion')!r}) — 실제 장치를 움직일 수 없어요"
        protocol = info.get("dev_motion_protocol")
        if type(protocol) is not int or protocol < DEV_MOTION_PROTOCOL_REQUIRED:
            return ("dev_protocol_unsupported",
                    "RPi4가 개발자 조작을 모르는 판이에요 — RPi5와 같은 판으로 배포해 주세요")
        latched = snap.get("estop_latched")
        if latched is True:
            return "estop_latched", "비상정지가 걸려 있어요 — 풀고 확인한 뒤 다시 시도해 주세요"
        if latched is None:
            return "estop_unknown", "비상정지 상태를 확인하는 중이에요 — 잠시 뒤 다시 시도해 주세요"
        return None

    def availability(self) -> tuple[str, str] | None:
        """움직일 수 없는 이유 ``(code, 문장)``, 준비됐으면 None. 보내지 않고 읽기만 한다(표시용)."""
        try:
            return self._problem(self._link())
        except DevAdapterRefused as exc:
            return exc.code, exc.message

    def _require_ready(self):
        link = self._link()
        problem = self._problem(link)
        if problem is not None:
            raise DevAdapterRefused(*problem)
        return link

    # ── 명령 ────────────────────────────────────────────────────────────────

    def _call(self, link, op: str, timeout_s: float, **fields) -> dict:
        try:
            reply = link.dev_motion(op, timeout_s, **fields)
        except DevAdapterRefused:
            raise
        except Exception as exc:  # 링크 끊김·기한 초과 — 움직였는지 모른다
            raise DevAdapterFailed(f"RPi4 응답을 확인하지 못했어요: {exc}") from exc
        if not isinstance(reply, dict):
            raise DevAdapterFailed("RPi4 답의 모양이 틀렸어요")
        if reply.get("ok") is True:
            return reply
        reason = reply.get("reason") if isinstance(reply.get("reason"), str) else "refused"
        detail = reply.get("detail") if isinstance(reply.get("detail"), str) else reason
        if reply.get("moved") is False:
            raise DevAdapterRefused(reason, detail)
        raise DevAdapterFailed(f"{reason}: {detail}")

    def jog(self, axis: DevAxis, direction: int, amount_mm: float, ttl_s: float) -> None:
        # ttl_s는 쓰지 않는다 — 실물 조그는 상한으로 묶인 절대 목표 한 번이다(머리말).
        if not (0 < amount_mm <= self._max_step_mm):
            raise DevAdapterRefused("step_too_large", f"한 번에 {self._max_step_mm:g}mm까지만 움직여요")
        link = self._require_ready()
        delta = amount_mm if direction > 0 else -amount_mm
        self._call(link, "jog", MOVE_TIMEOUT_S, axis=axis.value, delta_mm=delta)

    def home(self) -> None:
        link = self._require_ready()
        self._call(link, "home", HOME_TIMEOUT_S)

    def press(self, button_id: str) -> None:
        # 지금 위치에서 솔레노이드 시간 누름 한 번(RPi4 설정·800 ms 상한). button_id는 기록용 이름이다 —
        # 버튼 좌표로 이동하지 않는다(조그로 맞춘 자리에서 누른다).
        link = self._require_ready()
        self._call(link, "press", MOVE_TIMEOUT_S, label=button_id)

    def read_sensor(self) -> dict[str, float]:
        """실물에는 전류·음향 대신 MCU 위치를 돌려준다(x_mm·y_mm, 원점 확인 homed 1/0)."""
        link = self._require_ready()
        reply = self._call(link, "status", STATUS_TIMEOUT_S)
        out: dict[str, float] = {}
        for key in ("x_mm", "y_mm"):
            value = reply.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
                out[key] = float(value)
        out["homed"] = 1.0 if reply.get("homed") is True else 0.0
        return out

    def stop(self, reason: str) -> dict:
        """정지 — 거절 조건(비상정지·모의·상한)을 보지 않는다. 링크가 없거나 끊겼으면 예외(RPi4에 닿지 못함).

        돌려주는 값은 정지 확인 단계 ``{"stop_level", "ack_ms"}``(2026-10-13): RPi4가 개발자 조작 규약 2로 답한
        ``sent``·``mcu_ack``·``verified``. 단계가 없는 답(규약 1)·모르는 값·``abort drive`` 대체 경로는 ``sent``다 —
        RPi4가 정지를 보냈다는 것까지만 안다(`rpi.services.stop_confirm`)."""
        from .stop_confirm import STOP_SENT, read_ack_ms, read_stop_level  # noqa: PLC0415

        link = self._link()
        snap = self._snapshot(link)
        if not snap.get("link_up"):
            raise RuntimeError("RPi4 연결이 끊겨 정지를 보내지 못했어요")
        if not self._supports_dev(snap):
            # 옛 RPi4·모의 모션: 개발자 이동이 가지 않았다. 그래도 구동부 정지는 보낸다(답 없는 단방향).
            drive_stop = getattr(link, "request_drive_stop", None)
            if callable(drive_stop):
                drive_stop()
            return {"stop_level": STOP_SENT, "ack_ms": None}
        reply = link.dev_motion("stop", STOP_TIMEOUT_S, reason=_reason_token(reason))
        if not isinstance(reply, dict) or reply.get("ok") is not True:
            detail = reply.get("detail") if isinstance(reply, dict) else None
            raise RuntimeError(f"RPi4가 정지를 보내지 못했어요: {detail or reply!r}")
        level = read_stop_level(reply.get("stop_level"))
        return {"stop_level": level, "ack_ms": read_ack_ms(reply.get("ack_ms"), level)}


def _reason_token(reason: str) -> str:
    """정지 이유를 규약 모양(소문자·밑줄)으로 — 모르는 모양이면 dev_stop."""
    token = (reason or "").strip().lower()
    if token and all(ch.isascii() and (ch.isalnum() or ch == "_") for ch in token) and token[0].isalpha():
        return token[:64]
    return "dev_stop"
