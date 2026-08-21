import logging
import threading
import uuid
from dataclasses import dataclass

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
from rpi.services import NodeRegistry

log = logging.getLogger(__name__)


class ServiceNotReadyError(RuntimeError):
    """Raised when execute_purpose is called before startup completes or after shutdown."""


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

    def _execute_via_resolver(
        self, purpose: str, resolver: IntentResolver, appliance_id: str | None = None
    ) -> ExecutionResult:
        buttons = resolver.resolve(purpose)
        self._begin_run(len(buttons))
        try:
            return self._run_buttons(tuple(buttons), appliance_id, purpose)
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
        self._begin_run(len(buttons))
        try:
            return self._run_buttons(buttons, appliance_id, purpose=None)
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
        buttons = resolver.resolve(purpose)
        return self._submit(tuple(buttons), appliance_id, purpose)

    def submit_buttons(
        self, buttons: tuple[str, ...], appliance_id: str | None = None
    ) -> str:
        return self._submit(tuple(buttons), appliance_id, purpose=None)

    def _submit(
        self, buttons: tuple[str, ...], appliance_id: str | None, purpose: str | None
    ) -> str:
        job_id = self._begin_run(len(buttons))
        thread = threading.Thread(
            target=self._run_job,
            args=(buttons, appliance_id, purpose),
            daemon=True,
            name=f"simplelay-exec-{job_id}",
        )
        thread.start()
        return job_id

    def _run_job(
        self, buttons: tuple[str, ...], appliance_id: str | None, purpose: str | None
    ) -> None:
        try:
            self._run_buttons(buttons, appliance_id, purpose)
        except Exception:
            # 백그라운드 스레드라 HTTP 500으로 표면화할 곳이 없다 — 로그를
            # 남기고 /status의 last_status="failed"로 실패를 노출한다.
            log.exception("background job execution failed")
            self._last_result = ExecutionResult(ExecutionStatus.FAILED, ())
        finally:
            self._end_run()

    def _begin_run(self, total_steps: int | None) -> str:
        """check-and-set을 락으로 원자화한 실행 시작 게이트."""
        with self._lock:
            self._guard_can_execute()
            self._running = True
            job_id = uuid.uuid4().hex[:12]
            self._current_job_id = job_id
            self._current_total_steps = total_steps
        if self._progress_tracker is not None:
            self._progress_tracker.clear()
        return job_id

    def _end_run(self) -> None:
        with self._lock:
            self._running = False
            self._last_job_id = self._current_job_id
            self._current_job_id = None
            self._current_total_steps = None
        if self._progress_tracker is not None:
            self._progress_tracker.clear()

    def _run_buttons(
        self, buttons: tuple[str, ...], appliance_id: str | None, purpose: str | None
    ) -> ExecutionResult:
        controller = self._controller_for(appliance_id)
        self._last_result = controller.execute(buttons)
        # purpose가 없는 실행(직접 버튼 시퀀스)은 의도적으로 학습 로그에서 제외
        if purpose is not None and self._usage_log is not None:
            outcome = (
                UsageOutcome.SUCCEEDED
                if self._last_result.status is ExecutionStatus.SUCCEEDED
                else UsageOutcome.FAILED
            )
            self._usage_log.append(
                UsageRecord(self._clock.now(), purpose.strip(), outcome)
            )
        return self._last_result

    def _controller_for(self, appliance_id: str | None) -> ButtonSequenceController:
        """Routes to the appliance's registered node if there is one,
        otherwise falls back to the local default controller (today's only
        behavior, and still the answer for the built-in appliance)."""
        if appliance_id is not None and self._node_registry is not None:
            node_controller = self._node_registry.get(appliance_id)
            if node_controller is not None:
                return node_controller
        return self._controller

    def emergency_stop(self) -> bool:
        """긴급 정지 — 로컬 기본 컨트롤러와 등록된 모든 노드 컨트롤러 중
        ``request_stop()``을 지원하는 대상 전부에 정지를 요청한다.

        어느 컨트롤러가 실행 중인지 추적하지 않고 전부에 요청하는 이유:
        정지 경로에서는 "덜 멈추는 것"이 "더 멈추는 것"보다 훨씬 위험하고,
        유휴 컨트롤러에 대한 요청은 다음 execute() 시작 시 무해하게 버려진다
        (ClosedLoopController.execute()의 clear() 참고).

        반환값은 요청 시점에 실행이 진행 중이었는지 — 클라이언트가
        "정지됨"과 "실행 중인 작업 없음"을 구분해 표시할 수 있게 한다.
        """
        was_running = self._running
        for controller in self._stoppable_controllers():
            controller.request_stop()
        return was_running

    def _stoppable_controllers(self) -> list[ButtonSequenceController]:
        controllers: list[ButtonSequenceController] = [self._controller]
        if self._node_registry is not None:
            for appliance_id in self._node_registry.list_appliance_ids():
                node = self._node_registry.get(appliance_id)
                if node is not None:
                    controllers.append(node)
        return [c for c in controllers if hasattr(c, "request_stop")]

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
            )
