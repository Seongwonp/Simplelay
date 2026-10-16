"""실행 중 RPi5→RPi4 생존 신호 — 링크 생존 신호 규약 1(2026-10-16, 안전 보고 G5). docs/protocol.md '실행 중 생존 신호'.

Wi-Fi가 조용히 끊기면(FIN 없음) 두 보드 모두 TCP keepalive(약 11 s 추정)가 알아챌 때까지 모른다. 그동안 RPi4는 RPi5의
정지를 받을 길이 없는데도 남은 버튼을 눌렀다. 규약:

- RPi4는 ``act_info``에 ``heartbeat_protocol: 1``과 자기 제한 시간 ``heartbeat_timeout_s``를 알린다.
- 그것을 본 RPi5만 ``execute``에 ``heartbeat_s``(보내는 주기)를 싣고, 그 실행의 결과를 받을 때까지 ``heartbeat
  {sequence_id}``를 그 주기로 보낸다(링크 이벤트 루프의 작업 — 공용 스레드 풀·정지 경로와 무관하다).
- RPi4는 ``heartbeat_s``가 실린 실행에서만, 인증된 줄(어떤 종류든)이 ``max(제한 시간, 주기 × 3)`` 넘게 오지 않으면 받은 정지와
  같은 길로 멈추고 결과를 ``safety_stop``·``abort_reason: motion_link_lost``로 적는다. 다음 ``act_info``에 ``last_link_stop``을
  한 번 싣는다 — RPi5는 다시 이은 뒤 보호자 알림으로 남긴다.
- 옛 RPi5(``heartbeat_s`` 없음)·쉬는 중에는 요구하지 않는다. 옛 RPi4(알림 없음)에는 보내지 않는다. RPi4·RPi5는 같은 커밋으로
  배포한다(``run_ref``와 같은 규칙).

주기 1 s·제한 시간 3 s는 **추측값이다(측정 필요)** — 핫스팟 Wi-Fi의 실제 지연 분포를 재지 않았다. 너무 짧으면 멀쩡한 실행이
'연결 끊김으로 멈춤'이 되고(안전 쪽 실패), 너무 길면 끊긴 뒤 더 누른다.
"""

from __future__ import annotations

import logging
import math
import os
from collections import deque
from collections.abc import Callable

log = logging.getLogger(__name__)

#: ``act_info.heartbeat_protocol`` 값.
HEARTBEAT_PROTOCOL = 1
#: RPi5 — 실행 중 생존 신호 주기(초).
PERIOD_ENV = "SIMPLELAY_LINK_HEARTBEAT_S"
DEFAULT_PERIOD_S = 1.0
PERIOD_RANGE = (0.2, 5.0)
#: RPi4 — 마지막 줄 뒤 이만큼 조용하면 스스로 멈춘다(초).
TIMEOUT_ENV = "SIMPLELAY_LINK_HEARTBEAT_TIMEOUT_S"
DEFAULT_TIMEOUT_S = 3.0
TIMEOUT_RANGE = (1.0, 30.0)
#: 제한 시간은 적어도 주기의 이 배수 — 생존 신호 두 번을 놓친 것으로는 멈추지 않는다.
MIN_MISSED_PERIODS = 3
#: RPi4가 받아들이는 주기 상한(초). 넘거나 모양이 틀리면 '주기 없음'(옛 RPi5와 같다).
MAX_DECLARED_PERIOD_S = 10.0
#: RPi4가 생존 신호를 잃고 멈춘 결과의 ``abort_reason``. ``motion_…`` 모양이라 옛 RPi5·폰·키오스크도 받는다.
LINK_LOST_ABORT_REASON = "motion_link_lost"


