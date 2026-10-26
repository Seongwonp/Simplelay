"""LG 앱·리모컨·가전 버튼으로 직접 바꾼 상태도 '직접 사용'으로 기록(2026-10-26, 심사 추천 ④).

ThinQ 클라이언트에는 푸시가 없다(:mod:`.client`) — **새로 클라우드를 부르지 않는다.** 이미 도는 공기질 판독
(:mod:`rpi.api.air_quality_wiring`, 기본 120초)이 읽은 상태를 넘겨받아 바로 앞 판독과 견준다.

- **비교 칸·목적 문장은 대응표(``bindings``) 그대로다.** 동작(capability)이 쓰는 칸을 읽고, 바뀐 새 값이 대응표의 목적
  문장(예: ``set_power POWER_ON`` → '공기청정기 켜줘')과 동작·인자가 똑같을 때만 기록한다. 대응표에 없는 변화(운전 모드,
  바람 세기 '중' 등)는 기록하지 않는다(뜻을 짐작하지 않는다). 그래서 습관 판단(``PatternDetector``)·루틴 초안
  (``rpi/routines/candidates.py``)이 바뀌지 않고 그대로 쓴다.
- 가전 종류는 :data:`MANUAL_USE_DEVICE_TYPES`(공기청정기)만 — 낮은 위험 동작만 있는 표다.
- 꺼진 채 바뀐 전원 밖 칸(바람 세기)은 쓰지 않는다 — 꺼져 있으면 마지막 설정일 뿐이다(``AirReading.wind_is_strong``과 같은 생각).
- **우리가 바꾼 것은 세지 않는다.** SimpleLay가 그 가전에 명령을 보낸 시각(시작·끝, 직접 명령·루틴·자동 실행·제안 승인 모두
  ``ThinqController.execute_command`` 하나를 지난다)이 바로 앞 판독 뒤이거나 :data:`SELF_CHANGE_WINDOW_SECONDS` 안이면 이번
  변화는 기록하지 않는다(그래도 비교 기준은 새 값으로 옮긴다). 그 사이 사람이 바꾼 것도 함께 빠진다 — 두 번 세는 것보다 낫다.
- 기동 뒤 첫 판독은 기준만 잡는다(기록 없음). 판독 실패·빈 상태는 기준을 지우지도, 기록을 만들지도 않는다(모르는 칸은
  앞 값을 그대로 둔다).
- 기록 시각은 **변화를 본 판독 시각**이다. 실제로 바꾼 때는 바로 앞 판독과 이번 판독 사이 어딘가다(최대 판독 주기만큼 늦다).
- 실행 환경은 그 가전의 값(``execution_mode_for`` — 연습 기기는 MOCK)이 REAL일 때만 REAL, 나머지는 MOCK이다. 습관 판단은
  REAL만 쓰므로 모의·모의 클라우드 기록은 습관 근거가 되지 않는다.
- 사용 기록에는 '앱에서 바꿈' 같은 표시 칸이 없다(``UsageRecord``·저장 표에 칸을 늘리지 않았다). 기록만으로는 SimpleLay에서
  한 직접 사용과 구분되지 않는다 — 로그에만 남긴다.

이 클래스는 기억만 한다(입출력은 넘겨받은 사용 기록 ``append`` 하나). 판독 스레드·실행 스레드가 함께 부르므로 잠근다.
"""

from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from datetime import datetime
from typing import Any

from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageOutcome, UsageRecord, UsageSource

from .bindings import AIR_PURIFIER_DEVICE_TYPE
from .profile import read_state

log = logging.getLogger(__name__)

#: SimpleLay가 명령을 보낸 뒤 이 시간 안에 본 변화는 우리가 바꾼 것으로 친다(**추측/측정 필요** — 실제 클라우드 상태가
#: 늦게 바뀌는 시간을 재지 않았다. 판독 주기 기본 120초의 다섯 배로 넉넉히 둔다).
SELF_CHANGE_WINDOW_SECONDS = 10 * 60.0
#: 앱·리모컨 변화를 기록할 가전 종류(대응표가 낮은 위험 동작뿐인 것).
MANUAL_USE_DEVICE_TYPES = (AIR_PURIFIER_DEVICE_TYPE,)

_POWER_ACTION = "set_power"
_POWER_OFF = "POWER_OFF"


