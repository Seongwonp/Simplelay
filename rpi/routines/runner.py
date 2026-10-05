"""승인된 루틴 실행 — 기존 명령 실행(시나리오 엔진과 같은 규칙) 위의 얇은 순서기.

진입점은 **제안 승인뿐이다.** 제안 서비스가 ``routine:`` 카드를 승인하면
``submit_approved``/``execute_approved``를 부른다(``ApprovedCommand`` 없이는 부를 방법이
없다). 여기서 하는 일:

1. 카드의 ``scenario_id``에 적힌 단계 지문과 지금 루틴의 지문을 대조한다. 다르거나
   루틴이 꺼졌거나 '알림만'으로 바뀌었으면 ``ApprovalMismatchError``(재승인).
2. 단계를 구간으로 나눈다: 이어진 장치 단계는 한 번의 ``execute_approved``(다가전
   시나리오와 같은 게이트 · 앞 단계가 확인되지 않으면 뒤 단계를 보내지 않음 · 정지
   요청이면 남은 단계 미전송). ``announce``는 알림 기록, ``wait_until_done``은 앞 결과의
   확인 수준을 본다.
3. 첫 구간은 호출 스레드에서 **제출**한다 -- 바쁨(409)·준비 안 됨(412) 같은 거절이 그대로
   승인 응답으로 올라가고, 제안 서비스가 카드를 되돌린다. 나머지는 백그라운드에서 이어간다.

``wait_until_done`` 판정(실물 미검증, 2026-10-06 갭 M2):
- 그 가전의 마지막 결과가 성공이고 ``operation_confirmed``(L3) 또는 ``state_confirmed``여야 한다(시작 확인).
- **끝 센서가 있는 가전**(``SIMPLELAY_ROUTINE_DONE_SENSORS``, RPi4 ``SIMPLELAY_DONE_WATCH``와 맞춘다)이면 그 위에서
  RPi4가 그 가전의 CT 채널 전력 하강(`rpi/verifier/cycle_end.py`)으로 보내는 ``appliance_done``을 기다린다 --
  구간을 보내기 전에 잡은 표(`ApplianceDoneLog.mark`) 뒤에 온 것만, ``SIMPLELAY_ROUTINE_DONE_TIMEOUT_S``(기본 1200,
  측정 필요)까지. 오면 통과(``basis: cycle_end``), 안 오면 루틴을 멈추고 알림함에 남긴다. 정지 요청이면 멈춤.
- 끝 센서가 없으면 시작 확인으로 통과하되 단계에 **"시작만 확인 — 끝남 판정 센서 없음"**(``basis: start_only``).
- 모의 실행(``mock``)의 성공은 센서가 있어도 기다리지 않고 **시연 통과**로 적는다(``basis: mock``).
- 그 밖(L1 눌림만·보고만·미확인·실패)은 루틴을 멈추고 보호자 알림함에 남긴다.

이어지는 구간의 승인: 첫 구간을 제출할 때 카드의 유효 시간·상황 재검사를 통과했다.
뒤 구간은 **같은 승인의 연속**이라 카드 유효 시간(15분)으로 끊지 않는다(세탁처럼 긴
대기). 명령 지문 대조와 실행 직전 재검사(대상·경로·동작 범위·준비 상태)는 그대로 한다.
"""

from __future__ import annotations

import logging
import math
import os
import re
import threading
import time
from collections import deque
from dataclasses import dataclass, field, replace
from datetime import datetime
from enum import Enum

from rpi.commands import ApprovalMismatchError, ApprovedCommand, CommandStatus
from rpi.controller.models import ExecutionMode

from .model import Routine, parse_scenario_key

log = logging.getLogger(__name__)

KIND_ROUTINE_ANNOUNCE = "routine_announce"
KIND_ROUTINE_STOPPED = "routine_stopped"

#: 끝 센서(RPi4 사이클 끝 판정)가 있는 가전 ID 목록(쉼표). RPi4 ``SIMPLELAY_DONE_WATCH``의 가전과 맞춘다.
DONE_SENSORS_ENV = "SIMPLELAY_ROUTINE_DONE_SENSORS"
#: ``wait_until_done``이 사이클 끝을 기다리는 상한(초). 기본 20분 — 측정 필요(가열 시간 + 대기 확인 시간).
DONE_TIMEOUT_ENV = "SIMPLELAY_ROUTINE_DONE_TIMEOUT_S"
DEFAULT_DONE_TIMEOUT_S = 1200.0
START_ONLY_DETAIL = "시작만 확인 — 끝남 판정 센서 없음"
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


