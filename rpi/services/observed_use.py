"""앱·키오스크를 거치지 않은 사용을 CT 전력으로 안다 — 끝 이벤트 → 사용 기록 + "가열이 끝났어요" 알림.

**실행 근거가 아니다.** 여기서는 사용 기록과 알림만 남긴다. 기록의 ``source``는 ``observed_power``라 습관 카드·루틴
초안·자동 실행이 보지 않고(`PatternDetector`는 ``direct``만 근거로 쓴다) '알게 된 것'에 시간대와 평균 시간으로 보이기만 한다.
전자레인지 같은 열 나는 가전을 습관 때문에 묻거나 맡기는 길을 만들지 않기 위해서다.

CT는 어떤 버튼·메뉴를 눌렀는지 모른다. 그래서 목적 문장은 가전 종류 하나뿐이고, 취소·문 열림으로 멈춘 가열도 같게 보인다
(문구는 '가열이 끝났어요'까지만 — 조리가 끝났다고 말하지 않는다).

남기지 않는 경우:

- 실물이 아닌 입력(``source`` mock·injected) — 가짜 기록을 만들지 않는다.
- 전력 근거가 없거나(종료음만) 운전 중 끊김(``gaps``)이 있었던 끝 — 시작·길이를 다 보지 못했다. 알림도 내지 않는다.
- 세트를 다른 종류의 가전에 옮겨 묶은 경우 — 그 CT의 끝을 전자레인지로 말하지 않는다.
- 같은 사건을 다시 받은 경우.
- 앱·키오스크 실행과 겹치는 경우 — 사용 기록만 뺀다(그 실행이 이미 남겼다). 알림은 낸다. 가열은 누름 작업이 끝난 뒤에도 이어지므로
  앞뒤로 :data:`JOB_MARGIN_S`를 둔다. 겹치는 손 사용까지 빠지지만 두 번 세는 것보다 낫다.

가전 ID: RPi4는 CT 채널의 역할을 ``SIMPLELAY_DONE_WATCH``의 고정 이름(``microwave``)으로 보낸다. 사용자가 추가한 가전의 ID는
RPi4가 알 수 없으므로, 사람이 세트를 묶어 둔 가전이 있으면 그 가전으로 옮겨 적는다(`observed_target`). 루틴·규칙에는 프레임의 ID가
그대로 간다.

시각: RPi4 표본 시각은 프레임 안에서만 뺀다(같은 단조 시계) — 끝을 보낸 때부터 시작까지의 나이를 허브 현재 시각에서 뺀다.
"""

from __future__ import annotations

import logging
import math
import threading
from collections import deque
from collections.abc import Callable, Mapping
from datetime import datetime, timedelta

from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageOutcome, UsageRecord, UsageSource
from rpi.services.appliance_registry import ApplianceCategory
from rpi.services.care_events import KIND_HEAT_DONE

log = logging.getLogger(__name__)

HEAT_EVENT = "heat_complete"
#: 사용 기록의 목적 문장 — CT는 메뉴를 모르므로 가전 종류까지만 말한다.
OBSERVED_PURPOSE = "전자레인지 사용"
HEAT_DONE_MESSAGE = "가열이 끝났어요"
#: 실행과 겹친다고 보는 앞뒤 여유(초). **추측/측정 필요** — 누름 작업이 끝난 뒤 가열이 시작되기까지의 시간.
JOB_MARGIN_S = 15.0
#: 겹침을 볼 최근 실행 수.
_RECENT_JOBS = 50
#: 같은 사건을 가릴 기억 수.
_RECENT_EVENTS = 32
#: 세트에 묶인 가전이 이 종류일 때만 전자레인지 CT로 본다. 종류를 고르지 않은 사용자 가전(기타)은 사람이 묶은 것을 믿는다.
_HEAT_CATEGORIES = (ApplianceCategory.MICROWAVE, ApplianceCategory.OTHER)


