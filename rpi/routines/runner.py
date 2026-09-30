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

``wait_until_done`` 판정(실물 미검증):
- 그 가전의 마지막 결과가 성공이고 ``operation_confirmed``(L3) 또는 ``state_confirmed``면 통과.
- 모의 실행(``mock``)의 성공은 **시연 통과**로 적는다(실제 완료를 본 것이 아니다).
- 그 밖(L1 눌림만·보고만·미확인·실패)은 루틴을 멈추고 보호자 알림함에 남긴다.
"가열이 끝났다"(전류가 다시 내려감)를 따로 기다리는 기능은 없다 -- 실측 뒤 정한다.

이어지는 구간의 승인: 첫 구간을 제출할 때 카드의 유효 시간·상황 재검사를 통과했다.
뒤 구간은 **같은 승인의 연속**이라 카드 유효 시간(15분)으로 끊지 않는다(세탁처럼 긴
대기). 명령 지문 대조와 실행 직전 재검사(대상·경로·동작 범위·준비 상태)는 그대로 한다.
"""

from __future__ import annotations

import logging
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
                 job_timeout_seconds: float = 3 * 3600, idle_timeout_seconds: float = 60.0) -> None:
        self._store = store
        self._service = service
        self._clock = clock
        self._care = care_events
        self._on_finished = on_finished
        self._poll = poll_seconds
        self._sleep = sleep
        self._job_timeout = job_timeout_seconds
        self._idle_timeout = idle_timeout_seconds
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
        job_id = self._service.submit_approved(tuple(first), approval_guard=approval_guard,
                                               scenario_id=scenario_id, **kwargs)
        run = self._start(routine, scenario_id, job_id)
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
        record = self._service.execute_approved(tuple(first), approval_guard=approval_guard,
                                                scenario_id=scenario_id, **kwargs)
        run = self._start(routine, scenario_id, record.job_id)
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
                ok, detail = self._check_done(run, payload)
                run.steps.append({"kind": "wait_until_done", "appliance_id": payload,
                                  "status": "passed" if ok else "not_confirmed", "detail": detail})
                if not ok:
                    self._finish(run, routine, RunStatus.UNCONFIRMED, detail, notify=True)
                    return
                continue
            if not self._await_idle():
                self._finish(run, routine, RunStatus.FAILED,
                             "다른 작업이 끝나지 않아 다음 단계를 보내지 않았어요", notify=True)
                return
            approved = tuple(replace(a, expires_at=None) for a in payload)
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

    def _check_done(self, run: RoutineRun, appliance_id: str) -> tuple[bool, str]:
        result = next((r for r in reversed(run.results) if r.command.target_id == appliance_id), None)
        if result is None:
            return False, "기다릴 가전의 실행 결과가 없어요"
        if result.status is CommandStatus.SUCCEEDED and result.confirmation.confirms_appliance:
            return True, "가전 동작을 확인했어요"
        if result.status is CommandStatus.SUCCEEDED and result.execution_mode is ExecutionMode.MOCK:
            run.is_demo = True
            return True, "시연: 모의 실행이라 실제 완료를 확인한 것은 아니에요"
        return False, (f"완료를 확인하지 못해 다음 단계를 보내지 않았어요 "
                       f"(확인 수준: {result.confirmation.value})")

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
