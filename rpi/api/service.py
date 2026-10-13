import logging
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime

from rpi.controller import (
    ButtonSequenceController,
    ButtonTarget,
    ExecutionProgress,
    ExecutionProgressTracker,
    ExecutionResult,
    ExecutionStatus,
    outcome_of,
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
from rpi.intent.models import UsageSource
from rpi.intent.completed_actions import CompletedActions
from rpi.intent.rules import UnknownIntentError, RuleBasedIntentResolver
from rpi.services import NodeRegistry
from rpi.commands import ApprovalMismatchError, ControlRoute
from rpi.services.appliance_registry import BUILTIN_APPLIANCES

from .service_commands import CommandExecutionMixin, WrongRouteError
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

#: appliance_id 없는 옛 실행 요청의 대상 — 규칙 해석(즉석밥 등)이 쓰는 내장 갠트리 가전.
#: RPi4 execute에는 이 값을 **명시해** 싣는다(2026-10-07, 평가 H3). RPi4가 대상을 가정하지 않는다.
BUILTIN_GANTRY_APPLIANCE = "microwave"


@dataclass(frozen=True)
class EmergencyStopReport:
    """긴급 정지 요청을 **접수하고 전달한 결과**. 물리 정지 확인이 아니다.

    - ``was_running``: 요청 시점에 이 서버의 실행이 진행 중이었는지.
    - ``nodes_acknowledged``: 정지 요청을 받았다고 응답한 노드(가전 ID).
    - ``nodes_unconfirmed``: 전송 실패·오류 응답·기한 내 무응답, 또는 수신을
      확인할 수단이 없는 노드. 요청은 이 노드들에도 나갔다.
    """

    was_running: bool
    nodes_acknowledged: tuple[str, ...] = ()
    nodes_unconfirmed: tuple[str, ...] = ()
    #: ThinQ 명령을 보내기 전이라 취소한 가전(전송 안 됨).
    cloud_cancelled: tuple[str, ...] = ()
    #: 이미 보낸 ThinQ 명령 -- 취소할 수 없다. 가전 운전 정지는 자동으로 보내지 않는다.
    cloud_uncancellable: tuple[str, ...] = ()
    #: 모션 정지의 확인 단계(2026-10-13): sent | mcu_ack | verified, 보고 수단이 없거나 멈출 것이 없었으면 None.
    #: ``mcu_ack`` 이상만 확인이다(`rpi.services.stop_confirm`).
    motion_stop_level: str | None = None
    motion_stop_ack_ms: int | None = None
    #: RPi4가 멈춘 대상: run | dev | hold | idle | None(모름).
    motion_stop_target: str | None = None
    motion_stop_detail: str | None = None
    #: 이 정지가 멈춘 실행의 job_id(요청 시점에 실행 중이었을 때만). 클라이언트는 같은 실행일 때만 단계를 반영한다
    #: (평가 2026-10-13 H1 — 이전 정지의 늦은 보고가 새 실행에 섞이지 않게).
    job_id: str | None = None


class ServiceNotReadyError(RuntimeError):
    """Raised when execute_purpose is called before startup completes or after shutdown."""


def _mode_of(controller: object | None) -> ExecutionMode:
    """실행 대상이 스스로 밝힌 실제/모의 모드.

    밝히지 않으면 UNKNOWN이다. 라우팅 결과(원격이냐 로컬이냐)로
    추측하지 않는다 -- 전송이 원격이라는 사실은 저쪽이 실제로 눌렀는지에
    대해 아무것도 말해주지 않는다.
    """
    return getattr(controller, "execution_mode", ExecutionMode.UNKNOWN)


def _run_mode(controller: object | None, result: object | None) -> ExecutionMode:
    """이번 실행의 모드 -- 컨트롤러가 모른다고(UNKNOWN) 밝혔을 때만 결과의 보고를 쓴다.

    UART 링크(ActClientController)는 저쪽 보드가 실물을 돌렸는지 알 수 없어
    UNKNOWN이다. RPi4가 결과 프레임에 ``execution_mode``를 실어 보내면 그것이 근거다.
    컨트롤러가 스스로 MOCK이라고 밝혔으면(시뮬레이터) 보고로 REAL이 되지 않는다.
    """
    declared = _mode_of(controller)
    reported = getattr(result, "execution_mode", None)
    if declared is ExecutionMode.UNKNOWN and isinstance(reported, ExecutionMode):
        return reported
    return declared


_BUILTIN_IDS = frozenset(a.appliance_id for a in BUILTIN_APPLIANCES)

#: 콘센트 모듈 비상정지가 걸려 있을 때 화면에 그대로 보이는 사유(2026-10-05).
ESTOP_LATCHED_REASON = "비상정지가 걸려 있어요 — 버튼을 풀고 정지 해제 확인을 눌러 주세요"
#: RPi5가 다시 켜진 뒤 RPi4의 걸림 상태를 아직 모를 때(2026-10-06 평가 C1). '풀림'으로 보지 않는다.
ESTOP_UNKNOWN_REASON = "비상정지 상태를 확인하는 중이에요 — RPi4 응답을 기다려요"
#: RPi4(누름 장치) 링크가 끊겼거나 첫 연결 전일 때(2026-10-06 인계 §6). 걸림 상태도 모름이라 실행하지 않는다.
ACT_LINK_DOWN_REASON = "누름 장치 연결 안 됨 — 다시 연결하는 중이에요"


def _check_approved(buttons, approved_buttons) -> None:
    """결정 #1(승인 고정): 승인 카드가 보여 준 시퀀스와 지금 해석이 다르면 실행하지 않는다.

    승인 뒤 규칙·가전 기능이 바뀌어 해석이 달라졌다면 그것은 사용자가 승인한
    명령이 아니다 -- 새 카드로 다시 승인받는다(ApprovalMismatchError → 409).
    """
    if approved_buttons is not None and tuple(buttons) != tuple(approved_buttons):
        raise ApprovalMismatchError(
            f"승인 {' → '.join(approved_buttons)} / 지금 {' → '.join(buttons)}"
        )


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
    execution_mode: ExecutionMode = ExecutionMode.UNKNOWN
    last_execution_mode: ExecutionMode = ExecutionMode.UNKNOWN
    # ── 명령 계약(U1-a) — 실행 환경과 독립인 축 ──
    route: str | None = None
    last_route: str | None = None
    last_receipt: str | None = None
    last_confirmation: str | None = None
    last_detail: str | None = None
    #: ThinQ 등 명령 경로의 상태(succeeded/failed/stopped/unconfirmed). 물리는 None.
    last_command_status: str | None = None


class SimpleLayService(CommandExecutionMixin, PurposeExecutor):
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
        control_arbiter=None,
        completed_actions: CompletedActions | None = None,
        thinq_controller=None,
        system_controllers=None,
        job_listeners=(),
    ) -> None:
        # ThinQ 경로 실행기와 서버 구성 가전(모의 선풍기 등)의 실행기. 둘 다 없으면
        # 종전 동작 그대로다(service_commands.py).
        self._init_commands(thinq_controller, system_controllers)
        for listener in job_listeners:
            self.add_job_listener(listener)
        self.completed_actions = completed_actions or CompletedActions()
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
        self._execution_mode = ExecutionMode.UNKNOWN
        self._last_execution_mode = ExecutionMode.UNKNOWN
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
        # 마지막 긴급 정지의 모션 확인 단계(2026-10-13) — RPi4 정지 보고. 새 실행이 시작되면 지운다. _lock으로 보호.
        self._last_motion_stop: dict | None = None
        # 실행 세대(2026-10-13 H1) — _begin_run마다 1 오른다. 정지 보고가 늦게 와도 요청 때 세대와 다르면
        # (그 사이 새 실행이 시작됐으면) /status에 남기지 않는다. _lock으로 보호.
        self._run_generation = 0
        # 지금 실행의 시작 시각 — 소요시간을 재려면 필요하다. _lock으로 보호.
        self._current_started_at = None
        # 기계 제어권 중재자(ControlArbiter) — 개발자 세션과의 상호 배제.
        # None이면 일반 실행만 존재하는 구성(기존 테스트·rpi4 브리지)이라
        # 종전 동작 그대로다. 락 순서: 항상 self._lock 안에서 부른다 —
        # 중재자 락은 최내곽(leaf)이라 역전이 없다(control_arbiter.py 참고).
        self._control_arbiter = control_arbiter

    def mark_ready(self) -> None:
        """Declare that hardware dependencies finished initializing."""
        self._ready = True

    def request_shutdown(self) -> None:
        """Stop accepting new purposes; a running execution still completes."""
        self._shutting_down = True

    def execute_purpose(
        self, purpose: str, appliance_id: str | None = None,
        *, usage_source: UsageSource = UsageSource.DIRECT,
        approval_guard=None,
        expected_buttons: tuple[str, ...] | None = None,
        approved_buttons: tuple[str, ...] | None = None,
        approved_command=None,
    ) -> ExecutionResult:
        if self.route_of(appliance_id) is ControlRoute.THINQ:
            return self._submit_thinq_purpose(
                purpose, appliance_id, usage_source, approval_guard, background=False,
                expected_buttons=expected_buttons, approved_buttons=approved_buttons,
                approved_command=approved_command,
            )
        return self._execute_via_resolver(purpose, self._intent, appliance_id, usage_source, approval_guard, expected_buttons, approved_buttons)

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

    def _function_sequence(
        self, purpose: str, appliance_id: str | None
    ) -> tuple[str, ...] | None:
        """가전이 **스스로 정의한** 목적별 시퀀스가 있으면 그것을 쓴다.

        규칙·모델 해석보다 먼저다 -- 등록한 사람이 이 조작부에 맞춰 적은
        순서가 일반 규칙보다 정확하다. 없으면 None(종전 해석 경로).

        다이얼 회전 단계가 있으면 실행하지 않는다. 실행기가 아직 회전을
        모르므로, 앞 단계만 누르고 멈추면 반쯤 설정된 가전이 남는다.
        """
        if appliance_id is None or self._appliance_registry is None:
            return None
        appliance = self._appliance_registry.get(appliance_id)
        if appliance is None:
            return None  # 없는 가전은 뒤의 게이트가 404로 거절한다
        steps = appliance.function_steps(purpose)
        if steps is None:
            return None
        if any(step.turns is not None for step in steps):
            raise UnknownIntentError(
                f"'{purpose.strip()}'에는 다이얼 회전 단계가 있어 아직 실행할 수 "
                "없습니다 — 다이얼 구동부 연동 후 지원됩니다"
            )
        return tuple(step.label for step in steps)

    def _learning_purpose(self, purpose, buttons, resolver, appliance_id, defined):
        if defined is not None:
            return purpose.strip()
        normalize = getattr(resolver, "learning_purpose", None)
        if normalize is None:
            return purpose.strip()
        canonical = normalize(purpose, tuple(buttons))
        if canonical != purpose.strip() and self._appliance_registry is not None:
            appliance = self._appliance_registry.get(appliance_id)
            # A custom function with the canonical name may mean something else.
            if appliance is not None and appliance.function_steps(canonical) is not None:
                return purpose.strip()
        return canonical

    def _execute_via_resolver(
        self, purpose: str, resolver: IntentResolver, appliance_id: str | None = None,
        usage_source: UsageSource = UsageSource.DIRECT,
        approval_guard=None,
        expected_buttons: tuple[str, ...] | None = None,
        approved_buttons: tuple[str, ...] | None = None,
    ) -> ExecutionResult:
        defined = self._function_sequence(purpose, appliance_id)
        buttons = self._validate_resolved_sequence(
            defined if defined is not None else tuple(resolver.resolve(purpose))
        )
        _check_approved(buttons, approved_buttons)
        if expected_buttons is not None:
            if (tuple(buttons) != expected_buttons
                    or self.revision_options(appliance_id).get(purpose) != expected_buttons):
                raise UnknownIntentError('reviewed action changed; review again')
        controller = self._controller_for(appliance_id)
        calibration = self._calibration_snapshot(appliance_id)
        targets = self._targets_snapshot(appliance_id, tuple(buttons), controller)
        self._begin_run(len(buttons), controller, appliance_id, approval_guard)
        try:
            return self._run_buttons(
                tuple(buttons), controller, purpose, appliance_id, calibration, usage_source,
                self._learning_purpose(purpose, buttons, resolver, appliance_id, defined),
                targets=targets,
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
        buttons = self._validate_resolved_sequence(tuple(buttons))
        controller = self._controller_for(appliance_id)
        calibration = self._calibration_snapshot(appliance_id)
        targets = self._targets_snapshot(appliance_id, buttons, controller)
        self._begin_run(len(buttons), controller, appliance_id)
        try:
            # 목적은 없지만 대상 가전은 있다. 넘기지 않으면 수동 버튼
            # 실행의 이력이 '어느 가전에서'를 잃는다 — 커스텀 가전은
            # 대부분 이 경로로 조작되므로 실험 표본이 통째로 빈다.
            return self._run_buttons(
                buttons, controller, None, appliance_id, calibration, targets=targets
            )
        finally:
            self._end_run()

    # ── 비동기 job 모델 ──────────────────────────────────────────────────────
    # HTTP 엔드포인트용. 실기기에서 버튼 시퀀스는 수 초~수십 초 걸리는데
    # 클라이언트(폰 8초·키오스크 4초) 타임아웃 안에 동기 응답이 불가능하므로,
    # 의도 해석(즉시 실패 가능한 부분)만 동기로 끝내고 물리 실행은 백그라운드
    # 스레드로 넘긴 뒤 job_id를 즉시 돌려준다. 진행·완료는 /status 폴링으로.

    def submit_purpose(
        self, purpose: str, appliance_id: str | None = None,
        *, usage_source: UsageSource = UsageSource.DIRECT,
        approval_guard=None,
        expected_buttons: tuple[str, ...] | None = None,
        approved_buttons: tuple[str, ...] | None = None,
        approved_command=None,
    ) -> str:
        if self.route_of(appliance_id) is ControlRoute.THINQ:
            return self._submit_thinq_purpose(
                purpose, appliance_id, usage_source, approval_guard, background=True,
                expected_buttons=expected_buttons, approved_buttons=approved_buttons,
                approved_command=approved_command,
            )
        defined = self._function_sequence(purpose, appliance_id)
        buttons = defined if defined is not None else self._intent.resolve(purpose)
        if approved_buttons is not None:
            # 상한 거절(422, 카드 유지)이 불일치(409, 재승인)보다 먼저다.
            _check_approved(self._validate_resolved_sequence(tuple(buttons)), approved_buttons)
        if expected_buttons is not None:
            if (tuple(buttons) != expected_buttons
                    or self.revision_options(appliance_id).get(purpose) != expected_buttons):
                raise UnknownIntentError('reviewed action changed; review again')
        return self._submit(
            tuple(buttons), appliance_id, purpose, usage_source, approval_guard,
            self._learning_purpose(purpose, buttons, self._intent, appliance_id, defined),
        )

    def revision_options(self, appliance_id: str | None) -> dict[str, tuple[str, ...]]:
        """Only registered functions or built-in deterministic button sequences.

        No LLM, no movement, and no guesses for custom appliances.
        """
        if self._appliance_registry is None or appliance_id is None:
            return {}
        appliance = self._appliance_registry.get(appliance_id)
        if appliance is None:
            return {}
        labels = {b.label for b in appliance.buttons}
        names = [name for name, _ in appliance.functions]
        # Shared labels such as 'power' do not imply shared appliance semantics.
        # The built-in rule table is defined for the microwave demo; other
        # appliances must explicitly register their own functions.
        if appliance_id == 'microwave' and not appliance.is_custom:
            names.extend(RuleBasedIntentResolver.DEFAULT_RULES)
        choices = {}
        for name in names:
            try:
                defined = self._function_sequence(name, appliance_id)
                steps = (defined if defined is not None
                         else RuleBasedIntentResolver.DEFAULT_RULES.get(name, ()))
                steps = self._validate_resolved_sequence(tuple(steps))
                if steps and set(steps) <= labels:
                    choices[name] = steps
            except UnknownIntentError:
                continue
        return choices

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
        defined = self._function_sequence(purpose, appliance_id)
        if defined is not None:
            return self._submit(defined, appliance_id, purpose)
        resolver = LlmIntentResolver(self._llm_client, known_buttons=known_buttons)
        return self._submit(tuple(resolver.resolve(purpose)), appliance_id, purpose)

    def submit_buttons(
        self, buttons: tuple[str, ...], appliance_id: str | None = None
    ) -> str:
        return self._submit(tuple(buttons), appliance_id, purpose=None)

    def _submit(
        self, buttons: tuple[str, ...], appliance_id: str | None, purpose: str | None,
        usage_source: UsageSource = UsageSource.DIRECT,
        approval_guard=None,
        learning_purpose: str | None = None,
    ) -> str:
        # 모든 비동기 실행(/execute·/execute-buttons·/execute-for-appliance·
        # 제안 승인)의 합류점. 상한을 진입점마다 두면 제안 승인처럼 빠지는
        # 경로가 다시 생긴다 — 대상 확정·제어권 획득보다 먼저 거절한다.
        buttons = self._validate_resolved_sequence(tuple(buttons))
        controller = self._controller_for(appliance_id)
        # 보정 버전은 **대상을 확정하는 지금** 캡처해 실행 스레드로 넘긴다.
        # 스레드 안에서 다시 읽으면 실행 중에 갱신된 값을 찍는다.
        calibration = self._calibration_snapshot(appliance_id)
        # 좌표도 같은 순간에 잡는다 -- 보정 버전과 실제로 쓴 좌표가 어긋나지 않게.
        targets = self._targets_snapshot(appliance_id, buttons, controller)
        job_id = self._begin_run(len(buttons), controller, appliance_id, approval_guard)
        thread = threading.Thread(
            target=self._run_job,
            args=(buttons, controller, purpose, appliance_id, calibration, usage_source, learning_purpose),
            kwargs={"targets": targets},
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
        usage_source: UsageSource = UsageSource.DIRECT,
        learning_purpose: str | None = None,
        targets: "dict[str, ButtonTarget] | None" = None,
    ) -> None:
        try:
            self._run_buttons(
                buttons, controller, purpose, appliance_id, calibration_version, usage_source, learning_purpose,
                targets=targets,
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
        approval_guard=None,
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
            if approval_guard is not None:
                approval_guard()
            # 개발자 세션과의 상호 배제 — 확인과 점유가 중재자 안에서
            # 원자적이라, "확인은 통과했는데 그 사이 세션이 열리는" 창이
            # 없다. 실패는 ControlConflictError/ControlFaultedError
            # (RuntimeError)로 올라가 라우터에서 409가 된다.
            if self._control_arbiter is not None:
                self._control_arbiter.acquire(self._control_arbiter.EXECUTION)
            self._running = True
            self._stop_requested_this_run = False
            self._stop_requested_at = None
            self._last_motion_stop = None
            self._run_generation += 1
            self._stop_sticky = False
            self._current_route = ControlRoute.PHYSICAL
            job_id = uuid.uuid4().hex[:12]
            self._current_job_id = job_id
            self._execution_mode = _mode_of(controller)
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
            if self._control_arbiter is not None:
                self._control_arbiter.release(self._control_arbiter.EXECUTION)
            self._running = False
            self._last_job_id = self._current_job_id
            self._last_execution_mode = self._execution_mode
            self._execution_mode = ExecutionMode.UNKNOWN
            self._last_appliance_id = self._current_appliance_id
            self._last_route = self._current_route
            self._current_route = None
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
                    # 시나리오의 여러 단계는 job_id 뒤에 단계 번호를 붙인다.
                    job_id=self._history_job_id(),
                    # 명령 계약 열(경로·수신·확인 근거) — U1-a.
                    **self._physical_contract_fields(
                        result, getattr(self, "_physical_expected", None)
                    ),
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
                    execution_mode=_run_mode(controller, result),
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
                    outcome=outcome_of(result).value,
                    operation_confirmed=(
                        result.operation.passed if result.operation is not None else None
                    ),
                    operation_detail=(
                        result.operation.detail if result.operation is not None else ""
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
        usage_source: UsageSource = UsageSource.DIRECT,
        learning_purpose: str | None = None,
        targets: "dict[str, ButtonTarget] | None" = None,
    ) -> ExecutionResult:
        self._physical_expected = len(buttons)
        # 실행 대상 가전(2026-10-07, 평가 H3): RPi4 링크는 대상 없는 execute를 보내지 않는다. RPi4가 그 대상의
        # CT 채널로 L3·정지 확인을 고른다. appliance_id 없는 옛 요청은 규칙 해석과 같은 내장 갠트리 가전이다.
        arm_target = getattr(controller, "arm_execute_target", None)
        if callable(arm_target):
            arm_target(appliance_id if appliance_id is not None else BUILTIN_GANTRY_APPLIANCE)
        # 정지 대기·보관 계획(2026-09-30): 받는 대상(RPi4 링크)에만, 이번 실행 한 번에 싣는다.
        arm_hold = getattr(controller, "arm_stop_hold", None)
        arm_simulated = getattr(controller, "arm_simulated_stop_hold", None)
        if getattr(controller, "simulates_stop_hold", False) is True and callable(arm_simulated):
            # 전부 모의 등급(시뮬레이터)만 — 정지 버튼만 있어도 모의 위치로 대기를 흉내 낸다(M3).
            arm_simulated(self._appliance_registry, appliance_id)
        elif callable(arm_hold):
            from rpi.services.stop_park import hold_plan_for  # noqa: PLC0415

            arm_hold(hold_plan_for(self._appliance_registry, appliance_id))
        if targets:
            self._last_result = controller.execute(buttons, targets)
        else:
            # 좌표가 없으면 종전 호출 그대로 — targets를 모르는 구현도 받는다.
            self._last_result = controller.execute(buttons)
        run_mode = _run_mode(controller, self._last_result)
        with self._lock:
            # 원격이 보고한 모드로 이번 실행의 표시값을 고친다(_end_run이 last로 옮긴다).
            self._execution_mode = run_mode
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
        if (not stopped_by_user
                and self._last_result.status is ExecutionStatus.SUCCEEDED
                and run_mode is ExecutionMode.REAL
                and usage_source is UsageSource.DIRECT):
            try:
                self.completed_actions.remember(
                    appliance_id, learning_purpose or (purpose.strip() if purpose else None),
                    buttons, self._clock.now(),
                )
            except Exception:
                # Motion already succeeded. Keep the in-memory block and report
                # persistence trouble without changing the physical outcome.
                log.exception("completed action persistence failed")
        # purpose가 없는 실행(직접 버튼 시퀀스)은 의도적으로 학습 로그에서 제외
        if purpose is not None and self._usage_log is not None:
            outcome = (
                UsageOutcome.SUCCEEDED
                if self._last_result.status is ExecutionStatus.SUCCEEDED and not stopped_by_user
                else UsageOutcome.FAILED
            )
            self._usage_log.append(
                UsageRecord(
                    self._clock.now(),
                    learning_purpose or purpose.strip(),
                    outcome,
                    appliance_id=appliance_id,
                    execution_mode=run_mode,
                    source=usage_source,
                )
            )
        # 상태 표시용 계약 필드 + 완료 이벤트(시나리오 트리거가 듣는다).
        self._after_physical_run(
            self._last_result, buttons, controller, appliance_id, purpose, usage_source
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
        if self.route_of(appliance_id) is ControlRoute.THINQ:
            # ThinQ 가전에는 누를 조작부가 없다. 로컬 갠트리로 흘리면 전자레인지를
            # 누른다 -- 물리 오라우팅이므로 여기서 거절한다(422).
            raise WrongRouteError(
                f"'{appliance_id}'는 ThinQ 가전이라 버튼 시퀀스로 실행하지 않아요 — "
                "등록된 동작 이름으로 요청해 주세요"
            )
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

    def _targets_snapshot(
        self,
        appliance_id: str | None,
        buttons: tuple[str, ...],
        controller: ButtonSequenceController,
    ) -> "dict[str, ButtonTarget] | None":
        """대상을 확정하는 순간의 버튼 좌표(mm). 보정된 버튼만 싣는다.

        좌표를 받는다고 밝힌 실행 대상(``supports_button_targets``)에만 만든다.
        좌표가 없는 버튼을 거절할지는 실행 대상(모션 어댑터)이 정한다 --
        mock은 좌표 없이도 돌고, 실제 모션 어댑터는 누르기 전에 거절한다.
        격자 칸 번호(x, y)로 좌표를 만들지 않는다.
        """
        if appliance_id is None or self._appliance_registry is None:
            return None
        if getattr(controller, "supports_button_targets", False) is not True:
            return None
        appliance = self._appliance_registry.get(appliance_id)
        if appliance is None:
            return None
        by_label = {b.label: b for b in appliance.buttons if b.calibrated}
        targets = {
            step: ButtonTarget(by_label[step].x_mm, by_label[step].y_mm, by_label[step].press_ms)
            for step in buttons
            if step in by_label
        }
        return targets or None

    def _route_to(self, appliance_id: str | None) -> ButtonSequenceController:
        system = self._system_controllers.get(appliance_id) if appliance_id else None
        if system is not None:
            return system
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

    def system_mock_ready(self, appliance_id: str | None) -> bool | None:
        """서버 구성 실행기가 맡은 가전인가, 그렇다면 스스로 준비를 선언한 **모의** 실행기인가.

        서버 구성 실행기가 아니면 None. _require_ready와 같은 조건이다 — 화면 판정과 실행 거절이 어긋나지 않게.
        """
        controller = self._system_controllers.get(appliance_id) if appliance_id else None
        if controller is None:
            return None
        return (getattr(controller, "mock_ready", False) is True
                and _mode_of(controller) is ExecutionMode.MOCK)

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
        # 내장 가전만. 서버 구성 가전(ThinQ·모의 선풍기)은 is_custom이 아니지만
        # 로컬 갠트리의 대상이 아니다.
        return (appliance is not None and not appliance.is_custom
                and appliance_id in _BUILTIN_IDS)

    def _require_ready(
        self, appliance_id: str | None, controller: ButtonSequenceController
    ) -> None:
        if controller is self._controller:
            blocked = self.estop_block_reason()
            if blocked is not None:
                # 로컬 갠트리(RPi4)가 걸림을 보고했거나(RPi4도 거절한다) 아직 상태를 모른다 — 화면에 같은 사유를 준다.
                raise ApplianceNotReadyError(appliance_id or "", (blocked,))
        if (controller is not self._controller
                and controller in self._system_controllers.values()
                and getattr(controller, "mock_ready", False) is True
                and _mode_of(controller) is ExecutionMode.MOCK):
            # 서버 구성의 **모의** 실행기(예: 시나리오 선풍기)는 자기 준비를
            # 스스로 선언한다. 실제 노드 준비 상태(4축)를 대신하지 않는다.
            return
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

    @property
    def local_controller(self):
        """내장 가전의 실행 대상(UART면 RPi4 링크). 개발자 실물 어댑터가 RPi4 링크를 찾을 때 쓴다(2026-10-10)."""
        return self._controller

    def hold_status(self) -> dict | None:
        """로컬 실행 대상이 보고한 마지막 정지 대기 상태(없으면 None). 판정은 RPi4가 한다."""
        status = getattr(self._controller, "hold_status", None)
        try:
            return status() if callable(status) else None
        except Exception:  # noqa: BLE001 - 상태 조회 고장이 /status를 막지 않는다
            log.exception("hold status failed")
            return None

    def estop_status(self) -> dict | None:
        """로컬 실행 대상(RPi4)이 보고한 비상정지 걸림 ``{"latched", "detail"}``. 보고 수단이 없으면 None."""
        status = getattr(self._controller, "estop_status", None)
        if not callable(status):
            return None
        try:
            return status()
        except Exception:  # noqa: BLE001 - 상태 조회 고장이 /status를 막지 않는다
            log.exception("estop status failed")
            return None

    def estop_latched(self) -> bool:
        status = self.estop_status() or {}
        return status.get("latched") is True

    def estop_block_reason(self) -> str | None:
        """로컬 실행 대상을 막는 걸림 사유: 걸림(RPi4 보고, 재부팅으로 꺼진 콘센트 포함) → 링크 끊김·첫 연결 전
        (누름 장치 연결 안 됨) → 상태 모름(확인 중) 순."""
        status = self.estop_status() or {}
        if status.get("latched") is True:
            detail = status.get("detail")
            # RPi4가 이유를 따로 밝힌 걸림(예: 콘센트 모듈 재부팅)은 그 문장을 그대로 보인다.
            if isinstance(detail, str) and "다시 켜져" in detail:
                return detail
            return ESTOP_LATCHED_REASON
        if status.get("link_up") is False:
            return ACT_LINK_DOWN_REASON
        if status.get("known") is False:
            return ESTOP_UNKNOWN_REASON
        return None

    def actuator_link_up(self) -> bool | None:
        """로컬 실행 대상(RPi4)과의 링크. 링크를 보고하지 않는 실행 대상(로컬 모의 등)이면 None."""
        status = getattr(self._controller, "link_status", None)
        if not callable(status):
            return None
        try:
            return bool(status().get("link_up"))
        except Exception:  # noqa: BLE001 - 상태 조회 고장이 /status를 막지 않는다
            log.exception("link status failed")
            return None

    def acknowledge_estop(self) -> dict:
        """사람의 비상정지 해제 확인을 RPi4로 보낸다. 지원하지 않는 실행 대상이면 RuntimeError."""
        ack = getattr(self._controller, "acknowledge_estop", None)
        if not callable(ack):
            raise RuntimeError("이 실행기는 비상정지 걸림을 보고하지 않아요")
        return ack()

    def emergency_stop(self) -> bool:
        """``emergency_stop_report``의 호환 형태 — 실행 중이었는지만 돌려준다."""
        return self.emergency_stop_report().was_running

    def emergency_stop_report(self) -> EmergencyStopReport:
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
            # 이 정지를 지금 실행(세대·job)에 묶는다 — 보고는 락 밖에서 늦게 온다(H1).
            generation = self._run_generation
            stop_job_id = self._current_job_id if was_running else None
            stop_handle = None
            if hasattr(local, "request_stop"):
                stop_handle = local.request_stop()
            if was_running:
                # 시나리오의 남은 단계를 보내지 않게 단계 사이에도 남긴다.
                self._stop_sticky = True
            # ThinQ: 보내기 전이면 취소, 보냈으면 취소 불가로 보고(결정 #5).
            cloud_cancelled, cloud_uncancellable = self._stop_command_paths()

        acknowledged, unconfirmed = self._broadcast_stop_to_nodes(nodes)
        motion = self._motion_stop_report(local, generation, stop_job_id, was_running, stop_handle)
        return EmergencyStopReport(
            was_running=was_running,
            nodes_acknowledged=acknowledged,
            nodes_unconfirmed=unconfirmed,
            cloud_cancelled=cloud_cancelled,
            cloud_uncancellable=cloud_uncancellable,
            motion_stop_level=motion.get("stop_level"),
            motion_stop_ack_ms=motion.get("ack_ms"),
            motion_stop_target=motion.get("target"),
            motion_stop_detail=motion.get("stop_detail"),
            job_id=stop_job_id,
        )

    def _motion_stop_report(self, local: object, generation: int, job_id: str | None,
                            was_running: bool, handle: object = None) -> dict:
        """로컬 실행 대상(RPi4 링크)의 정지 확인 단계를 짧게 기다린다(락 밖, 2026-10-13). 정지는 이미 나갔다.

        보고 수단이 없는 대상(로컬 모의 폐루프)이면 빈 dict — 단계를 지어내지 않는다. 받은 보고는 RPi4가 무언가를
        멈췄을 때(run·dev·hold)나 실행 중이었을 때 /status에 남긴다.

        평가 2026-10-13 H1: 보고를 기다리는 사이 새 실행이 시작됐으면(세대가 바뀜) 남기지 않는다 — 새 실행의 초기화를
        옛 보고가 되돌리지 못하게. ``handle``(request_stop이 돌려준 그 정지)이 있으면 그 정지의 보고만 기다린다."""
        wait = getattr(local, "wait_stop_report", None)
        if not callable(wait):
            return {}
        try:
            report = wait(handle=handle) if handle is not None else wait()
        except Exception:  # noqa: BLE001 - 정지 확인 실패가 정지 응답을 막지 않는다
            log.exception("emergency stop: waiting for the motion stop report failed")
            return {}
        if not isinstance(report, dict):
            return {}
        with self._lock:
            if self._run_generation != generation:
                log.info("emergency stop: a newer run started before the stop report came back; not kept")
            elif report.get("target") in ("run", "dev", "hold") or was_running:
                self._last_motion_stop = {**report, "job_id": job_id}
        return report

    def last_motion_stop(self) -> dict | None:
        """마지막 긴급 정지의 모션 확인 단계(새 실행이 시작되면 None). /status가 옮긴다."""
        with self._lock:
            return dict(self._last_motion_stop) if self._last_motion_stop is not None else None

    def _broadcast_stop_to_nodes(
        self, nodes: list[tuple[str, ButtonSequenceController]]
    ) -> tuple[tuple[str, ...], tuple[str, ...]]:
        """등록된 노드 전부에 병렬로 정지를 보낸다(전체 상한 있음).

        죽은 노드가 섞여 있어도 살아 있는 노드의 정지가 그 뒤에서 기다리지
        않게 한다. 상한을 넘긴 전송은 백그라운드에 두고 반환한다 — 정지
        요청을 더 보내는 것보다 호출자(폰의 긴급 정지 버튼)를 빨리 놓아주는
        편이 낫고, 각 요청 자체에도 개별 타임아웃이 있다.

        반환값은 (받았다고 응답한 노드, 미확인 노드)의 가전 ID다. ``request_stop``이
        ``True``를 돌려준 노드만 받은 것으로 센다 — ``None``(수신 확인 수단 없음)·
        ``False``·예외·기한 초과는 모두 미확인이다.
        """
        if not nodes:
            return (), ()
        executor = ThreadPoolExecutor(
            max_workers=min(len(nodes), 8), thread_name_prefix="estop"
        )
        try:
            futures = {
                executor.submit(node.request_stop): appliance_id
                for appliance_id, node in nodes
            }
            _, pending = wait(futures, timeout=EMERGENCY_STOP_BROADCAST_SECONDS)
            if pending:
                log.error(
                    "emergency stop: %d/%d node(s) did not confirm within %.1fs",
                    len(pending), len(nodes), EMERGENCY_STOP_BROADCAST_SECONDS,
                )
        finally:
            executor.shutdown(wait=False)

        acknowledged: list[str] = []
        unconfirmed: list[str] = []
        for future, appliance_id in futures.items():
            if future in pending:
                unconfirmed.append(appliance_id)
                continue
            try:
                received = future.result() is True
            except Exception as exc:  # noqa: BLE001 -- 정지 결과 집계는 삼킨다
                log.error("emergency stop to %s raised: %s", appliance_id, exc)
                received = False
            (acknowledged if received else unconfirmed).append(appliance_id)
        return tuple(acknowledged), tuple(unconfirmed)

    def _stoppable_nodes(self) -> list[tuple[str, ButtonSequenceController]]:
        nodes: list[tuple[str, ButtonSequenceController]] = [
            (appliance_id, controller)
            for appliance_id, controller in self._system_controllers.items()
            if hasattr(controller, "request_stop")
        ]
        if self._node_registry is None:
            return nodes
        for appliance_id in self._node_registry.list_appliance_ids():
            node = self._node_registry.get(appliance_id)
            if node is not None and hasattr(node, "request_stop"):
                nodes.append((appliance_id, node))
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
                execution_mode=self._execution_mode,
                last_execution_mode=self._last_execution_mode,
                route=self._current_route.value if self._current_route else None,
                last_route=self._last_route.value if self._last_route else None,
                last_receipt=self._last_receipt.value if self._last_receipt else None,
                last_confirmation=(
                    self._last_confirmation.value if self._last_confirmation else None
                ),
                last_detail=self._last_detail,
                last_command_status=(
                    self._last_command_status.value if self._last_command_status else None
                ),
            )
