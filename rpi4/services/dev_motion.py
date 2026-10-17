"""개발자 조작(``dev_motion``)의 RPi4 쪽 — 2026-10-10, **실물 미검증**.

RPi5 개발자 API가 실물 모드(``SIMPLELAY_DEV_MODE`` + ``SIMPLELAY_DEV_REAL_MOTION``)일 때 보내는 홈·조그·누름·
상태·정지 한 번을, 일반 실행과 **같은** `SerialMotionClient`로 모션 MCU(firmware-motion-corexy)에 넘긴다.
그래서 MCU의 거절(``busy``·``not_homed``·``soft_limit``·``z_cooldown`` …)과 알람이 그대로 올라온다.

이 층이 더하는 제한(펌웨어·어댑터 검사 위에 한 겹 더):
- 조그는 X·Y 상대 이동 한 번, 크기 0 < |d| ≤ `DEV_JOG_STEP_CEILING_MM`. Z는 솔레노이드라 조그가 없다.
  기준 위치는 MCU가 보고한 A·B 카운트(조그 CLI와 같다) — 호스트가 위치를 짐작하지 않는다.
- 원점(홈) 전 조그·누름 거절. 정지로 끊긴 뒤에도 원점부터(재개 없음).
- 누름은 지금 위치에서 시간 누름(``duration``) 한 번, 구동+유지 ≤ `DEV_PRESS_ON_MAX_MS`(펌웨어 상한과 같은 800 ms).
- bring-up 펌웨어(``fw``가 ``-bringup``으로 끝남 — 사람용 방향 시험 명령이 켜진 빌드)에는 보내지 않는다.

거절 판정(비상정지 걸림·콘센트 무응답·모션 연결 전·일반 실행 중)은 실행기가 이 서비스를 부르기 **전에** 한다
(`ActExecutor._dev_refusal`). 답의 ``moved``: ``False``면 움직이기 전 거절(RPi5는 정지를 따로 보내지 않는다),
``None``이면 움직였을 수 있다(RPi5가 정지를 보낸다).
"""

from __future__ import annotations

import logging
import math
import threading

from rpi.controller.kinematics import KinematicsNotConfigured, SoftLimitExceeded, motor_counts_to_xy
from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import (
    MotionAlarm,
    MotionConfigError,
    MotionError,
    MotionPositionMismatch,
    MotionRefused,
    MotionReset,
    MotionStopped,
    MotionTimeout,
    SerialMotionClient,
    StopReport,
)

from ..models.act_messages import DevMotionMsg

log = logging.getLogger(__name__)

#: act_info로 알리는 개발자 조작 규약 판. RPi5는 이 값이 없거나 1 미만이면 보내지 않는다.
#: 2(2026-10-13): ``stop`` 답에 정지 확인 단계 ``stop_level``(sent·mcu_ack·verified)과 ``ack_ms``를 싣는다.
#: 1인 RPi4의 답에는 없다 — RPi5는 그때 ``sent``(보냄)로만 읽는다.
DEV_MOTION_PROTOCOL = 2
#: 조그 한 번의 절대 상한(mm). RPi5가 더 작은 상한(기본 1 mm)을 따로 둔다 — 이것은 RPi4의 마지막 울타리다.
DEV_JOG_STEP_CEILING_MM = 10.0
#: 개발자 누름의 솔레노이드 켜짐 상한(ms) — firmware-motion-corexy SOLENOID_ON_MAX_MS와 같다.
DEV_PRESS_ON_MAX_MS = 800
#: 이 접미사의 펌웨어에는 개발자 조작을 보내지 않는다(firmware-motion-corexy esp32dev_bringup).
BRINGUP_FW_SUFFIX = "-bringup"


class _Refused(Exception):
    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


