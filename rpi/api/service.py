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
        self._guard_can_execute()
        self._running = True
        if self._progress_tracker is not None:
            self._progress_tracker.clear()
        try:
            buttons = resolver.resolve(purpose)
            controller = self._controller_for(appliance_id)
            self._last_result = controller.execute(buttons)
            if self._usage_log is not None:
                outcome = (
                    UsageOutcome.SUCCEEDED
                    if self._last_result.status is ExecutionStatus.SUCCEEDED
                    else UsageOutcome.FAILED
                )
                self._usage_log.append(
                    UsageRecord(self._clock.now(), purpose.strip(), outcome)
                )
            return self._last_result
        finally:
            self._running = False
            if self._progress_tracker is not None:
                self._progress_tracker.clear()

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
        self._guard_can_execute()
        self._running = True
        if self._progress_tracker is not None:
            self._progress_tracker.clear()
        try:
            controller = self._controller_for(appliance_id)
            self._last_result = controller.execute(buttons)
            return self._last_result
        finally:
            self._running = False
            if self._progress_tracker is not None:
                self._progress_tracker.clear()

    def _controller_for(self, appliance_id: str | None) -> ButtonSequenceController:
        """Routes to the appliance's registered node if there is one,
        otherwise falls back to the local default controller (today's only
        behavior, and still the answer for the built-in appliance)."""
        if appliance_id is not None and self._node_registry is not None:
            node_controller = self._node_registry.get(appliance_id)
            if node_controller is not None:
                return node_controller
        return self._controller

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
        return StatusSnapshot(self._running, ready, self._last_result, progress)
