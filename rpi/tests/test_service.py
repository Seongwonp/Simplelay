from rpi.api import SimpleLayService
from rpi.api.service import LlmNotConfiguredError
from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import InMemoryUsageLog, RuleBasedIntentResolver, UnknownIntentError
from rpi.intent.mock import MockLlmClient
from rpi.verifier import MockVerifier


def test_rule_based_intent_executes_full_sequence():
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl, MockVerifier([True, True, True]), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(RuleBasedIntentResolver(), controller)

    result = service.execute_purpose("우유 데워줘")

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["해동", "시간 90초", "시작"]
    assert service.status().last_result is result
    assert service.status().running is False


def test_unknown_intent_does_not_leave_service_running():
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([]), MockAlertSink(), MockSafetyController()
        ),
    )

    try:
        service.execute_purpose("지원하지 않는 목적")
    except UnknownIntentError:
        pass
    else:
        raise AssertionError("UnknownIntentError was not raised")

    assert service.status().running is False


# ── execute_buttons (의도 해석 우회, 사용자 정의 가전용) ──────────────────────


def test_execute_buttons_runs_sequence_without_intent_resolution():
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl, MockVerifier([True, True]), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(RuleBasedIntentResolver(), controller)

    result = service.execute_buttons(("커스텀버튼A", "커스텀버튼B"))

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["커스텀버튼A", "커스텀버튼B"]
    assert service.status().last_result is result
    assert service.status().running is False


def test_execute_buttons_does_not_pollute_usage_log():
    usage_log = InMemoryUsageLog()
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([True]), MockAlertSink(), MockSafetyController()
        ),
        usage_log=usage_log,
    )

    service.execute_buttons(("버튼1",))

    # 목적 문자열이 없으므로 패턴 학습용 사용 로그에는 아무것도 안 남는다.
    assert usage_log.records() == ()


def test_execute_buttons_rejects_concurrent_execution():
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([True]), MockAlertSink(), MockSafetyController()
        ),
    )
    service._running = True

    try:
        service.execute_buttons(("버튼1",))
    except RuntimeError:
        pass
    else:
        raise AssertionError("RuntimeError was not raised")


# ── execute_purpose_for_appliance (커스텀 가전 음성 명령, LLM 기반) ────────────


def test_execute_purpose_for_appliance_resolves_via_llm_and_executes():
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl, MockVerifier([True, True]), MockAlertSink(), MockSafetyController()
    )
    llm = MockLlmClient({"해동해줘": '{"sequence": ["해동", "시작"]}'})
    service = SimpleLayService(RuleBasedIntentResolver(), controller, llm_client=llm)

    result = service.execute_purpose_for_appliance(
        "해동해줘", frozenset({"해동", "시작", "취소"})
    )

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [command.button for command in grbl.commands] == ["해동", "시작"]
    # 호출한 어휘가 그대로 LLM 클라이언트에 전달됐는지 확인
    assert llm.calls[0][1] == tuple(sorted({"해동", "시작", "취소"}))


def test_execute_purpose_for_appliance_without_llm_client_raises():
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([]), MockAlertSink(), MockSafetyController()
        ),
    )

    try:
        service.execute_purpose_for_appliance("아무거나", frozenset({"버튼"}))
    except LlmNotConfiguredError:
        pass
    else:
        raise AssertionError("LlmNotConfiguredError was not raised")


def test_execute_purpose_for_appliance_rejects_button_outside_vocabulary():
    llm = MockLlmClient({"이상한 명령": '{"sequence": ["등록안된버튼"]}'})
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([]), MockAlertSink(), MockSafetyController()
        ),
        llm_client=llm,
    )

    try:
        service.execute_purpose_for_appliance("이상한 명령", frozenset({"해동"}))
    except UnknownIntentError:
        pass
    else:
        raise AssertionError("UnknownIntentError was not raised")


def test_execute_purpose_for_appliance_logs_usage():
    usage_log = InMemoryUsageLog()
    llm = MockLlmClient({"불 꺼줘": '{"sequence": ["전원"]}'})
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            MockGrblClient(), MockVerifier([True]), MockAlertSink(), MockSafetyController()
        ),
        usage_log=usage_log,
        llm_client=llm,
    )

    service.execute_purpose_for_appliance("불 꺼줘", frozenset({"전원"}))

    assert len(usage_log.records()) == 1
    assert usage_log.records()[0].purpose == "불 꺼줘"


# ── emergency_stop (POST /stop 배선) ─────────────────────────────────────────


def test_emergency_stop_requests_stop_on_local_controller():
    controller = ClosedLoopController(
        MockGrblClient(), MockVerifier([]), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(RuleBasedIntentResolver(), controller)

    was_running = service.emergency_stop()

    assert was_running is False  # 유휴 상태 — 실행 중이던 작업 없음
    assert controller._stop_requested.is_set()  # 정지 요청은 컨트롤러까지 전달됐다


def test_emergency_stop_reaches_registered_node_controllers():
    class RecordingStoppable:
        def __init__(self):
            self.stopped = False

        def execute(self, buttons):
            raise AssertionError("not used in this test")

        def request_stop(self):
            self.stopped = True

    from rpi.services import NodeRegistry

    node = RecordingStoppable()
    registry = NodeRegistry(controller_factory=lambda base_url: node)
    registry.register("에어컨", "http://192.168.0.50:8080")
    local = ClosedLoopController(
        MockGrblClient(), MockVerifier([]), MockAlertSink(), MockSafetyController()
    )
    service = SimpleLayService(
        RuleBasedIntentResolver(), local, node_registry=registry
    )

    service.emergency_stop()

    assert node.stopped  # 등록된 노드 컨트롤러에도 정지가 전파된다
    assert local._stop_requested.is_set()