def _ranged_env(name: str, default: float, low: float, high: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        log.warning("%s=%r is not a number — using %s", name, raw, default)
        return default
    if not math.isfinite(value) or not low <= value <= high:
        log.warning("%s=%r is outside %s..%s — using %s", name, raw, low, high, default)
        return default
    return value


def period_from_env() -> float:
    """RPi5 생존 신호 주기. 끌 수는 없다(범위 밖·이상한 값은 기본값)."""
    return _ranged_env(PERIOD_ENV, DEFAULT_PERIOD_S, *PERIOD_RANGE)


def timeout_from_env() -> float:
    """RPi4 제한 시간. 범위 밖·이상한 값은 기본값."""
    return _ranged_env(TIMEOUT_ENV, DEFAULT_TIMEOUT_S, *TIMEOUT_RANGE)


def parse_declared_period(value: object) -> float | None:
    """``execute.heartbeat_s`` — 0 초과 ``MAX_DECLARED_PERIOD_S`` 이하의 유한한 수만. 아니면 None(감시하지 않음)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    if not math.isfinite(value) or not 0 < value <= MAX_DECLARED_PERIOD_S:
        return None
    return value


def effective_timeout(declared_period: float, configured: float) -> float:
    return max(configured, MIN_MISSED_PERIODS * declared_period)


def supports_heartbeat(act_info: dict | None) -> bool:
    protocol = (act_info or {}).get("heartbeat_protocol")
    return isinstance(protocol, int) and not isinstance(protocol, bool) and protocol >= HEARTBEAT_PROTOCOL


def parse_link_stop(doc: object) -> dict | None:
    """``act_info.last_link_stop`` — 모양이 맞을 때만(문자열 ``sequence_id``, 0 이상 정수 ``pressed`` ≤ ``total``)."""
    if not isinstance(doc, dict):
        return None
    seq, pressed, total = doc.get("sequence_id"), doc.get("pressed"), doc.get("total")
    if not isinstance(seq, str) or not 0 < len(seq) <= 128:
        return None
    for n in (pressed, total):
        if isinstance(n, bool) or not isinstance(n, int) or n < 0:
            return None
    if pressed > total:
        return None
    return {"sequence_id": seq, "pressed": pressed, "total": total,
            "run_ref": doc.get("run_ref") if isinstance(doc.get("run_ref"), str) else None,
            "outcome": doc.get("outcome") if isinstance(doc.get("outcome"), str) else None}


def link_stop_message(stop: dict) -> str:
    """보호자 알림 문장. 확인된 누름 수만 말한다 — 멈출 때 누르던 버튼은 눌렸는지 모른다."""
    return (f"실행 중 가전과 연결이 끊겨 누름 장치가 스스로 멈췄어요 — 확인된 누름은 버튼 {stop['total']}개 중 "
            f"{stop['pressed']}개예요. 가전을 직접 확인해 주세요(자동으로 다시 누르지 않아요).")


class LinkStopNotices:
    """RPi4가 다시 이은 뒤 알린 ``last_link_stop``을 보호자 알림 한 건으로 남긴다(같은 실행은 한 번만).

    ``care_events``는 알림 저장소를 돌려주는 함수(없으면 None) — 읽기 루프에서 불리므로 예외를 내지 않는다."""

    def __init__(self, care_events: "Callable[[], object | None]") -> None:
        self._care_events = care_events
        self._seen: deque[str] = deque(maxlen=32)

    def receive(self, info: object) -> bool:
        stop = parse_link_stop(info.get("last_link_stop") if isinstance(info, dict) else None)
        if stop is None or stop["sequence_id"] in self._seen:
            return False
        self._seen.append(stop["sequence_id"])
        log.warning("RPi4 stopped run %s by itself after losing the link (pressed %d/%d)",
                    stop["sequence_id"], stop["pressed"], stop["total"])
        try:
            store = self._care_events()
            if store is None:
                return False
            store.append("execution_failed", link_stop_message(stop))  # type: ignore[attr-defined]
        except Exception:  # noqa: BLE001 - 알림 기록 고장이 링크 읽기를 막지 않는다
            log.exception("link stop care event record failed")
            return False
        return True
