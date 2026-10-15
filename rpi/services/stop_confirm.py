"""정지 확인 단계를 RPi5에서 읽는 규칙(2026-10-13, docs/계획-정지-확인-2026-10-12.md).

RPi4가 올리는 단계(`rpi.controller.serial_motion.STOP_LEVELS`):
``sent``(정지 줄을 썼다) < ``mcu_ack``(모션 MCU가 받았다) < ``verified``(엔코더로 멈춤 확인).
**확인(confirmed)은 ``mcu_ack`` 이상일 때만**이다. 단계가 없는 답(옛 RPi4)·모르는 값은 ``sent``로 낮춰 읽는다 —
보낸 것은 확실하지만 그 이상은 모른다. 물리 E-STOP이 최종 권한이다. 기한·지연 값은 실물로 재야 한다.

``verified``는 '정지 뒤 엔코더 값이 같다'만으로 내지 않는다(2026-10-15 G11): 이번 실행에 이동을 명령한 축마다 엔코더
값이 바뀐 것을 RPi4 어댑터가 봤을 때만이다. 죽은 엔코더(늘 같은 값)·이동 없는 쉬는 중 정지는 ``mcu_ack``에 머문다
(`rpi.controller.serial_motion.ENCODER_UNPROVEN_DETAIL`).
"""

from __future__ import annotations

from rpi.controller.serial_motion import STOP_LEVELS, STOP_MCU_ACK, STOP_SENT, STOP_VERIFIED

__all__ = [
    "STOP_LEVELS", "STOP_MCU_ACK", "STOP_SENT", "STOP_VERIFIED",
    "read_stop_level", "read_ack_ms", "stop_level_confirmed", "stop_sentence",
]


def read_stop_level(value: object) -> str:
    """RPi4가 보낸 값 → 알려진 단계. 없거나 모르는 값은 ``sent``(보냄까지만)."""
    return value if isinstance(value, str) and value in STOP_LEVELS else STOP_SENT


def read_ack_ms(value: object, level: str) -> int | None:
    """지연 ms — MCU 확인 이상이고 0 이상 정수일 때만."""
    if level == STOP_SENT or isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def stop_level_confirmed(level: str | None) -> bool:
    return level in (STOP_MCU_ACK, STOP_VERIFIED)


def stop_sentence(level: str | None, ack_ms: int | None = None) -> str | None:
    """화면·응답 문장(해요체). 단계가 없으면 None — 호출자가 자기 문장을 쓴다."""
    if level == STOP_VERIFIED:
        # ack_ms는 보낸 뒤 모션 보드 응답까지다(멈춤 확인까지가 아님) — 폰·키오스크와 같은 문장(10/13).
        return "멈춘 것을 확인했어요" + (f" (모션 보드 응답 {ack_ms} ms)" if ack_ms is not None else "")
    if level == STOP_MCU_ACK:
        return "모션 보드가 정지를 확인했어요" + (f" ({ack_ms} ms)" if ack_ms is not None else "")
    if level == STOP_SENT:
        return "정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요"
    return None