class DevMotionService:
    """개발자 조작 한 번을 모션 MCU에 넘긴다. `run`은 블로킹(실행기가 작업 스레드에서 부른다), `stop`은 즉시."""

    def __init__(self, client: SerialMotionClient, *, max_step_mm: float = DEV_JOG_STEP_CEILING_MM) -> None:
        if not (math.isfinite(max_step_mm) and 0 < max_step_mm <= DEV_JOG_STEP_CEILING_MM):
            raise ValueError(f"max_step_mm는 0보다 크고 {DEV_JOG_STEP_CEILING_MM:g} 이하여야 해요: {max_step_mm!r}")
        self._client = client
        self._max_step_mm = max_step_mm
        #: 이번 조작 중에 정지가 왔나 — MCU가 대기 명령을 ``stopped``로 끝내면 어댑터는 알람으로 올리는데,
        #: 정지 요청의 결과면 '정지'로 답한다.
        self._stop_seen = threading.Event()

    @property
    def client(self) -> SerialMotionClient:
        return self._client

    def not_ready_reason(self) -> str | None:
        """모션 MCU 연결 확인 전이면 이유(실행기 준비 확인과 같은 문장)."""
        fn = getattr(self._client, "not_ready_reason", None)
        return fn() if callable(fn) else None

    # ── 정지 ────────────────────────────────────────────────────────────────

    def stop(self, reason: str | None = None) -> bool:
        """MCU에 정지를 보낸다(진행 중 조작은 MotionStopped로 끝난다). 정지 줄을 썼으면 True."""
        log.warning("dev motion stop (%s) — sending MCU stop", reason or "unspecified")
        self._stop_seen.set()
        return bool(self._client.request_stop())

    @property
    def last_stop_id(self) -> int | None:
        """마지막으로 보낸 MCU 정지의 id(`SerialMotionClient.last_stop_id`) — 확인을 그 정지에 묶는 데 쓴다."""
        return self._client.last_stop_id

    def confirm_stop(self, stop_id: int | None = None) -> StopReport:
        """``stop_id`` 정지(없으면 마지막 정지)의 확인 단계(블로킹, 짧은 기한 — 실행기가 작업 스레드에서 부른다).
        `SerialMotionClient.confirm_stop`."""
        return self._client.confirm_stop(stop_id=stop_id)

    # ── 조작 ────────────────────────────────────────────────────────────────

    def run(self, msg: DevMotionMsg) -> dict:
        """조작 한 번 → 답 필드(``ok`` 포함). 예외를 밖으로 내지 않는다."""
        self._stop_seen.clear()
        try:
            self._refuse_bringup()
            fields = self._run(msg)
        except _Refused as exc:
            return {"ok": False, "reason": exc.reason, "detail": exc.detail, "moved": False}
        except SoftLimitExceeded as exc:
            return {"ok": False, "reason": "soft_limit", "detail": f"이동 범위 밖이라 움직이지 않았어요: {exc}",
                    "moved": False}
        except (KinematicsNotConfigured, MotionConfigError) as exc:
            return {"ok": False, "reason": "motion_config",
                    "detail": f"RPi4 모션 설정이 비어 있어 움직이지 않았어요: {exc}", "moved": False}
        except MotionRefused as exc:
            return {"ok": False, "reason": exc.code or "refused",
                    "detail": f"움직이기 전에 거절됐어요: {exc}", "moved": False}
        except MotionStopped as exc:
            return {"ok": False, "reason": "stopped", "detail": f"정지 요청으로 멈췄어요: {exc}", "moved": None}
        except MotionReset as exc:
            return {"ok": False, "reason": "motion_reset", "detail": f"모션 보드가 다시 켜졌어요: {exc}",
                    "moved": None}
        except MotionPositionMismatch as exc:
            return {"ok": False, "reason": "position_mismatch", "detail": str(exc), "moved": None}
        except MotionTimeout as exc:
            return {"ok": False, "reason": "motion_timeout", "detail": f"모션 보드 응답이 늦어 멈췄어요: {exc}",
                    "moved": None}
        except MotionAlarm as exc:
            if self._stop_seen.is_set():
                return {"ok": False, "reason": "stopped", "detail": f"정지 요청으로 멈췄어요: {exc}", "moved": None}
            return {"ok": False, "reason": "motion_alarm", "detail": f"모션 보드에서 알람이 왔어요: {exc}",
                    "moved": None}
        except (MotionError, OSError, RuntimeError, ValueError) as exc:
            log.exception("dev motion %s failed", msg.op)
            return {"ok": False, "reason": "motion_error", "detail": f"조작 중 오류가 났어요: {exc}", "moved": None}
        return {"ok": True, **fields}

    def _run(self, msg: DevMotionMsg) -> dict:
        if msg.op == "status":
            return self._position(query=True)
        # 이전 정지 표시는 새 조작 요청이 지운다(일반 실행의 reset_stop과 같다). 정지로 끊긴 이동이면 어댑터 상태가
        # STOPPED라 원점 전으로 남는다 — 아래 원점 검사가 다시 홈을 요구한다(재개 없음).
        if msg.op == "home":
            self._client.reset_stop()
            self._client.home()
            return self._position(query=True)
        if msg.op == "jog":
            return self._jog(msg)
        if msg.op == "press":
            return self._press(msg)
        raise _Refused("bad_args", f"모르는 개발자 조작이에요: {msg.op}")

    def _jog(self, msg: DevMotionMsg) -> dict:
        if msg.axis == "z":
            raise _Refused("z_jog_unsupported", "Z는 솔레노이드라 조그가 없어요 — 누르기로만 움직여요")
        delta = msg.delta_mm
        if msg.axis not in ("x", "y") or delta is None or not math.isfinite(delta) or delta == 0:
            raise _Refused("bad_args", "조그는 x·y 축과 0이 아닌 거리가 필요해요")
        if abs(delta) > self._max_step_mm:
            raise _Refused("step_too_large",
                           f"한 번에 {self._max_step_mm:g} mm까지만 움직여요(요청 {abs(delta):g} mm)")
        self._require_homed("조그")
        self._client.reset_stop()
        x0, y0 = self._current_xy("조그")
        x, y = (x0 + delta, y0) if msg.axis == "x" else (x0, y0 + delta)
        self._client.move_to(x, y)
        return self._position(query=False, fallback=(x, y))

    def _press(self, msg: DevMotionMsg) -> dict:
        config = self._client.config
        if config.press_mode != "duration":
            raise _Refused("press_mode_unsupported",
                           "개발자 누름은 솔레노이드 시간 누름만 해요 — SIMPLELAY_MOTION_PRESS_MODE=duration")
        if config.press_drive_ms is None or config.press_dwell_ms is None:
            raise _Refused("motion_config", "누름 시간 설정(SIMPLELAY_MOTION_PRESS_DRIVE_MS·DWELL_MS)이 비어 있어요")
        on_ms = config.press_drive_ms + config.press_dwell_ms
        if on_ms > DEV_PRESS_ON_MAX_MS:
            raise _Refused("press_too_long",
                           f"솔레노이드 켜짐 {on_ms} ms가 상한 {DEV_PRESS_ON_MAX_MS} ms를 넘어 누르지 않았어요")
        self._require_homed("누름")
        self._client.reset_stop()
        x, y = self._current_xy("누름")
        self._client.press(PressCommand(button=msg.label or "dev", x_mm=x, y_mm=y))
        return self._position(query=False, fallback=(x, y))

    # ── 내부 ────────────────────────────────────────────────────────────────

    def _refuse_bringup(self) -> None:
        info = getattr(self._client, "ready_info", None) or {}
        fw = info.get("fw") if isinstance(info, dict) else None
        if isinstance(fw, str) and fw.endswith(BRINGUP_FW_SUFFIX):
            raise _Refused("bringup_firmware",
                           f"방향 시험용 펌웨어({fw})가 올라가 있어요 — 시연 빌드(esp32dev)를 올린 뒤 써 주세요")

    def _require_homed(self, operation: str) -> None:
        if not self._client.homed:
            raise _Refused("not_homed",
                           f"{operation}: 원점이 확인되지 않았어요(상태 {self._client.state.value}) — 홈을 먼저 눌러 주세요")

    def _current_xy(self, operation: str) -> tuple[float, float]:
        status = self._client.status()
        if status.a_counts is None or status.b_counts is None:
            raise _Refused("position_unknown", f"{operation}: 모션 보드가 위치(A·B 카운트)를 알려 주지 않았어요")
        if not self._client.homed:  # status가 원점 상실(알람·재시작)을 알렸다
            raise _Refused("not_homed", f"{operation}: 원점이 확인되지 않았어요 — 홈을 먼저 눌러 주세요")
        return motor_counts_to_xy(status.a_counts, status.b_counts, self._client.config.kinematics)

    def _position(self, *, query: bool, fallback: tuple[float, float] | None = None) -> dict:
        """답에 싣는 위치·원점 상태. 위치는 MCU 보고값(없으면 목표값), 모르면 None."""
        x = y = None
        if query:
            status = self._client.status()
            if status.a_counts is not None and status.b_counts is not None:
                try:
                    x, y = motor_counts_to_xy(status.a_counts, status.b_counts, self._client.config.kinematics)
                except KinematicsNotConfigured:
                    pass
        else:
            last = self._client.last_position
            if last is not None and last.get("x_mm") is not None:
                x, y = last["x_mm"], last["y_mm"]
            elif fallback is not None:
                x, y = fallback
        return {"homed": self._client.homed,
                "x_mm": round(x, 3) if x is not None else None,
                "y_mm": round(y, 3) if y is not None else None}