def _values(binding: Any, state: Any) -> dict[str, str]:
    """동작 이름 → 지금 값(문자열만). 대응표 동작이 쓰는 칸을 앞 칸부터 읽는다(:func:`.power.power_of`와 같은 규칙)."""
    out: dict[str, str] = {}
    for cap in getattr(binding, "capabilities", ()):
        for key in cap.keys:
            value = read_state(state, cap.resource, key, location=cap.location)
            if value is not None:
                if isinstance(value, str):
                    out[cap.action] = value
                break
    return out


def _purpose(binding: Any, action: str, value: str) -> str | None:
    """대응표에서 동작·인자가 똑같은 목적 문장. 없으면 None."""
    for fn in getattr(binding, "functions", ()):
        args = dict(fn.args)
        if fn.action == action and len(args) == 1 and next(iter(args.values())) == value:
            return fn.purpose
    return None


class ThinqManualUseTracker:
    """가전 ID → (마지막 판독 값들, 판독 시각)과 SimpleLay 명령 시각. 스레드 안전."""

    def __init__(self, *, monotonic: Callable[[], float] | None = None,
                 self_window_s: float = SELF_CHANGE_WINDOW_SECONDS) -> None:
        self._monotonic = monotonic or time.monotonic
        self._self_window_s = self_window_s
        self._lock = threading.Lock()
        self._last: dict[str, tuple[dict[str, str], float]] = {}
        self._commanded_at: dict[str, float] = {}

    def note_command(self, appliance_id: str | None) -> None:
        """SimpleLay가 이 가전에 명령을 보내기 시작했다·끝냈다(실행기가 부른다). 입출력 없음."""
        if not appliance_id:
            return
        with self._lock:
            self._commanded_at[appliance_id] = self._monotonic()

    def clear(self) -> None:
        with self._lock:
            self._last.clear()
            self._commanded_at.clear()

    def observe_read(self, appliance_id: str, binding: Any, state: Any, *, execution_mode: ExecutionMode,
                     usage_log: Any, now: datetime) -> tuple[UsageRecord, ...]:
        """판독 한 번(성공한 것만 넘긴다). 바깥에서 바꾼 대응표 동작이면 사용 기록에 남기고 그 기록들을 돌려준다."""
        if binding is None or getattr(binding, "device_type", None) not in MANUAL_USE_DEVICE_TYPES:
            return ()
        values = _values(binding, state)
        if not values:
            return ()  # 빈 판독 — 기준을 건드리지 않는다
        with self._lock:
            read_at = self._monotonic()
            prev = self._last.get(appliance_id)
            merged = {**(prev[0] if prev else {}), **values}
            self._last[appliance_id] = (merged, read_at)
            if prev is None:
                return ()  # 첫 판독은 기준만
            before, prev_read_at = prev
            commanded = self._commanded_at.get(appliance_id)
        changes = [(action, value) for action, value in values.items()
                   if action in before and before[action] != value]
        if not changes:
            return ()
        if commanded is not None and (commanded >= prev_read_at or read_at - commanded < self._self_window_s):
            log.info("thinq change on %s right after our command — not counted as manual use", appliance_id)
            return ()
        power_off = values.get(_POWER_ACTION) == _POWER_OFF
        mode = ExecutionMode.REAL if execution_mode is ExecutionMode.REAL else ExecutionMode.MOCK
        records = []
        for action, value in changes:
            if power_off and action != _POWER_ACTION:
                continue  # 꺼진 채 바뀐 설정 칸은 마지막 설정일 뿐이다
            purpose = _purpose(binding, action, value)
            if purpose is None:
                continue  # 대응표에 없는 변화는 짐작하지 않는다
            records.append(UsageRecord(now, purpose, UsageOutcome.SUCCEEDED, appliance_id=appliance_id,
                                       execution_mode=mode, source=UsageSource.DIRECT))
        appended = []
        for record in records:
            try:
                usage_log.append(record)
            except Exception:  # noqa: BLE001 -- 기록 실패가 판독을 막지 않는다
                log.exception("manual use append failed")
                continue
            appended.append(record)
        if appended:
            log.info("thinq manual use on %s: %d record(s), mode=%s (changed between reads)",
                     appliance_id, len(appended), mode.value)
        return tuple(appended)


__all__ = ["MANUAL_USE_DEVICE_TYPES", "SELF_CHANGE_WINDOW_SECONDS", "ThinqManualUseTracker"]
