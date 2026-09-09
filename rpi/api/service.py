import logging
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime

from rpi.controller import (
    ButtonSequenceController,
    ExecutionProgress,
    ExecutionProgressTracker,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.intent import (
    Clock,
    IntentResolver,
    LlmClient,
    LlmIntentResolver,
    PurposeExecutor,
    SystemClock,
    UsageLog,
    UsageOutcome,
    UsageRecord,
)
from rpi.intent.rules import UnknownIntentError
from rpi.services import NodeRegistry
from rpi.services.history import (
    ButtonAttempt,
    ExecutionMode,
    JobHistoryEntry,
    JobHistoryStore,
    Termination,
)

log = logging.getLogger(__name__)

# 노드 정지 브로드캐스트 전체 상한 — 개별 요청 타임아웃(2초)보다 살짝 길게
# 잡아, 살아 있는 노드는 확인하고 죽은 노드 하나가 호출자를 붙잡지는 않게.
EMERGENCY_STOP_BROADCAST_SECONDS = 2.5


class ServiceNotReadyError(RuntimeError):
    """Raised when execute_purpose is called before startup completes or after shutdown."""


def _mode_of(controller: object | None) -> ExecutionMode:
    """실행 대상이 스스로 밝힌 실제/모의 모드.

    밝히지 않으면 UNKNOWN이다. 라우팅 결과(원격이냐 로컬이냐)로
    추측하지 않는다 -- 전송이 원격이라는 사실은 저쪽이 실제로 눌렀는지에
    대해 아무것도 말해주지 않는다.
    """
    return getattr(controller, "execution_mode", ExecutionMode.UNKNOWN)


class ApplianceNotReadyError(LookupError):
    """대상 가전이 아직 조작할 수 있는 상태가 아니다.

    ``reasons``에 **사용자에게 그대로 보여줄 수 있는** 사유를 담는다.
    화면이 기술 문구를 잘라 쓰게 하면 서버 문구가 바뀔 때마다 조용히
    깨지고, 그러다 결국 "실행하지 못했어요" 같은 일반 문구로 덮인다 --
    그러면 무엇이 남았는지가 사라진다.

    등록됐다는 것과 조작할 수 있다는 것은 다르다 -- 주소는 맞는데 선이
    안 꽂혀 있거나, 전송은 되는데 모터가 홈을 안 잡았거나, 좌표를 아직
    안 맞춘 상태에서 실행을 받으면 갠트리가 엉뚱한 곳을 누른다.

    UnknownApplianceError와 마찬가지로 RuntimeError가 아니다 -- 409('다른
    작업이 실행 중')로 뭉뚱그리면 "잠시 후 다시"로 안내되는데, 여기서
    필요한 것은 기다림이 아니라 **설치를 마치는 일**이다.
    """

    def __init__(
        self, appliance_id: str, reasons: tuple[str, ...] = ()
    ) -> None:
        self.appliance_id = appliance_id
        self.reasons = reasons
        super().__init__(
            f"appliance '{appliance_id}' is not ready -- "
            + (" · ".join(reasons) or "reason unknown")
        )

    @property
    def user_message(self) -> str:
        """화면에 그대로 실을 수 있는 문장."""
        return " · ".join(self.reasons) or "아직 조작할 준비가 되지 않았어요"


class UnknownApplianceError(LookupError):
    """실행 대상 가전을 레지스트리에서 찾을 수 없다.

    **RuntimeError를 상속하지 않는다.** 그쪽은 라우터가 409('다른 작업이
    실행 중')로 옮기는 자리라, 여기에 섞이면 "잠시 후 다시 시도하세요"로
    안내된다 -- 기다려도 영원히 안 되는 상황에 대고 하는 말이다."""


class LlmNotConfiguredError(RuntimeError):
    """Raised when execute_purpose_for_appliance is called without an LLM
    client configured on this service instance (see the ``llm_client``
    constructor parameter and rpi/api/deps.py)."""


@dataclass(frozen=True)
class StatusSnapshot:
    running: bool
    ready: bool
    last_result: ExecutionResult | None
    progress: ExecutionProgress | None = None
    # 비동기 job 모델: 실행 중이면 job_id, 끝나면 last_job_id로 옮겨간다.
    # 클라이언트는 자기가 제출한 job_id와 대조해 "내 실행"의 완료만 집는다
    # (이전 실행의 last_result를 내 결과로 오인하는 stale-result 레이스 방지).
    job_id: str | None = None
    last_job_id: str | None = None
    total_steps: int | None = None
    # 이 실행이 대상으로 삼은 가전. 화면이 "지금 고른 가전"으로 메우지
    # 않으려면 서버가 말해줘야 한다 -- 실행 중에 다른 가전을 골라도
    # 진행 중인 작업의 대상은 바뀌지 않는다.
    appliance_id: str | None = None
    last_appliance_id: str | None = None


class SimpleLayService(PurposeExecutor):
    """Small framework-neutral API suitable for wrapping with FastAPI later.

    Readiness is tracked separately from "process started": a caller that
    wants to confirm hardware dependencies (controller, verifier) before
    accepting commands can construct with ``start_ready=False`` and call
    ``mark_ready()`` once that check passes. ``request_shutdown()`` stops new
    purposes from being accepted while leaving an already-running execution
    (tracked by ``_running``) to finish normally rather than being torn down
    mid-retry.

    ``progress_tracker``, when given, must be the same
    ``ExecutionProgressTracker`` instance the caller wired into the
    ``ClosedLoopController`` passed as ``controller`` (via its
    ``on_progress`` callback) -- that's how ``status()`` can report live
    progress while ``execute_purpose`` is still running on another thread.
    """

    def __init__(
        self,
        intent: IntentResolver,
        controller: ButtonSequenceController,
        usage_log: UsageLog | None = None,
        clock: Clock | None = None,
        start_ready: bool = True,
        progress_tracker: ExecutionProgressTracker | None = None,
        llm_client: LlmClient | None = None,
        node_registry: NodeRegistry | None = None,
        appliance_registry=None,
        readiness_registry=None,
        local_appliance_ids: frozenset[str] | None = None,
        history_store: JobHistoryStore | None = None,
        care_events=None,
    ) -> None:
        self._intent = intent
        self._controller = controller
        self._usage_log = usage_log
        self._clock = clock or SystemClock()
        self._running = False
        self._ready = start_ready
        self._shutting_down = False
        self._last_result: ExecutionResult | None = None
        # job 모델 상태. _lock이 _guard_can_execute() 확인과 _running 설정을
        # 원자화한다 — 이전에는 check와 set이 분리되어 동시 요청 2개가 둘 다
        # 가드를 통과해 물리 실행이 이중으로 돌 수 있었다(TOCTOU).
        self._lock = threading.Lock()
        self._current_job_id: str | None = None
        self._last_job_id: str | None = None
        self._current_appliance_id: str | None = None
        self._last_appliance_id: str | None = None
        self._current_total_steps: int | None = None
        self._progress_tracker = progress_tracker
        # 사용자 정의 가전의 버튼 어휘로 즉석에서 LlmIntentResolver를 만들 때 씀
        # (execute_purpose_for_appliance). None이면 그 경로는 막힌다 -- 서버가
        # 기본으로 오프라인 동작하도록, LLM 연동은 항상 명시적으로 켜야 한다.
        self._llm_client = llm_client
        # 가전별로 등록된 원격 노드(Act) — appliance_id가 여기 없으면 로컬
        # self._controller(기본 내장 가전)로 그대로 간다. 다중 노드 아키텍처
        # 전환 전까지는 None으로 둬도 기존 동작과 완전히 동일하다.
        self._node_registry = node_registry
        # 실행 대상 가전의 존재 검증(R1). None이면 검증하지 않는다 --
        # 가전 개념이 없는 구성(rpi4 브리지·단위 테스트)의 기존 동작 유지.
        self._appliance_registry = appliance_registry
        # 가전별 준비 상태(F1). None이면 검사하지 않는다.
        self._readiness_registry = readiness_registry
        # 로컬 갠트리에 **의도적으로** 물린 커스텀 가전 id.
        #
        # 로컬 컨트롤러는 내장 가전(전자레인지) 위에 얹힌 갠트리다.
        # 노드 없는 커스텀 가전을 암묵적으로 여기로 흘리면, 선풍기
        # 시퀀스가 전자레인지의 엉뚱한 버튼을 누른다 -- R1이 막았던
        # 물리 오라우팅이 다른 문으로 되돌아오는 것이다. 데모용 배선은
        # 여기 적어 '의도한 것'임을 밝힌다.
        self._local_appliance_ids = frozenset(local_appliance_ids or ())
        # 실행 이력(무엇을·언제·재시도·결과) — None이면 기록하지 않는다
        self._history_store = history_store
        # 보호자 알림(실패·긴급정지) — None이면 기록하지 않는다
        self._care_events = care_events
        # 이번 실행 중 긴급 정지가 요청됐나 — 실행 종료 시 실패 이벤트의
        # 종류를 가른다(사용자가 멈춘 것 vs 스스로 실패한 것은 보호자에게
        # 전혀 다른 소식이다). _lock으로 보호.
        self._stop_requested_this_run = False
        # 그 정지를 **접수한** 시각 — 정지 지연의 기준점이다. 실행 종료
        # 시각만으로는 "멈추라고 한 뒤 얼마나 걸렸나"를 뺄 수 없다.
        # _lock으로 보호.
        self._stop_requested_at = None
        # 지금 실행의 시작 시각 — 소요시간을 재려면 필요하다. _lock으로 보호.
        self._current_started_at = None

    def mark_ready(self) -> None:
        """Declare that hardware dependencies finished initializing."""
        self._ready = True

    def request_shutdown(self) -> None:
        """Stop accepting new purposes; a running execution still completes."""
        self._shutting_down = True

    def execute_purpose(
        self, purpose: str, appliance_id: str | None = None
    ) -> ExecutionResult:
        return self._execute_via_resolver(purpose, self._intent, appliance_id)

    def execute_purpose_for_appliance(
        self,
        purpose: str,
        known_buttons: frozenset[str],
        appliance_id: str | None = None,
    ) -> ExecutionResult:
        """Like execute_purpose, but resolves against a caller-supplied button
        vocabulary instead of the server's fixed intent resolver.

        For user-registered custom appliances: they have no entry in the
        server's rule-based resolver, so a purpose is resolved fresh through
        an LLM constrained to exactly this appliance's button labels. Logs to
        the usage log like execute_purpose does -- unlike execute_buttons,
        this has a real repeatable purpose string worth learning from.
        """
        if self._llm_client is None:
            raise LlmNotConfiguredError(
                "no LLM client configured -- appliance-aware voice commands "
                "need one (see the llm_client param / rpi/api/deps.py)"
            )
        resolver = LlmIntentResolver(self._llm_client, known_buttons=known_buttons)
        return self._execute_via_resolver(purpose, resolver, appliance_id)

    @staticmethod
    def _validate_resolved_sequence(buttons: tuple[str, ...]) -> tuple[str, ...]:
        """resolver(특히 LLM) 출력의 실행 상한 재검증 (교차 리뷰 #5).

        요청 본문은 스키마가 거르지만 LLM이 만들어낸 시퀀스는 그 검증을
        거치지 않고 실행으로 들어갔다 — 모델이 폭주하면 상한 없는 물리
        실행이 된다. 여기서 개수·바이트 예산을 같은 기준으로 다시 적용한다."""
        from rpi.api.schemas import (  # noqa: PLC0415 — 순환 회피
            MAX_BUTTONS_PER_RUN,
            MAX_EXECUTE_PAYLOAD_BYTES,
            execute_payload_bytes,
        )

        if len(buttons) > MAX_BUTTONS_PER_RUN:
            raise UnknownIntentError(
                f"resolved sequence has {len(buttons)} buttons "
                f"(limit {MAX_BUTTONS_PER_RUN})"
            )
        size = execute_payload_bytes(list(buttons))
        if size > MAX_EXECUTE_PAYLOAD_BYTES:
            raise UnknownIntentError(
                f"resolved sequence is {size} bytes "
                f"(limit {MAX_EXECUTE_PAYLOAD_BYTES})"
            )
        return buttons

    def _execute_via_resolver(
        self, purpose: str, resolver: IntentResolver, appliance_id: str | None = None
    ) -> ExecutionResult:
        buttons = self._validate_resolved_sequence(tuple(resolver.resolve(purpose)))
        controller = self._controller_for(appliance_id)
        calibration = self._calibration_snapshot(appliance_id)
        self._begin_run(len(buttons), controller, appliance_id)
        try:
            return self._run_buttons(
                tuple(buttons), controller, purpose, appliance_id, calibration
            )
        finally:
            self._end_run()

    def execute_buttons(
        self, buttons: tuple[str, ...], appliance_id: str | None = None
    ) -> ExecutionResult:
        """Run an already-known button sequence directly, skipping intent
        resolution entirely.

        For appliances with no intent rules (e.g. user-defined custom button
        maps) there is no purpose string to resolve or log -- the same
        closed-loop guarantees (retry, verification) still apply, but this
        run is intentionally NOT added to the pattern-learning usage log,
        since that log's suggestion logic assumes a repeatable purpose
        string, not raw button presses.
        """
        buttons = tuple(buttons)
        controller = self._controller_for(appliance_id)
        calibration = self._calibration_snapshot(appliance_id)
        self._begin_run(len(buttons), controller, appliance_id)
        try:
            # 목적은 없지만 대상 가전은 있다. 넘기지 않으면 수동 버튼
            # 실행의 이력이 '어느 가전에서'를 잃는다 — 커스텀 가전은
            # 대부분 이 경로로 조작되므로 실험 표본이 통째로 빈다.
            return self._run_buttons(
                buttons, controller, None, appliance_id, calibration
            )
        finally:
            self._end_run()

    # ── 비동기 job 모델 ──────────────────────────────────────────────────────
    # HTTP 엔드포인트용. 실기기에서 버튼 시퀀스는 수 초~수십 초 걸리는데
    # 클라이언트(폰 8초·키오스크 4초) 타임아웃 안에 동기 응답이 불가능하므로,
    # 의도 해석(즉시 실패 가능한 부분)만 동기로 끝내고 물리 실행은 백그라운드
    # 스레드로 넘긴 뒤 job_id를 즉시 돌려준다. 진행·완료는 /status 폴링으로.

    def submit_purpose(self, purpose: str, appliance_id: str | None = None) -> str:
        buttons = self._intent.resolve(purpose)
        return self._submit(tuple(buttons), appliance_id, purpose)

    def submit_purpose_for_appliance(
        self,
        purpose: str,
        known_buttons: frozenset[str],
        appliance_id: str | None = None,
    ) -> str:
        if self._llm_client is None:
            raise LlmNotConfiguredError(
                "no LLM client configured -- appliance-aware voice commands "
                "need one (see the llm_client param / rpi/api/deps.py)"
            )
        resolver = LlmIntentResolver(self._llm_client, known_buttons=known_buttons)
        buttons = self._validate_resolved_sequence(tuple(resolver.resolve(purpose)))
        return self._submit(buttons, appliance_id, purpose)

    def submit_buttons(
        self, buttons: tuple[str, ...], appliance_id: str | None = None
    ) -> str:
        return self._submit(tuple(buttons), appliance_id, purpose=None)

    def _submit(
        self, buttons: tuple[str, ...], appliance_id: str | None, purpose: str | None
    ) -> str:
        controller = self._controller_for(appliance_id)
        # 보정 버전은 **대상을 확정하는 지금** 캡처해 실행 스레드로 넘긴다.
        # 스레드 안에서 다시 읽으면 실행 중에 갱신된 값을 찍는다.
        calibration = self._calibration_snapshot(appliance_id)
        job_id = self._begin_run(len(buttons), controller, appliance_id)
        thread = threading.Thread(
            target=self._run_job,
            args=(buttons, controller, purpose, appliance_id, calibration),
            daemon=True,
            name=f"simplelay-exec-{job_id}",
        )
        thread.start()
        return job_id

    def _run_job(
        self,
        buttons: tuple[str, ...],
        controller: ButtonSequenceController,
        purpose: str | None,
        appliance_id: str | None = None,
        calibration_version: str | None = None,
    ) -> None:
        try:
            self._run_buttons(
                buttons, controller, purpose, appliance_id, calibration_version
            )
        except Exception:
            # 백그라운드 스레드라 HTTP 500으로 표면화할 곳이 없다 — 로그를
            # 남기고 /status의 last_status="failed"로 실패를 노출한다.
            log.exception("background job execution failed")
            self._last_result = ExecutionResult(ExecutionStatus.FAILED, ())
            # 컨트롤러는 알고 있으므로 모드도 함께 남긴다 — 예외로 끝난
            # 실행이야말로 실기기 실험에서 놓치면 안 되는 표본이다.
            #
            # 정지 여부도 정상 경로와 똑같이 소진해 넘긴다. 안 그러면
            # 사용자가 멈춘 뒤 컨트롤러가 예외로 끝난 실행이 '재시도 소진'
            # 으로 기록돼, 실험에서 실패율 분모에 섞인다.
            with self._lock:
                stopped_by_user = self._stop_requested_this_run
                stop_requested_at = self._stop_requested_at
                self._stop_requested_this_run = False
                self._stop_requested_at = None
            self._record_history(
                self._last_result,
                purpose,
                appliance_id,
                stopped_by_user,
                controller=controller,
                calibration_version=calibration_version,
                stop_requested_at=stop_requested_at,
            )
            # 보호자 알림도 남긴다 — 오히려 진짜 하드웨어 장애(UART 단절 등)
            # 일수록 예외로 끝나는데, 그게 알림함에서 빠지면 안 된다
            # (교차 리뷰 #7). 내부 예외 문구는 노출하지 않는다.
            if self._care_events is not None:
                label = purpose or ", ".join(buttons[:2])
                try:
                    self._care_events.append(
                        "execution_failed",
                        f"'{label}' 실행 중 가전과 연결이 끊겨 완료하지 "
                        "못했어요. 가전을 확인해 주세요.",
                        purpose=purpose,
                    )
                except Exception:
                    log.exception("care event record failed")
        finally:
            self._end_run()

    def _begin_run(
        self,
        total_steps: int | None,
        controller: ButtonSequenceController | None = None,
        appliance_id: str | None = None,
    ) -> str:
        """check-and-set을 락으로 원자화한 실행 시작 게이트.

        stop 토큰 리셋도 이 락 안에서 한다 — emergency_stop()이 같은 락을
        잡으므로 "접수 직후 정지"가 실행 스레드 시작 전에 와도 유실되지
        않는다: begin이 먼저면 stop이 뒤에 set되어 실행이 경계에서 멈추고,
        stop이 먼저면 begin이 리셋하지만 그 stop은 was_running=False로
        '실행 중 작업 없음'을 정확히 보고받는다.
        """
        with self._lock:
            self._guard_can_execute()
            self._running = True
            self._stop_requested_this_run = False
            self._stop_requested_at = None
            job_id = uuid.uuid4().hex[:12]
            self._current_job_id = job_id
            self._current_appliance_id = appliance_id
            self._current_total_steps = total_steps
            self._current_started_at = self._clock.now()
            if controller is not None:
                reset_stop = getattr(controller, "reset_stop", None)
                if reset_stop is not None:
                    reset_stop()
        if self._progress_tracker is not None:
            self._progress_tracker.clear()
        return job_id

    def _end_run(self) -> None:
        with self._lock:
            self._running = False
            self._last_job_id = self._current_job_id
            self._last_appliance_id = self._current_appliance_id
            self._current_job_id = None
            self._current_appliance_id = None
            self._current_total_steps = None
        if self._progress_tracker is not None:
            self._progress_tracker.clear()

    def _record_history(
        self,
        result: ExecutionResult,
        purpose: str | None,
        appliance_id: str | None = None,
        stopped_by_user: bool = False,
        controller: ButtonSequenceController | None = None,
        calibration_version: str | None = None,
        stop_requested_at: datetime | None = None,
    ) -> None:
        """실행 이력 기록 — 실패해도 실행 자체를 절대 막지 않는다.

        실기기 실험의 근거가 여기서 나온다(F4). 그래서 가전·실제/모의·
        시작 시각·종료 사유까지 함께 남긴다: 없으면 성공률의 분모를 가를 수
        없고, 정지 지연을 잴 수 없고, mock 실행이 실제 통계에 섞인다.
        """
        if self._history_store is None:
            return
        try:
            self._history_store.append(
                JobHistoryEntry(
                    job_id=self._current_job_id or "",
                    finished_at=self._clock.now(),
                    purpose=purpose,
                    status=result.status.value,
                    buttons=tuple(
                        ButtonAttempt(
                            b.button, b.status.value == "succeeded", b.attempts
                        )
                        for b in result.buttons
                    ),
                    appliance_id=appliance_id,
                    execution_mode=_mode_of(controller),
                    started_at=self._current_started_at,
                    # 실행 시작 시점의 스냅샷 -- 여기서 다시 조회하면
                    # 실행 중에 갱신된 값을 찍게 된다.
                    calibration_profile_version=calibration_version,
                    termination=self._termination_of(result, stopped_by_user),
                    # 정지로 끝난 실행에만 남긴다. 정지를 요청했지만
                    # 실행이 이미 성공으로 끝났다면 지연을 잰 것이
                    # 아니므로 비운다.
                    stop_requested_at=(
                        stop_requested_at if stopped_by_user else None
                    ),
                )
            )
        except Exception:
            log.exception("job history record failed")

    @staticmethod
    def _termination_of(
        result: ExecutionResult, stopped_by_user: bool
    ) -> Termination:
        """사용자가 멈춘 것과 스스로 포기한 것은 다른 사건이다.

        status 하나로 뭉개면 실험에서 정지 지연(사용자 정지)과 실패율(재시도
        소진)이 같은 표본에 섞인다.
        """
        if result.status is ExecutionStatus.SUCCEEDED:
            return Termination.COMPLETED
        return (
            Termination.STOPPED_BY_USER
            if stopped_by_user
            else Termination.RETRIES_EXHAUSTED
        )

    def _record_care_outcome(
        self,
        result: ExecutionResult,
        purpose: str | None,
        buttons: tuple[str, ...],
        stopped_by_user: bool,
    ) -> None:
        """보호자 알림 기록 — 실패해도 실행 자체를 절대 막지 않는다.

        긴급 정지로 끝난 실행(SAFETY_STOPPED)은 사용자가 의도한 중단이므로
        '실패'가 아니라 '멈춤'으로 알린다 — 같은 상태값이라도 보호자에게는
        전혀 다른 소식이다. 재시도 소진으로 스스로 멈춘 경우가 실패다."""
        if self._care_events is None:
            return
        if result.status is ExecutionStatus.SUCCEEDED:
            return
        label = purpose or ", ".join(buttons[:2]) + (
            f" 외 {len(buttons) - 2}개" if len(buttons) > 2 else ""
        )
        try:
            if stopped_by_user:
                self._care_events.append(
                    "emergency_stop",
                    f"'{label}' 실행을 긴급 정지로 멈췄어요.",
                    purpose=purpose,
                )
            else:
                self._care_events.append(
                    "execution_failed",
                    f"'{label}' 실행이 완료되지 못했어요. 가전을 확인해 주세요.",
                    purpose=purpose,
                )
        except Exception:
            log.exception("care event record failed")

    def _run_buttons(
        self,
        buttons: tuple[str, ...],
        controller: ButtonSequenceController,
        purpose: str | None,
        appliance_id: str | None = None,
        calibration_version: str | None = None,
    ) -> ExecutionResult:
        self._last_result = controller.execute(buttons)
        # stop 여부는 실행이 반환된 '직후' 스냅샷+소진한다 (교차 리뷰 #8) —
        # 이후에 도착한 stop이 자연 실패(재시도 소진)를 '긴급 정지로 멈춤'
        # 으로 오분류하는 창을 최소화한다. (완전 제거는 컨트롤러가 종료
        # 사유를 반환해야 가능 — 실기기 통합 때 termination_reason 검토)
        with self._lock:
            stopped_by_user = self._stop_requested_this_run
            stop_requested_at = self._stop_requested_at
            self._stop_requested_this_run = False
            self._stop_requested_at = None
        self._record_history(
            self._last_result,
            purpose,
            appliance_id,
            stopped_by_user,
            # 실제로 실행한 대상이 자기 모드를 말한다 -- 서버 전역 설정을
            # 쓰면 가전별 원격 노드로 라우팅된 실행이 로컬 설정값으로
            # 기록된다(실제 실행이 mock 통계에 섞인다).
            controller,
            calibration_version,
            stop_requested_at,
        )
        self._record_care_outcome(
            self._last_result, purpose, buttons, stopped_by_user
        )
        # purpose가 없는 실행(직접 버튼 시퀀스)은 의도적으로 학습 로그에서 제외
        if purpose is not None and self._usage_log is not None:
            outcome = (
                UsageOutcome.SUCCEEDED
                if self._last_result.status is ExecutionStatus.SUCCEEDED
                else UsageOutcome.FAILED
            )
            self._usage_log.append(
                UsageRecord(
                    self._clock.now(),
                    purpose.strip(),
                    outcome,
                    appliance_id=appliance_id,
                )
            )
        return self._last_result

    def _controller_for(self, appliance_id: str | None) -> ButtonSequenceController:
        """실행 대상 컨트롤러를 고른다 -- **모든 진입점의 합류점**이다.

        등록된 노드가 있으면 그쪽으로, 없으면 로컬 기본 컨트롤러로 간다.
        그 폴백은 **레지스트리에 존재하는 가전**에 한해서만 안전하다
        (내장 가전과, 실물 노드가 아직 없는 커스텀 가전). 존재하지 않는
        id까지 폴백하면 삭제된 선풍기의 버튼 시퀀스가 전자레인지
        갠트리에서 실행된다 -- 물리 오라우팅이다.

        검증이 여기 있는 이유: 예전에는 라우터의 직접 실행 3개 경로에만
        있어서 제안 승인이 그대로 통과했다. 진입점이 늘 때마다 같은
        구멍이 생기므로, 대상을 고르는 이 한 곳에서 거절한다.
        """
        self._require_known_appliance(appliance_id)
        controller = self._route_to(appliance_id)
        self._require_ready(appliance_id, controller)
        return controller

    def _calibration_snapshot(self, appliance_id: str | None) -> str | None:
        """**대상을 확정하는 순간의** 보정 프로파일 버전.

        실행이 끝난 뒤에 다시 읽으면 안 된다. 20초짜리 실행 도중 노드가
        새 보정을 보고하면, 끝나고 읽은 값은 그 실행이 실제로 쓴 좌표가
        아니다 -- v1로 돌린 결과가 v2의 성적표에 들어간다. 실험 데이터가
        조용히 오염되는 자리다.
        """
        if appliance_id is None or self._readiness_registry is None:
            return None
        return self._readiness_registry.get(
            appliance_id
        ).calibration_profile_version

    def _route_to(self, appliance_id: str | None) -> ButtonSequenceController:
        if appliance_id is not None and self._node_registry is not None:
            node_controller = self._node_registry.get(appliance_id)
            if node_controller is not None:
                return node_controller
        return self._controller

    def readiness_of(self, appliance_id: str):
        """이 가전을 지금 맡길 수 있나 — 화면이 상태와 사유를 보여줄 때 쓴다.

        노드가 없는 가전은 **조작 가능이라고 하지 않는다.** 로컬 폴백은
        하드웨어 없이 개발·데모를 돌리기 위한 편의지 준비 완료 선언이 아니다.
        """
        from rpi.services.readiness import ApplianceReadiness  # noqa: PLC0415

        if self._readiness_registry is None:
            return ApplianceReadiness.unknown(appliance_id)
        return self._readiness_registry.get(appliance_id)

    def runs_locally(self, appliance_id: str | None) -> bool:
        """이 가전을 로컬 갠트리로 실행해도 되는가.

        로컬 컨트롤러는 **내장 가전 위에 얹힌 갠트리**다. 그러니 로컬 실행이
        정당한 경우는 둘뿐이다:

        1. 내장 가전 -- 그 갠트리가 곧 이 가전의 액추에이터다.
        2. 명시적으로 로컬에 물렸다고 밝힌 커스텀 가전(데모 배선).

        노드 없는 커스텀 가전을 암묵적으로 여기로 흘리면, 선풍기 시퀀스가
        전자레인지의 엉뚱한 버튼을 누른다.
        """
        if appliance_id is None:
            return True  # 대상을 안 밝힌 실행 -- 기본 컨트롤러가 곧 대상이다
        if appliance_id in self._local_appliance_ids:
            return True
        if self._appliance_registry is None:
            return True  # 가전 개념이 없는 구성 -- 종전 동작 유지
        appliance = self._appliance_registry.get(appliance_id)
        return appliance is not None and not appliance.is_custom

    def _require_ready(
        self, appliance_id: str | None, controller: ButtonSequenceController
    ) -> None:
        """실행 대상이 **준비됐다고 확인된** 뒤에만 컨트롤러로 보낸다.

        로컬 컨트롤러로 가는 실행도 그냥 통과시키지 않는다. 노드가 없다는
        것은 '검사 대상이 아니다'가 아니라 대개 **액추에이터가 없다**는
        뜻이기 때문이다 -- runs_locally()가 정당한 로컬 대상만 가른다.

        heartbeat만으로 통과시키지 않는다: transport는 네 축 중 하나일 뿐이다.
        """
        if self._readiness_registry is None:
            return
        if controller is self._controller:
            if self.runs_locally(appliance_id):
                return
            # 노드도 없고 로컬 대상도 아니다 = 누를 액추에이터가 없다.
            raise ApplianceNotReadyError(
                appliance_id or "", ("아직 기기와 연결되지 않았어요",)
            )
        readiness = self._readiness_registry.get(appliance_id)
        if readiness.can_execute:
            return
        raise ApplianceNotReadyError(
            appliance_id, readiness.blocking_reasons
        )

    def _require_known_appliance(self, appliance_id: str | None) -> None:
        if appliance_id is None or self._appliance_registry is None:
            return
        if self._appliance_registry.get(appliance_id) is None:
            raise UnknownApplianceError(
                f"appliance '{appliance_id}' not found -- 삭제되었거나 "
                "등록되지 않은 가전입니다"
            )

    def emergency_stop(self) -> bool:
        """긴급 정지 — 로컬 기본 컨트롤러와 등록된 모든 노드 컨트롤러 중
        ``request_stop()``을 지원하는 대상 전부에 정지를 요청한다.

        어느 컨트롤러가 실행 중인지 추적하지 않고 전부에 요청하는 이유:
        정지 경로에서는 "덜 멈추는 것"이 "더 멈추는 것"보다 훨씬 위험하고,
        유휴 컨트롤러에 대한 요청은 다음 execute() 시작 시 무해하게 버려진다
        (ClosedLoopController.execute()의 clear() 참고).

        락 범위: 로컬 컨트롤러의 정지만 락 안에서 부른다. 이 호출은 플래그
        설정(ClosedLoopController) 또는 코루틴 예약(ActClientController)이라
        블로킹이 없고, ``_begin_run``의 ``reset_stop()``과 직렬화돼야
        "접수 직후 정지"가 리셋에 덮이지 않는다. 반면 원격 노드 정지는 HTTP
        요청이라 락 안에서 순차 실행하면 죽은 노드 하나당 최대 2초씩 정지가
        지연되고 그동안 /status·신규 실행 판정까지 막힌다 — 락을 놓고 병렬로
        보낸다(노드에는 reset_stop 개념이 없어 순서 보장이 불필요하다).

        반환값은 요청 시점에 실행이 진행 중이었는지 — 클라이언트가
        "정지됨"과 "실행 중인 작업 없음"을 구분해 표시할 수 있게 한다.
        """
        with self._lock:
            was_running = self._running
            if was_running:
                self._stop_requested_this_run = True
                # 지연의 기준점. 연타하면 **첫** 요청을 남긴다 --
                # 사용자가 멈추라고 한 순간은 그때다.
                if self._stop_requested_at is None:
                    self._stop_requested_at = self._clock.now()
            nodes = self._stoppable_nodes()
            local = self._controller
            if hasattr(local, "request_stop"):
                local.request_stop()

        self._broadcast_stop_to_nodes(nodes)
        return was_running

    def _broadcast_stop_to_nodes(
        self, nodes: list[ButtonSequenceController]
    ) -> None:
        """등록된 노드 전부에 병렬로 정지를 보낸다(전체 상한 있음).

        죽은 노드가 섞여 있어도 살아 있는 노드의 정지가 그 뒤에서 기다리지
        않게 한다. 상한을 넘긴 전송은 백그라운드에 두고 반환한다 — 정지
        요청을 더 보내는 것보다 호출자(폰의 긴급 정지 버튼)를 빨리 놓아주는
        편이 낫고, 각 요청 자체에도 개별 타임아웃이 있다.
        """
        if not nodes:
            return
        executor = ThreadPoolExecutor(
            max_workers=min(len(nodes), 8), thread_name_prefix="estop"
        )
        try:
            futures = [executor.submit(node.request_stop) for node in nodes]
            _, pending = wait(futures, timeout=EMERGENCY_STOP_BROADCAST_SECONDS)
            if pending:
                log.error(
                    "emergency stop: %d/%d node(s) did not confirm within %.1fs",
                    len(pending), len(nodes), EMERGENCY_STOP_BROADCAST_SECONDS,
                )
        finally:
            executor.shutdown(wait=False)

    def _stoppable_nodes(self) -> list[ButtonSequenceController]:
        if self._node_registry is None:
            return []
        nodes: list[ButtonSequenceController] = []
        for appliance_id in self._node_registry.list_appliance_ids():
            node = self._node_registry.get(appliance_id)
            if node is not None and hasattr(node, "request_stop"):
                nodes.append(node)
        return nodes

    def forward_demo_failure(self, button_index: int, attempts: int) -> None:
        """데모 실패 주입을 기본 컨트롤러에 전달 (지원 시 — UART 모드의
        ActClientController). 로컬 모드에서는 검증이 이 프로세스 안에서
        일어나 deps의 DemoFailureState가 직접 발동하므로 여기선 no-op."""
        inject = getattr(self._controller, "inject_failure", None)
        if inject is not None:
            inject(button_index, attempts)

    def clear_forwarded_demo_failure(self) -> None:
        clear = getattr(self._controller, "clear_failure", None)
        if clear is not None:
            clear()

    def _guard_can_execute(self) -> None:
        if not self._ready:
            raise ServiceNotReadyError(
                "service has not completed startup (call mark_ready() first)"
            )
        if self._shutting_down:
            raise ServiceNotReadyError(
                "service is shutting down and no longer accepts new purposes"
            )
        if self._running:
            raise RuntimeError("an execution is already in progress")

    def status(self) -> StatusSnapshot:
        ready = self._ready and not self._shutting_down
        progress = self._progress_tracker.current() if self._progress_tracker else None
        with self._lock:
            return StatusSnapshot(
                self._running,
                ready,
                self._last_result,
                progress,
                job_id=self._current_job_id,
                last_job_id=self._last_job_id,
                total_steps=self._current_total_steps,
                appliance_id=self._current_appliance_id,
                last_appliance_id=self._last_appliance_id,
            )
