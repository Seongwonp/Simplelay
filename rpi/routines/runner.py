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

``wait_until_done`` 판정(실물 미검증, 2026-10-06 갭 M2 · 같은 날 평가 B1·B4·B5·Copilot#5):
- **끝 센서가 있는 가전**(RPi4가 ``act_info.done_watch``로 알린 목록, 알기 전에는 ``SIMPLELAY_ROUTINE_DONE_SENSORS``
  — `DoneSensorSet`)이면 그 가전의 마지막 결과가 성공이기만 하면(L1 눌림 확인이어도 — L3는 전자레인지 채널만
  읽으므로 세탁기는 L3 시작 확인을 받을 수 없다, 평가 B4) RPi4가 그 가전 CT 채널 전력 하강(`rpi/verifier/cycle_end.py`)
  으로 보내는 ``appliance_done``을 기다린다 — 구간을 보내기 전에 잡은 표(`ApplianceDoneLog.mark`) 뒤에 온 것만,
  가전별 상한(``SIMPLELAY_ROUTINE_DONE_TIMEOUT_<가전>_S`` → ``SIMPLELAY_ROUTINE_DONE_TIMEOUT_S`` → 가전별 기본
  `DEFAULT_DONE_TIMEOUTS_S` → 1200 s, 전부 측정 필요)까지.
  **``done_confirmed``(전력·종료음 둘 다)만 끝남 확인**이다(평가 B1). 입력 하나뿐(``done_power_only``·``done_beep_only``)
  이면 "끝난 것 같아요."로 시작하는 문장을 남기고 뒤 단계(안내·장치)를 **보내지 않고** 루틴을 멈춘다(보수적 선택).
  안 오면 루틴을 멈추고 알림함에 남긴다.
- 끝 센서가 없으면 L3·상태 확인으로 통과하되 단계에 **"시작한 것만 확인했어요. 끝났는지는 몰라요."**(``basis: start_only``).
- 정지: 루틴 정지·전체 정지(``POST /stop`` → `stop_all`)·비상정지 걸림(실행 중 한 번이라도 걸렸으면 해제 확인 뒤에도)은
  기다림을 끊고 남은 단계를 보내지 않는다(평가 B5).
- 구간 사이 정지(2026-10-16 안전 보고 G3): 정지는 (1) 각 단계 앞, (2) 다른 명령이 끝나기를 기다린 **뒤**, (3) 다음 구간의
  실행 시작 게이트 안(``approval_guard`` — 실행 서비스가 정지 기록을 지우는 바로 그 잠금 안)에서 본다. (3)이 없으면
  마지막 확인과 실행 시작 사이에 온 정지는 쉬는 서비스에 기록되지 않고(``was_running`` 거짓) 실행 시작이 실행 대상의 정지
  표시까지 지워 다음 구간이 그대로 나갔다. 구간 결과에 정지 표시가 있으면(버튼은 다 눌렸어도) 루틴은 ``stopped``다.
- 기다리는 동안 실행 서비스는 쉬는 중이다 — 새 사용자 명령은 막히지 않는다. 다음 장치 단계는 그 명령이 끝나기를
  ``idle_timeout``만큼 기다렸다가, 안 끝나면 루틴을 멈춘다(Copilot#5).
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
#: 가전별 기다림 기본 상한(초) — 설계 초기값, **측정 필요**. 전자레인지는 가열 몇 분 + 대기 확인(settle) 여유,
#: 세탁기는 표준 코스 한 바퀴(1~2시간)에 여유를 둔다.
DEFAULT_DONE_TIMEOUTS_S: dict[str, float] = {"microwave": 900.0, "washer": 3 * 3600.0}
# 10/18 쉬운 말: 결과 한 줄 + 할 일 한 줄('단계' → '할 일'). '—'·괄호로 잇지 않는다. 확인 수준은 그대로 —
# 시작만 본 것을 끝났다고, 입력 하나뿐인 끝을 확인했다고 말하지 않는다.
START_ONLY_DETAIL = "시작한 것만 확인했어요. 끝났는지는 몰라요."
#: 입력 하나뿐인 끝(``probable``)의 문장 머리. 단계 상태는 이 글자가 아니라 `_wait_cycle_end`가 돌려준 값으로 정한다.
PROBABLE_DETAIL = "끝난 것 같아요."
ESTOP_STOP_DETAIL = "비상 버튼이 눌려 남은 할 일을 멈췄어요. 풀어도 이어서 하지 않아요."
#: ``POST /stop``(전체 정지)·루틴 하나 정지로 멈춘 루틴 문장.
ALL_STOP_DETAIL = "멈추기를 눌러서 남은 할 일을 하지 않았어요."
ROUTINE_STOP_DETAIL = "루틴을 멈춰서 남은 할 일을 하지 않았어요."
WAIT_STOPPED_DETAIL = "멈추기를 눌러서 기다리지 않았어요."
#: 연습 신호로 끝을 본 경우 덧붙이는 말(자동 실행 알림과 같은 말).
INJECTED_NOTE = " 연습으로 넣은 신호예요."
MOCK_INPUT_NOTE = " 연습 신호예요."
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


def routine_done_timeouts_from_env(env=None) -> dict[str, float]:
    """가전별 기다림 상한(Copilot#5). 앞선 것이 이긴다: ``SIMPLELAY_ROUTINE_DONE_TIMEOUT_<가전>_S`` →
    ``SIMPLELAY_ROUTINE_DONE_TIMEOUT_S``(모든 가전) → `DEFAULT_DONE_TIMEOUTS_S`. 반환에 없는 가전은 러너 기본값."""
    src = os.environ if env is None else env
    out = dict(DEFAULT_DONE_TIMEOUTS_S)
    common = (src.get(DONE_TIMEOUT_ENV) or "").strip()
    if common:
        value = _positive_seconds(DONE_TIMEOUT_ENV, common)
        out = {k: value for k in out}
    prefix = DONE_TIMEOUT_ENV.removesuffix("_S") + "_"
    for name, raw in src.items():
        if not name.startswith(prefix) or not name.endswith("_S") or name == DONE_TIMEOUT_ENV:
            continue
        appliance = name[len(prefix):-2].lower()
        if raw.strip():
            out[appliance] = _positive_seconds(name, raw.strip())
    return out


def _positive_seconds(name: str, raw: str) -> float:
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not (math.isfinite(value) and value > 0):
        raise RuntimeError(f"{name}는 0보다 커야 합니다: {raw!r}")
    return value


class DoneSensorSet:
    """끝 센서가 있는 가전 목록(평가 B3). RPi4가 ``act_info.done_watch``로 알리면 **그 목록을 따르고**, 알기 전에는
    ``SIMPLELAY_ROUTINE_DONE_SENSORS``를 쓴다. 두 목록이 다르거나 RPi4 가전 ID가 RPi5 가전 목록에 없으면
    `problems`에 사람이 읽을 문장으로 남기고 로그(error)로 알린다.

    ID 공간: RPi4 ``SIMPLELAY_DONE_WATCH``의 이름은 RPi5 가전 목록의 ``appliance_id``(예: 내장 전자레인지
    ``microwave``)와 **같아야** 한다 — RPi4가 보낸 ``appliance_done.appliance_id``를 루틴의 가전과 그대로 대조하기
    때문이다. 사용자가 추가한 가전(ID 자동 생성)이면 RPi4 설정에 그 ID를 써야 한다.
    """

    def __init__(self, configured: frozenset | set = frozenset()) -> None:
        self.configured = frozenset(configured)
        self.reported: frozenset | None = None
        self.problems: list[str] = []
        self._lock = threading.Lock()

    def current(self) -> frozenset:
        with self._lock:
            return self.reported if self.reported is not None else self.configured

    def __contains__(self, appliance_id: object) -> bool:
        return appliance_id in self.current()

    def __iter__(self):
        return iter(self.current())

    def report(self, done_watch, known_ids=None) -> list[str]:
        """RPi4가 알린 끝 관찰 가전 목록을 받는다. 어긋남을 돌려준다(없으면 빈 목록)."""
        ids = frozenset(i for i in (done_watch or ()) if isinstance(i, str) and _ID.fullmatch(i))
        problems: list[str] = []
        only_rpi5 = sorted(self.configured - ids)
        only_rpi4 = sorted(ids - self.configured)
        if only_rpi5:
            problems.append(f"{DONE_SENSORS_ENV}에 있는 {', '.join(only_rpi5)}의 끝을 RPi4가 관찰하지 않아요 "
                            "(RPi4 SIMPLELAY_DONE_WATCH 확인) — 그 가전은 끝을 기다리지 않고 시작 확인으로 처리해요")
        if only_rpi4:
            problems.append(f"RPi4가 {', '.join(only_rpi4)}의 끝을 보내는데 {DONE_SENSORS_ENV}에 없어요 — "
                            "RPi4 목록을 따라요(설정을 맞춰 주세요)")
        if known_ids is not None:
            unknown = sorted(ids - set(known_ids))
            if unknown:
                problems.append(f"RPi4 SIMPLELAY_DONE_WATCH의 가전 ID {', '.join(unknown)}가 RPi5 가전 목록에 없어요 — "
                                "이 가전의 끝 알림은 어떤 루틴에도 닿지 않아요(RPi5 가전 ID로 맞춰 주세요)")
        with self._lock:
            self.reported = ids
            self.problems = problems
        for problem in problems:
            log.error("done sensor mismatch: %s", problem)
        return problems


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


class RoutineHaltedError(RuntimeError):
    """다음 구간의 실행 시작 게이트에서 루틴 정지 표시를 봤다(G3) — 실행은 시작되지 않았다."""


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
    #: 시작할 때 본 비상정지 횟수(평가 B5) — 실행 중 늘면 해제 확인 뒤에도 남은 단계를 보내지 않는다.
    estop_trips: int | None = None
    #: 정지 사유(루틴 정지·전체 정지). 없으면 기본 문장.
    stop_reason: str | None = None

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
                 done_log=None, done_sensors: "frozenset | DoneSensorSet" = frozenset(),
                 done_timeout_seconds: float = DEFAULT_DONE_TIMEOUT_S,
                 done_timeouts: dict | None = None) -> None:
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
        self._done_sensors = (done_sensors if isinstance(done_sensors, DoneSensorSet)
                              else frozenset(done_sensors))
        self._done_timeout = done_timeout_seconds
        #: 가전별 기다림 상한(Copilot#5). 없는 가전은 ``done_timeout_seconds``.
        self._done_timeouts = dict(done_timeouts or {})
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
        self._announce_leading(routine, leading)
        mark = self._done_mark()
        job_id = self._service.submit_approved(tuple(first), approval_guard=approval_guard,
                                               scenario_id=scenario_id, **kwargs)
        run = self._start(routine, scenario_id, job_id)
        run.done_mark = mark
        for text in leading:
            self._announce_step(run, text)
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
        self._announce_leading(routine, leading)
        mark = self._done_mark()
        record = self._service.execute_approved(tuple(first), approval_guard=approval_guard,
                                                scenario_id=scenario_id, **kwargs)
        run = self._start(routine, scenario_id, record.job_id)
        run.done_mark = mark
        for text in leading:
            self._announce_step(run, text)
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

    def halt_all(self, reason: str = "전체 정지 요청") -> int:
        """진행 중인 루틴 모두에 정지 표시만 세운다 — 입출력·로그 없음(이벤트 루프에서 바로 불러도 된다).

        ``POST /stop``이 **맨 앞에서** 부른다(2026-10-16 G3): 실행 정지가 RPi4 정지 보고를 기다리는 동안 루틴이 다음 구간을
        보내지 않게. 사유를 표시보다 먼저 적는다(표시를 본 루틴이 사유를 읽는다). 표시를 세운 수를 돌려준다."""
        stopped = 0
        with self._lock:
            runs = [r for r in self._runs if r.status is RunStatus.RUNNING]
        for run in runs:
            run.stop_reason = reason
            run.cancel.set()
            stopped += 1
        return stopped

    def stop_all(self, reason: str = "전체 정지 요청") -> int:
        """진행 중인 루틴을 모두 멈춘다(평가 B5) — ``POST /stop``이 부른다. 장치 정지는 부른 쪽이 이미 했다.
        끝을 기다리는 루틴도 기다림을 끊고 남은 단계를 보내지 않는다. 멈춘 수를 돌려준다."""
        stopped = self.halt_all(reason)
        if stopped:
            log.warning("stopped %d routine run(s): %s", stopped, reason)
        return stopped

    def _estop_snapshot(self) -> tuple[bool, int | None]:
        status_fn = getattr(self._service, "estop_status", None)
        if not callable(status_fn):
            return False, None
        try:
            status = status_fn() or {}
        except Exception:  # noqa: BLE001 - 조회 고장은 '모름'(걸림으로 단정하지 않는다)
            log.exception("estop status for routine failed")
            return False, None
        trips = status.get("trips")
        return status.get("latched") is True, trips if isinstance(trips, int) else None

    def _estop_hit(self, run: RoutineRun) -> bool:
        """실행 중 비상정지가 걸렸나(지금 걸려 있거나, 시작 뒤 걸림 횟수가 늘었다)."""
        latched, trips = self._estop_snapshot()
        if latched:
            return True
        return run.estop_trips is not None and trips is not None and trips != run.estop_trips

    def _stopped_detail(self, run: RoutineRun) -> str:
        if self._estop_hit(run):
            return ESTOP_STOP_DETAIL
        # 사유(``stop_reason``)는 기록에 남기고 문장은 사람 말로 — 전체 정지인지 이 루틴만 멈췄는지만 가른다.
        return ALL_STOP_DETAIL if run.stop_reason else ROUTINE_STOP_DETAIL

    def _halted(self, run: RoutineRun) -> bool:
        return run.cancel.is_set() or self._estop_hit(run)

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
        run.estop_trips = self._estop_snapshot()[1]
        with self._lock:
            self._runs.append(run)
        return run

    def _continue_safely(self, *args) -> None:
        run = args[0]
        try:
            self._continue(*args)
        except Exception:  # noqa: BLE001 -- 순서기 예외가 스레드를 조용히 죽이지 않게
            log.exception("routine run %s failed", run.run_id)
            self._finish(run, args[1], RunStatus.FAILED, "루틴을 하다가 오류가 나서 멈췄어요. 가전을 봐 주세요.", notify=True)

    def _continue(self, run, routine, rest, job_id, record, scenario_id, kwargs) -> None:
        if record is None:
            record = self._await_job(job_id)
        run.active = False
        if record is None:
            self._finish(run, routine, RunStatus.UNCONFIRMED, "첫 할 일이 됐는지 몰라요. 가전을 봐 주세요.", notify=True)
            return
        if not self._absorb(run, record):
            self._finish_unabsorbed(run, routine, record)
            return
        for kind, payload in rest:
            if self._halted(run):
                self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
                return
            if kind == "announce":
                self._announce(run, routine, payload)
                continue
            if kind == "wait":
                ok, detail, basis, probable = self._check_done(run, payload)
                if self._halted(run):
                    run.steps.append({"kind": "wait_until_done", "appliance_id": payload, "status": "stopped",
                                      "detail": WAIT_STOPPED_DETAIL, "basis": basis})
                    self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
                    return
                status = "passed" if ok else ("probable" if probable else "not_confirmed")
                run.steps.append({"kind": "wait_until_done", "appliance_id": payload,
                                  "status": status, "detail": detail, "basis": basis})
                if not ok:
                    self._finish(run, routine, RunStatus.UNCONFIRMED, detail, notify=True)
                    return
                continue
            if not self._await_idle():
                self._finish(run, routine, RunStatus.FAILED,
                             "다른 일이 아직 끝나지 않아 다음 할 일을 멈췄어요.", notify=True)
                return
            # G3: 기다린 사이에 온 정지 — 다시 본다(기다림 앞의 확인만으로는 그 사이 정지를 놓친다).
            if self._halted(run):
                self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
                return
            approved = tuple(replace(a, expires_at=None) for a in payload)
            run.done_mark = self._done_mark()
            run.active = True
            try:
                # G3: 실행 시작 게이트(서비스 잠금 안)에서 루틴 정지를 한 번 더 본다 — 위 확인과 실행 시작 사이에 온 정지를
                # 실행 시작의 정지 기록 초기화가 덮지 못하게.
                record = self._service.execute_approved(approved, approval_guard=self._start_guard(run),
                                                        scenario_id=scenario_id, **kwargs)
            except RoutineHaltedError:
                run.active = False
                self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
                return
            except Exception as exc:  # noqa: BLE001 -- 재검사 거절(바뀜·준비 안 됨·바쁨)
                run.active = False
                if self._halted(run):
                    self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
                    return
                self._finish(run, routine, RunStatus.FAILED,
                             f"다음 할 일을 시작하지 못했어요. {exc}", notify=True)
                return
            run.active = False
            run.job_ids.append(record.job_id)
            if not self._absorb(run, record):
                self._finish_unabsorbed(run, routine, record)
                return
        if self._halted(run):
            self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
            return
        self._finish(run, routine, RunStatus.SUCCEEDED,
                     "모든 할 일을 마쳤어요." + (" 연습으로 한 일도 있어요." if run.is_demo else ""))

    @staticmethod
    def _start_guard(run: RoutineRun):
        """다음 구간의 실행 시작 게이트(``approval_guard``) — 실행 서비스가 **자기 잠금 안**에서 부른다.

        루틴 정지 표시만 본다(메모리 읽기 하나 — 서비스 잠금 안이라 서비스 조회·비상정지 조회는 부르지 않는다. 비상정지
        걸림은 실행 서비스의 시작 게이트가 따로 막는다). 표시가 있으면 `RoutineHaltedError` — 실행은 시작되지 않는다."""
        def guard() -> None:
            if run.cancel.is_set():
                raise RoutineHaltedError("멈추기를 눌러서 다음 할 일을 시작하지 않았어요.")
        return guard

    def _finish_unabsorbed(self, run: RoutineRun, routine: Routine, record) -> None:
        """구간이 성공으로 끝나지 않았거나 정지 표시가 있다 — 루틴을 멈춘다.

        정지(구간 ``stopped``, 결과의 정지 표시, 루틴 정지 표시)면 ``stopped``와 정지 문장이다(G3 — 버튼은 다 눌렸어도 정지
        요청이 있었으면 '성공'으로 적지 않는다). 실패·미확인은 그 상태 그대로 둔다 — 정지 뒤 링크가 끊긴 구간이라도
        '눌렸는지 모름'(G1)을 정지로 덮지 않는다."""
        status = _FROM_COMMAND[record.status]
        stopped = (status is RunStatus.STOPPED
                   or (status is RunStatus.SUCCEEDED
                       and (any(r.stop_requested for r in record.results) or self._halted(run))))
        if stopped:
            self._finish(run, routine, RunStatus.STOPPED, self._stopped_detail(run))
            return
        self._finish(run, routine, status, "앞의 할 일이 됐는지 몰라서 멈췄어요. 가전을 봐 주세요.")

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

    def _check_done(self, run: RoutineRun, appliance_id: str) -> tuple[bool, str, str, bool]:
        """(통과, 설명, 근거, 끝난 것 같음). 근거: cycle_end(끝 센서) · start_only(시작 확인만) · mock(모의 실행) · none.
        '끝난 것 같음'(입력 하나뿐인 끝)은 설명 글자로 가르지 않고 이 값으로 돌려준다."""
        result = next((r for r in reversed(run.results) if r.command.target_id == appliance_id), None)
        if result is None:
            return False, "기다릴 가전이 한 일을 찾지 못했어요. 가전을 봐 주세요.", "none", False
        sensored = appliance_id in self._done_sensors and self._done_log is not None
        if (sensored and result.status is CommandStatus.SUCCEEDED
                and result.execution_mode is not ExecutionMode.MOCK):
            # 끝 관찰 스트림이 곧 동작 근거다 — L3 시작 확인을 요구하지 않는다(평가 B4: L3는 전자레인지 채널만 읽는다).
            return self._wait_cycle_end(run, appliance_id)
        if result.status is CommandStatus.SUCCEEDED and result.confirmation.confirms_appliance:
            return True, START_ONLY_DETAIL, "start_only", False
        if result.status is CommandStatus.SUCCEEDED and result.execution_mode is ExecutionMode.MOCK:
            run.is_demo = True
            return True, "연습이라 실제로 끝났는지는 확인하지 않았어요.", "mock", False
        # 확인 수준(``result.confirmation``)은 결과 기록에 남는다 — 문장에는 내지 않는다.
        return False, "끝났는지 몰라서 다음 할 일을 멈췄어요. 가전을 봐 주세요.", "none", False

    def done_timeout_for(self, appliance_id: str) -> float:
        return self._done_timeouts.get(appliance_id, self._done_timeout)

    def _wait_cycle_end(self, run: RoutineRun, appliance_id: str) -> tuple[bool, str, str, bool]:
        """RPi4가 그 가전 CT 채널의 사이클 끝(``appliance_done``)을 보낼 때까지 기다린다(가전별 상한·정지·비상정지).

        짧게 나눠 기다리며 비상정지를 본다(평가 B5). 입력 하나뿐인 끝은 확인으로 치지 않는다(평가 B1).
        """
        timeout = self.done_timeout_for(appliance_id)
        deadline = time.monotonic() + timeout
        record = None
        while record is None:
            if self._halted(run):
                return False, WAIT_STOPPED_DETAIL, "cycle_end", False
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            record = self._done_log.wait_for(appliance_id, run.done_mark, min(remaining, 0.5), run.cancel)
        if record is None:
            return False, (f"시작한 뒤 {timeout / 60:.0f}분이 지나도 끝난 것을 보지 못했어요. "
                           "다음 할 일을 멈췄으니 가전을 봐 주세요."), "cycle_end", False
        inputs = record.get("inputs") or []
        source = record.get("source")
        if record.get("state") != "done_confirmed":
            which = "전기 쓰는 것만 줄었어요." if inputs == ["power"] else "끝나는 소리만 들렸어요."
            detail = f"{PROBABLE_DETAIL} {which} 다음 할 일을 멈췄으니 가전을 봐 주세요."
            if source == "injected":
                run.is_demo = True
                detail += INJECTED_NOTE
            elif source != "real":
                run.is_demo = True
                detail += MOCK_INPUT_NOTE
            return False, detail, "cycle_end", True
        detail = "끝난 것을 확인했어요."
        if source == "injected":
            run.is_demo = True
            detail += INJECTED_NOTE
        elif source != "real":
            run.is_demo = True
            detail += MOCK_INPUT_NOTE
        return True, detail, "cycle_end", False

    def _announce(self, run: RoutineRun, routine: Routine, text: str) -> None:
        self._announce_notice(routine, text)
        self._announce_step(run, text)

    def _announce_leading(self, routine: Routine, leading) -> None:
        """맨 앞 안내는 첫 장치 구간을 보내기 **전에** 알림함에 남긴다(검토 10/19 #5) — 예전에는 보낸 뒤(동기 실행이면 첫
        구간이 다 끝난 뒤)에 남았다. 루틴 기록의 단계는 실행 번호가 생긴 뒤 같은 순서(안내 → 장치)로 적는다."""
        for text in leading:
            self._announce_notice(routine, text)

    def _announce_notice(self, routine: Routine, text: str) -> None:
        if self._care is not None:
            try:
                self._care.append(KIND_ROUTINE_ANNOUNCE, text, purpose=routine.name)
            except Exception:  # noqa: BLE001
                log.exception("routine announce record failed")

    @staticmethod
    def _announce_step(run: RoutineRun, text: str) -> None:
        run.steps.append({"kind": "announce", "text": text, "status": "announced",
                          "detail": "안내를 알림함에 남겼어요."})

    def _await_job(self, job_id: str):
        """그 실행(``job_id``) 자신의 기록을 기다린다(검토 10/19 #3).

        예전에는 '쉬는 중이고 마지막 실행 번호가 이 실행'일 때만 기록을 봤다 — 그 사이 다른 실행이 시작되면 마지막 실행
        번호가 이 실행을 거치지 않고 넘어가 끝을 놓쳤다. 이제 번호가 이 실행인 기록이 보이면 곧바로 그것으로 판단한다.
        기록 없이 이 실행이 끝났으면(실행 스레드 예외 등) 예전처럼 None(모름).

        남은 경합(검토 10/19 #3 후속): 한 번 확인하는 사이에 다른 실행(J2)까지 끝나면 '마지막 기록'이 J2라 J1의 기록이
        가려졌다. 서비스가 실행 번호별 기록(``run_record``)을 주면 그것부터 본다. 없는 옛 서비스는 종전대로."""
        deadline = time.monotonic() + self._job_timeout
        while time.monotonic() < deadline:
            record = self._record_of(job_id)
            if record is not None:
                return record
            status = self._service.status()
            if not status.running and status.last_job_id == job_id:
                return self._record_of(job_id)
            self._sleep(self._poll)
        return None

    def _record_of(self, job_id: str):
        """그 실행 번호의 기록 — 번호별 기록이 먼저, 없으면 마지막 기록이 그 번호일 때만."""
        by_job = getattr(self._service, "run_record", None)
        if callable(by_job):
            record = by_job(job_id)
            if record is not None:
                return record
        last = self._service.last_run()
        return last if last is not None and last.job_id == job_id else None

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