def _finite(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _is_microwave(record: Mapping, registry) -> bool:
    if record.get("event") == HEAT_EVENT:
        return True
    appliance = registry.get(record.get("appliance_id"))
    return appliance is not None and appliance.category is ApplianceCategory.MICROWAVE


def observed_target(frame_id: str, service, registry) -> str | None:
    """끝 프레임의 가전 ID → 기록에 쓸 가전 ID. 세트가 묶인 가전이 있으면 그 가전, 사람이 묶지 않았으면(env 구성) 프레임 값.
    세트가 비었거나 전자레인지가 아닌 가전에 묶여 있으면 None(이 CT의 끝을 전자레인지로 말하지 않는다)."""
    bound = service.kit_bound(service.kit_id())
    if not bound.explicit:
        return frame_id
    appliance = registry.get(bound.appliance_id) if bound.appliance_id else None
    if appliance is None or appliance.category not in _HEAT_CATEGORIES:
        return None
    return appliance.appliance_id


class ObservedUses:
    """``usage_log``·``care_events``·``service``·``registry``·``jobs``는 꺼내 쓰는 함수다(지연 생성·시험 재설정)."""

    def __init__(self, *, usage_log: Callable, care_events: Callable, clock, service: Callable, registry: Callable,
                 jobs: Callable) -> None:
        self._usage_log = usage_log
        self._care_events = care_events
        self._clock = clock
        self._service = service
        self._registry = registry
        self._jobs = jobs
        self._lock = threading.Lock()
        self._seen: deque[tuple] = deque(maxlen=_RECENT_EVENTS)

    def on_done(self, record: Mapping) -> str:
        """검증한 ``appliance_done`` 기록 하나. 어떻게 처리했는지 한 낱말로 돌려준다(``recorded``가 아니면 사용 기록 없음)."""
        registry = self._registry()
        if record.get("source") != "real":
            return "not_real"
        if not _is_microwave(record, registry):
            return "not_microwave"
        span = _run_span(record)
        if span is None:
            log.info("heat end without a whole power run — not recorded: %s", record.get("appliance_id"))
            return "no_power_run"
        age_s, run_s = span
        service = self._service()
        target = observed_target(record["appliance_id"], service, registry)
        if target is None:
            log.warning("heat end on a kit not bound to a microwave — ignored: %s", record.get("appliance_id"))
            return "not_bound"
        key = (record.get("clock_id"), record["appliance_id"], record["evidence"]["power"].get("started_at_s"))
        with self._lock:
            if key in self._seen:
                return "duplicate"
            self._seen.append(key)
        started = self._clock.now() - timedelta(seconds=age_s)
        self._notify()
        ids = {record["appliance_id"], target}
        if self._overlaps_job(service, ids, started, started + timedelta(seconds=run_s)):
            log.info("heat on %s overlaps a job — not counted again", target)
            return "job_overlap"
        self._usage_log().append(UsageRecord(started, OBSERVED_PURPOSE, UsageOutcome.SUCCEEDED, appliance_id=target,
                                             execution_mode=ExecutionMode.REAL, source=UsageSource.OBSERVED_POWER,
                                             duration_s=round(run_s, 1)))
        return "recorded"

    def _notify(self) -> None:
        try:
            self._care_events().append(KIND_HEAT_DONE, HEAT_DONE_MESSAGE)
        except Exception:  # noqa: BLE001 -- 알림 실패가 사용 기록을 막지 않는다
            log.exception("heat done notice failed")

    def _overlaps_job(self, service, ids: set, started: datetime, ended: datetime) -> bool:
        snapshot = service.status()
        if snapshot.running and snapshot.appliance_id in ids:
            return True
        margin = timedelta(seconds=JOB_MARGIN_S)
        for entry in self._jobs().recent(_RECENT_JOBS):
            if entry.appliance_id not in ids:
                continue
            job_start = entry.started_at or entry.finished_at
            if job_start - margin <= ended and started <= entry.finished_at + margin:
                return True
        return False


def _run_span(record: Mapping) -> tuple[float, float] | None:
    """(시작부터 프레임을 낸 때까지의 나이 초, 가동 초). 끝까지 다 본 전력 사이클이 아니면 None."""
    if "power" not in record.get("inputs", ()):
        return None
    power = (record.get("evidence") or {}).get("power")
    if not isinstance(power, Mapping):
        return None
    started, done, run_s, gaps = (power.get(name) for name in ("started_at_s", "done_at_s", "run_s", "gaps"))
    if not (_finite(started) and _finite(done) and _finite(run_s)) or run_s <= 0 or done < started:
        return None
    if gaps is not None and not (_finite(gaps) and gaps == 0):
        return None
    sent_ns = record.get("t_monotonic_ns")
    sent = sent_ns / 1e9 if _finite(sent_ns) else done
    return max(sent, done) - started, float(run_s)


__all__ = ["HEAT_DONE_MESSAGE", "JOB_MARGIN_S", "OBSERVED_PURPOSE", "ObservedUses", "observed_target"]