def routine_done_settings_from_env(env=None) -> tuple[frozenset, float]:
    """(끝 센서가 있는 가전, 기다림 상한 초). 잘못된 값은 RuntimeError(기동 거절)."""
    src = os.environ if env is None else env
    names = [n.strip() for n in (src.get(DONE_SENSORS_ENV) or "").split(",") if n.strip()]
    if any(not _ID.fullmatch(n) for n in names):
        raise RuntimeError(f"{DONE_SENSORS_ENV}는 쉼표로 나눈 가전 ID입니다: {src.get(DONE_SENSORS_ENV)!r}")
    raw = (src.get(DONE_TIMEOUT_ENV) or "").strip()
    try:
        timeout = float(raw) if raw else DEFAULT_DONE_TIMEOUT_S
    except ValueError as exc:
        raise RuntimeError(f"{DONE_TIMEOUT_ENV} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not (math.isfinite(timeout) and timeout > 0):
        raise RuntimeError(f"{DONE_TIMEOUT_ENV}는 0보다 커야 합니다: {raw!r}")
    return frozenset(names), timeout


class RunStatus(str, Enum):
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    STOPPED = "stopped"
    UNCONFIRMED = "unconfirmed"


_FROM_COMMAND = {
    CommandStatus.SUCCEEDED: RunStatus.SUCCEEDED,
    CommandStatus.FAILED: RunStatus.FAILED,
    CommandStatus.STOPPED: RunStatus.STOPPED,
    CommandStatus.UNCONFIRMED: RunStatus.UNCONFIRMED,
}


@dataclass
class RoutineRun:
    run_id: str
    routine_id: str
    routine_name: str
    scenario_id: str
    started_at: datetime
    status: RunStatus = RunStatus.RUNNING
    finished_at: datetime | None = None
    detail: str = ""
    is_demo: bool = False
    job_ids: list = field(default_factory=list)
    steps: list = field(default_factory=list)
    results: list = field(default_factory=list)
    cancel: threading.Event = field(default_factory=threading.Event)
    active: bool = False
    #: 마지막 장치 구간을 보내기 전의 가전 끝 기록 표(`ApplianceDoneLog.mark`). 이 뒤에 온 끝만 센다.
    done_mark: int = 0

    def as_dict(self) -> dict:
        return {
            "run_id": self.run_id,
            "routine_id": self.routine_id,
            "routine_name": self.routine_name,
            "status": self.status.value,
            "detail": self.detail,
            "is_demo": self.is_demo,
            "started_at": self.started_at.isoformat(),
            "finished_at": self.finished_at.isoformat() if self.finished_at else None,
            "job_ids": list(self.job_ids),
            "steps": list(self.steps),
        }


class RoutineRunner:
    def __init__(self, store, service, clock, care_events=None, *, on_finished=None,
                 poll_seconds: float = 0.05, sleep=time.sleep,
                 job_timeout_seconds: float = 3 * 3600, idle_timeout_seconds: float = 60.0,
                 done_log=None, done_sensors: frozenset = frozenset(),
                 done_timeout_seconds: float = DEFAULT_DONE_TIMEOUT_S) -> None:
        self._store = store
        self._service = service
        self._clock = clock
        self._care = care_events
        self._on_finished = on_finished
        self._poll = poll_seconds
        self._sleep = sleep
        self._job_timeout = job_timeout_seconds
        self._idle_timeout = idle_timeout_seconds
        #: 가전 끝 기록(`rpi.services.appliance_done.ApplianceDoneLog`)·끝 센서가 있는 가전·기다림 상한(M2).
        self._done_log = done_log
        self._done_sensors = frozenset(done_sensors)
        self._done_timeout = done_timeout_seconds
        self._lock = threading.Lock()
        self._runs: deque[RoutineRun] = deque(maxlen=20)

    # ── 제안 서비스가 부르는 곳 ─────────────────────────────────────────────
    @staticmethod
    def handles(scenario_id: str | None) -> bool:
        return parse_scenario_key(scenario_id) is not None

    def submit_approved(self, approved, *, purpose=None, usage_source=None,
                        approval_guard=None, scenario_id=None) -> str:
        routine, items = self._plan(scenario_id, approved)
        leading, first, rest = self._split(items)
        kwargs = self._kwargs(purpose, usage_source)
        mark = self._done_mark()
        job_id = self._service.submit_approved(tuple(first), approval_guard=approval_guard,
                                               scenario_id=scenario_id, **kwargs)
        run = self._start(routine, scenario_id, job_id)
        run.done_mark = mark
        for text in leading:
            self._announce(run, routine, text)
        thread = threading.Thread(target=self._continue_safely,
                                  args=(run, routine, rest, job_id, None, scenario_id, kwargs),
                                  daemon=True, name=f"simplelay-routine-{job_id}")
        thread.start()
        return job_id

    def execute_approved(self, approved, *, purpose=None, usage_source=None,
                         approval_guard=None, scenario_id=None) -> RoutineRun:
        routine, items = self._plan(scenario_id, approved)
        leading, first, rest = self._split(items)
        kwargs = self._kwargs(purpose, usage_source)
        mark = self._done_mark()
        record = self._service.execute_approved(tuple(first), approval_guard=approval_guard,
                                                scenario_id=scenario_id, **kwargs)
        run = self._start(routine, scenario_id, record.job_id)
        run.done_mark = mark
        for text in leading:
            self._announce(run, routine, text)
        self._continue_safely(run, routine, rest, record.job_id, record, scenario_id, kwargs)
        return run

    # ── 조회·정지 ─────────────────────────────────────────────────────────
    def runs(self) -> tuple[RoutineRun, ...]:
        with self._lock:
            return tuple(reversed(self._runs))

    def get(self, run_id: str) -> RoutineRun | None:
        with self._lock:
            return next((r for r in self._runs if r.run_id == run_id), None)

    def stop(self, run_id: str) -> bool:
        """남은 단계를 보내지 않는다. 지금 실행 중인 구간이 있으면 긴급 정지도 보낸다."""
        run = self.get(run_id)
        if run is None or run.status is not RunStatus.RUNNING:
            return False
        run.cancel.set()
        if run.active and self._service.status().running:
            self._service.emergency_stop_report()
        return True

    # ── 내부 ──────────────────────────────────────────────────────────────
    def _plan(self, scenario_id, approved) -> tuple[Routine, list]:
        key = parse_scenario_key(scenario_id)
        routine = self._store.get(key[0]) if key else None
        if (routine is None or not routine.enabled or routine.mode != "approve"
                or routine.steps_fingerprint()[:12] != key[1]):
            raise ApprovalMismatchError("루틴이 바뀌었거나 꺼졌어요")
        if not all(isinstance(a, ApprovedCommand) for a in approved):
            # 승인 원장 밖의 명령은 받지 않는다 -- 이 순서기로 가는 길은 카드 승인뿐이다.
            raise ApprovalMismatchError("승인된 명령이 아니에요")
        device = routine.device_steps
        if len(device) != len(approved):
            raise ApprovalMismatchError("루틴 단계 수가 승인과 달라요")
        items: list = []
        index = 0
        for step in routine.steps:
            if step.is_device_step:
                entry = approved[index]
                index += 1
                if entry.command.target_id != step.appliance_id:
                    raise ApprovalMismatchError("루틴 단계의 가전이 승인과 달라요")
                if items and items[-1][0] == "commands":
                    items[-1][1].append(entry)
                else:
                    items.append(("commands", [entry]))
            elif step.kind == "announce":
                items.append(("announce", step.text))
            else:
                items.append(("wait", step.appliance_id))
        return routine, items

    @staticmethod
    def _split(items):
        leading = []
        items = list(items)
        while items and items[0][0] == "announce":
            leading.append(items.pop(0)[1])
        first = items.pop(0)  # 모델 검증: 승인 루틴에는 장치 단계가 있고 wait는 그 뒤다
        return leading, first[1], items

    @staticmethod
    def _kwargs(purpose, usage_source) -> dict:
        kwargs = {"purpose": purpose}
        if usage_source is not None:
            kwargs["usage_source"] = usage_source
        return kwargs

    def _start(self, routine: Routine, scenario_id: str, job_id: str) -> RoutineRun:
        run = RoutineRun(run_id=job_id, routine_id=routine.routine_id, routine_name=routine.name,
                         scenario_id=scenario_id, started_at=self._clock.now(), job_ids=[job_id],
                         active=True)
        with self._lock:
            self._runs.append(run)
        return run

    def _continue_safely(self, *args) -> None:
        run = args[0]
        try:
            self._continue(*args)
        except Exception:  # noqa: BLE001 -- 순서기 예외가 스레드를 조용히 죽이지 않게
            log.exception("routine run %s failed", run.run_id)
            self._finish(run, args[1], RunStatus.FAILED, "루틴 진행 중 오류가 나서 멈췄어요", notify=True)

    def _continue(self, run, routine, rest, job_id, record, scenario_id, kwargs) -> None:
        if record is None:
            record = self._await_job(job_id)
        run.active = False
        if record is None:
            self._finish(run, routine, RunStatus.UNCONFIRMED, "첫 단계의 결과를 확인하지 못했어요", notify=True)
            return
        if not self._absorb(run, record):
            self._finish(run, routine, _FROM_COMMAND[record.status], "앞 단계가 확인되지 않아 멈췄어요")
            return
        for kind, payload in rest:
            if run.cancel.is_set():
                self._finish(run, routine, RunStatus.STOPPED, "정지 요청으로 남은 단계를 보내지 않았어요")
                return
            if kind == "announce":
                self._announce(run, routine, payload)
                continue
            if kind == "wait":
                ok, detail, basis = self._check_done(run, payload)
                if run.cancel.is_set():
                    run.steps.append({"kind": "wait_until_done", "appliance_id": payload, "status": "stopped",
                                      "detail": "정지 요청으로 기다림을 멈췄어요", "basis": basis})
                    self._finish(run, routine, RunStatus.STOPPED, "정지 요청으로 남은 단계를 보내지 않았어요")
                    return
                run.steps.append({"kind": "wait_until_done", "appliance_id": payload,
                                  "status": "passed" if ok else "not_confirmed", "detail": detail,
                                  "basis": basis})
                if not ok:
                    self._finish(run, routine, RunStatus.UNCONFIRMED, detail, notify=True)
                    return
                continue
            if not self._await_idle():
                self._finish(run, routine, RunStatus.FAILED,
                             "다른 작업이 끝나지 않아 다음 단계를 보내지 않았어요", notify=True)
                return
            approved = tuple(replace(a, expires_at=None) for a in payload)
            run.done_mark = self._done_mark()
            run.active = True
            try:
                record = self._service.execute_approved(approved, approval_guard=None,
                                                        scenario_id=scenario_id, **kwargs)
            except Exception as exc:  # noqa: BLE001 -- 재검사 거절(바뀜·준비 안 됨·바쁨)
                run.active = False
                self._finish(run, routine, RunStatus.FAILED,
                             f"다음 단계를 시작하지 못했어요: {exc}", notify=True)
                return
            run.active = False
            run.job_ids.append(record.job_id)
            if not self._absorb(run, record):
                self._finish(run, routine, _FROM_COMMAND[record.status], "앞 단계가 확인되지 않아 멈췄어요")
                return
        if run.cancel.is_set():
            self._finish(run, routine, RunStatus.STOPPED, "정지 요청으로 멈췄어요")
            return
        self._finish(run, routine, RunStatus.SUCCEEDED,
                     "모든 단계를 마쳤어요" + (" (시연: 모의 실행 포함)" if run.is_demo else ""))

    def _absorb(self, run: RoutineRun, record) -> bool:
        for i, result in enumerate(record.results):
            run.results.append(result)
            if result.execution_mode is ExecutionMode.MOCK:
                run.is_demo = True
            run.steps.append({
                "kind": "command",
                "target_id": result.command.target_id,
                "route": result.route.value,
                "summary": record.summaries[i] if i < len(record.summaries) else "",
                "status": result.status.value,
                "confirmation": result.confirmation.value,
                "execution_mode": result.execution_mode.value,
                "detail": result.detail,
            })
        return (record.status is CommandStatus.SUCCEEDED
                and not any(r.stop_requested for r in record.results))

    def _done_mark(self) -> int:
        return self._done_log.mark() if self._done_log is not None else 0

    def _check_done(self, run: RoutineRun, appliance_id: str) -> tuple[bool, str, str]:
        """(통과, 설명, 근거). 근거: cycle_end(끝 센서) · start_only(시작 확인만) · mock(모의 실행) · none."""
        result = next((r for r in reversed(run.results) if r.command.target_id == appliance_id), None)
        if result is None:
            return False, "기다릴 가전의 실행 결과가 없어요", "none"
        if result.status is CommandStatus.SUCCEEDED and result.confirmation.confirms_appliance:
            if appliance_id in self._done_sensors and self._done_log is not None:
                return self._wait_cycle_end(run, appliance_id)
            return True, START_ONLY_DETAIL, "start_only"
        if result.status is CommandStatus.SUCCEEDED and result.execution_mode is ExecutionMode.MOCK:
            run.is_demo = True
            return True, f"시연: 모의 실행 — {START_ONLY_DETAIL} (실제 완료를 확인한 것은 아니에요)", "mock"
        return False, (f"완료를 확인하지 못해 다음 단계를 보내지 않았어요 "
                       f"(확인 수준: {result.confirmation.value})"), "none"

    def _wait_cycle_end(self, run: RoutineRun, appliance_id: str) -> tuple[bool, str, str]:
        """RPi4가 그 가전 CT 채널의 사이클 끝(``appliance_done``)을 보낼 때까지 기다린다(상한·정지 요청)."""
        record = self._done_log.wait_for(appliance_id, run.done_mark, self._done_timeout, run.cancel)
        if record is None:
            if run.cancel.is_set():
                return False, "정지 요청으로 기다림을 멈췄어요", "cycle_end"
            return False, (f"시작은 확인했지만 {self._done_timeout / 60:.0f}분 안에 끝남(전력 하강)을 확인하지 못해 "
                           f"다음 단계를 보내지 않았어요"), "cycle_end"
        inputs = record.get("inputs") or []
        how = "전력·종료음" if len(inputs) == 2 else ("전력 하강" if inputs == ["power"] else "종료음")
        detail = f"끝난 것을 확인했어요({how})"
        source = record.get("source")
        if source == "injected":
            run.is_demo = True
            detail += " (시연 주입)"
        elif source != "real":
            run.is_demo = True
            detail += " (모의 입력)"
        return True, detail, "cycle_end"

    def _announce(self, run: RoutineRun, routine: Routine, text: str) -> None:
        if self._care is not None:
            try:
                self._care.append(KIND_ROUTINE_ANNOUNCE, text, purpose=routine.name)
            except Exception:  # noqa: BLE001
                log.exception("routine announce record failed")
        run.steps.append({"kind": "announce", "text": text, "status": "announced",
                          "detail": "안내를 알림함에 남겼어요(음성 출력은 아직 연결 전)"})

    def _await_job(self, job_id: str):
        deadline = time.monotonic() + self._job_timeout
        while time.monotonic() < deadline:
            status = self._service.status()
            if not status.running and status.last_job_id == job_id:
                last = self._service.last_run()
                return last if last is not None and last.job_id == job_id else None
            self._sleep(self._poll)
        return None

    def _await_idle(self) -> bool:
        deadline = time.monotonic() + self._idle_timeout
        while time.monotonic() < deadline:
            if not self._service.status().running:
                return True
            self._sleep(self._poll)
        return False

    def _finish(self, run: RoutineRun, routine: Routine, status: RunStatus, detail: str,
                *, notify: bool = False) -> None:
        run.status = status
        run.detail = detail
        run.finished_at = self._clock.now()
        run.active = False
        if notify and self._care is not None:
            try:
                self._care.append(KIND_ROUTINE_STOPPED, f"'{routine.name}' 루틴: {detail}",
                                  purpose=routine.name)
            except Exception:  # noqa: BLE001
                log.exception("routine stop record failed")
        if self._on_finished is not None:
            try:
                self._on_finished(run)
            except Exception:  # noqa: BLE001
                log.exception("routine finished listener failed")
