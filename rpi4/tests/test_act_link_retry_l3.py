"""G1·G2 (2026-09-29): 재시도 수와 L3 판정이 UART 결과 프레임을 건너 RPi5 기록까지 살아남는다.

실제 ActClient(RPi5)와 실제 ActExecutor(RPi4)를 메모리 파이프로 잇는다. 결과 프레임을
``synthesize_from_act_result``로 합성한 뒤 이력(retry_count)·/status·SSE 공통 필드
(``result_detail_fields``)·확인 수준·시나리오 트리거까지 따라간다.
"""

from __future__ import annotations

import asyncio

import pytest

from rpi.api.router import result_detail_fields
from rpi.api.service_commands import JobFinishedEvent, _mode
from rpi.commands import Confirmation, ControlRoute, Receipt
from rpi.commands.physical import confirmation_of
from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ClosedLoopController,
    ExecutionMode,
    ExecutionOutcome,
    ExecutionResult,
    ExecutionStatus,
    VerificationLayer,
)
from rpi.controller.layered import OperationVerifier
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.models import LayerOutcome
from rpi.controller.power_operation import (
    MockPowerOperationVerifier,
    operation_verifier_from_env,
)
from rpi.controller.retry import DocumentedRetryPolicy
from rpi.intent.models import UsageSource
from rpi.services.act_client import ActClient
from rpi.services.aggregate_result import synthesize_execution_result, synthesize_from_act_result
from rpi.services.history import ButtonAttempt, JobHistoryEntry
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor

BUTTONS = ["즉석밥", "시작"]


class _PipeWriter:
    def __init__(self, peer: asyncio.StreamReader) -> None:
        self._peer = peer

    def write(self, data: bytes) -> None:
        self._peer.feed_data(data)

    async def drain(self) -> None:
        pass


class _RealGrbl(MockGrblClient):
    """실물 모터를 돌렸다고 밝히는 모션 어댑터 자리(테스트 전용)."""

    execution_mode = ExecutionMode.REAL


def _controller(outcomes, *, max_attempts=3, operation=None, grbl=None):
    return ClosedLoopController(
        grbl=grbl or MockGrblClient(),
        verifier=MockVerifier(outcomes=list(outcomes) + [True] * 20),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
        retry_policy=DocumentedRetryPolicy(max_attempts),
        operation=operation,
    )


def _roundtrip(controller, buttons=BUTTONS):
    async def _t():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        executor = ActExecutor(reader=rpi4_reader, writer=_PipeWriter(rpi5_reader),
                               controller=controller)
        client = ActClient(rpi5_reader, _PipeWriter(rpi4_reader))
        await client.start()
        task = asyncio.create_task(executor.run_once())
        act = await client.execute(list(buttons), sequence_id="g1")
        await task
        await client.stop()
        return act

    act = asyncio.run(_t())
    return act, synthesize_from_act_result(list(buttons), act)


def _history_retry(result: ExecutionResult) -> int:
    entry = JobHistoryEntry(
        "j", None, None, result.status.value,
        tuple(ButtonAttempt(b.button, b.status is ButtonStatus.SUCCEEDED, b.attempts)
              for b in result.buttons),
    )
    return entry.retry_count


# ── G1: 재시도 수 ────────────────────────────────────────────────────────


@pytest.mark.parametrize("retries", [0, 1, 2])
def test_success_keeps_retry_count_per_button(retries):
    # 첫 버튼(즉석밥)이 retries번 실패한 뒤 눌린다.
    act, result = _roundtrip(_controller([False] * retries))
    assert act.success is True and act.retry == retries
    assert act.button_results is not None
    assert [r.attempts for r in act.button_results] == [retries + 1, 1]
    assert result.status is ExecutionStatus.SUCCEEDED
    assert [b.attempts for b in result.buttons] == [retries + 1, 1]
    assert _history_retry(result) == retries
    assert result_detail_fields(result)["last_retry_count"] == retries
    # 재시도 누름마다 정성 보정이 함께 온다(첫 누름은 보정 없음).
    assert len(result.buttons[0].corrections) == retries


@pytest.mark.parametrize("retries", [0, 1, 2])
def test_failure_keeps_retry_count_and_layer(retries):
    # 첫 버튼이 끝내 안 눌린다 — 시도 상한이 retries+1.
    act, result = _roundtrip(_controller([False] * 10, max_attempts=retries + 1))
    assert act.success is False and act.outcome == "safety_stop"
    assert [r.attempts for r in act.button_results] == [retries + 1]
    assert result.outcome is ExecutionOutcome.SAFETY_STOP
    assert result.failed_layer is VerificationLayer.PRESS
    assert _history_retry(result) == retries
    assert result_detail_fields(result)["last_retry_count"] == retries


def test_stopped_keeps_retry_count():
    class Stopped:
        execution_mode = ExecutionMode.MOCK

        def execute(self, buttons):
            # 첫 버튼을 재시도 1회로 누른 뒤 정지 요청으로 멈춤(실패 버튼 없음).
            return ExecutionResult(ExecutionStatus.SAFETY_STOPPED,
                                   (ButtonResult(buttons[0], ButtonStatus.SUCCEEDED, 2, None),))

    act, result = _roundtrip(Stopped())
    assert act.outcome == "stopped"
    assert result.outcome is ExecutionOutcome.STOPPED
    assert _history_retry(result) == 1
    assert result_detail_fields(result)["last_retry_count"] == 1


def test_old_frame_without_button_results_still_keeps_aggregate_retry():
    # 옛 RPi4(버튼별 보고 없음): 성공이어도 집계 retry를 마지막 버튼에 싣는다.
    result = synthesize_execution_result(BUTTONS, True, 2)
    assert _history_retry(result) == 2
    failed = synthesize_execution_result(BUTTONS, False, 1, ExecutionOutcome.FAILED)
    assert failed.outcome is ExecutionOutcome.FAILED and _history_retry(failed) == 1


def test_no_buttons_means_retry_unknown_not_zero():
    assert result_detail_fields(None)["last_retry_count"] is None
    empty = ExecutionResult(ExecutionStatus.FAILED, ())
    assert result_detail_fields(empty)["last_retry_count"] is None


# ── G2: L3 판정(operation_confirmed) ─────────────────────────────────────


def test_l3_off_sends_null():
    act, result = _roundtrip(_controller([]))
    assert act.operation_confirmed is None and act.operation_detail is None
    assert result.operation is None
    fields = result_detail_fields(result)
    assert fields["last_operation_confirmed"] is None and fields["last_operation_source"] is None


def test_l3_mock_confirmed_is_true_but_not_evidence():
    act, result = _roundtrip(_controller([], operation=MockPowerOperationVerifier("confirmed")))
    assert act.success is True
    assert act.operation_confirmed is True and act.operation_source == "mock"
    assert act.operation_detail.startswith("모의 전력 센서")
    assert result.operation.passed and result.operation.mock
    # 합성 입력의 통과는 가열 근거가 아니다 → operation_confirmed 확인 수준으로 올리지 않는다.
    assert confirmation_of(result, len(BUTTONS)) is Confirmation.REPORTED
    assert result_detail_fields(result)["last_operation_source"] == "mock"


def test_l3_mock_unconfirmed_is_false_and_safety_stop():
    act, result = _roundtrip(_controller([], operation=MockPowerOperationVerifier("unconfirmed")))
    assert act.success is False and act.outcome == "safety_stop"
    assert act.operation_confirmed is False and act.operation_detail
    assert result.failed_layer is VerificationLayer.OPERATION
    fields = result_detail_fields(result)
    assert fields["last_operation_confirmed"] is False
    assert fields["last_operation_detail"]


class _RealPower(OperationVerifier):
    """실물 전력 판정 자리 — 통과를 실물 근거(mock=False)로 돌려준다(테스트 전용)."""

    def __init__(self, passed: bool) -> None:
        self._passed = passed

    def verify_operation(self, buttons):
        return LayerOutcome(VerificationLayer.OPERATION, self._passed,
                            "전력 상승 확인" if self._passed else "전력 상승 없음")


def test_real_l3_true_reaches_operation_confirmed():
    act, result = _roundtrip(_controller([], operation=_RealPower(True), grbl=_RealGrbl()))
    assert act.execution_mode == "real" and act.operation_source == "real"
    assert act.operation_confirmed is True
    assert result.execution_mode is ExecutionMode.REAL
    assert confirmation_of(result, len(BUTTONS)) is Confirmation.OPERATION_CONFIRMED


# ── G2: cook_then_air 트리거는 REAL + L3 실물 true일 때만 ─────────────────


class _Registry:
    def get(self, appliance_id):
        class A:
            name = appliance_id
            control_path = ControlRoute.THINQ
        return A()


class _Service:
    _appliance_registry = _Registry()

    def thinq_readiness(self, appliance_id):
        class R:
            can_execute = True
            reasons = ()
        return R()

    def summary_of(self, command):
        return command.target_id


def _engine():
    from rpi.scenarios import ScenarioCatalog, ScenarioEngine

    offered = []

    class Suggestions:
        def set_scenario_resolver(self, r):
            pass

        def create_scenario_suggestion(self, **kw):
            offered.append(kw)
            return kw

    return ScenarioEngine(ScenarioCatalog(), Suggestions(), _Service()), offered


class _UartLike:
    """ActClientController처럼 실행 환경을 모른다고 밝히는 컨트롤러."""

    execution_mode = ExecutionMode.UNKNOWN


def _finished(result):
    return JobFinishedEvent(
        "j", "microwave", ControlRoute.PHYSICAL, result.status.value, Receipt.ACCEPTED,
        confirmation_of(result, len(BUTTONS)), _mode(_UartLike(), result), UsageSource.DIRECT,
    )


def test_cook_then_air_real_trigger_only_on_real_confirmed_l3():
    engine, offered = _engine()
    _, confirmed = _roundtrip(_controller([], operation=_RealPower(True), grbl=_RealGrbl()))
    engine.on_job_finished(_finished(confirmed))
    assert len(offered) == 1
    assert offered[0]["scenario_id"] == "cook_then_air" and offered[0]["is_demo"] is False
    assert "L3" in offered[0]["reason"]


@pytest.mark.parametrize("case", ["no_l3", "mock_l3", "l3_false"])
def test_cook_then_air_real_no_trigger_without_confirmed_l3(case):
    engine, offered = _engine()
    operation = {"no_l3": None, "mock_l3": MockPowerOperationVerifier("confirmed"),
                 "l3_false": _RealPower(False)}[case]
    _, result = _roundtrip(_controller([], operation=operation, grbl=_RealGrbl()))
    assert result.execution_mode is ExecutionMode.REAL
    engine.on_job_finished(_finished(result))
    assert offered == []


def test_cook_then_air_mock_run_keeps_demo_card():
    engine, offered = _engine()
    _, result = _roundtrip(_controller([], operation=MockPowerOperationVerifier("confirmed")))
    assert result.execution_mode is ExecutionMode.MOCK
    engine.on_job_finished(_finished(result))
    assert len(offered) == 1 and offered[0]["is_demo"] is True
    assert "모의" in offered[0]["reason"]


# ── G2: SIMPLELAY_L3_MODE ─────────────────────────────────────────────────


def test_l3_mode_env():
    assert operation_verifier_from_env({}) is None
    assert operation_verifier_from_env({"SIMPLELAY_L3_MODE": "off"}) is None
    mock = operation_verifier_from_env({"SIMPLELAY_L3_MODE": "mock",
                                        "SIMPLELAY_L3_MOCK_OUTCOME": "unconfirmed"})
    assert isinstance(mock, MockPowerOperationVerifier) and mock.outcome == "unconfirmed"
    with pytest.raises(RuntimeError, match="아직 없습니다"):
        operation_verifier_from_env({"SIMPLELAY_L3_MODE": "real"})
    with pytest.raises(RuntimeError):
        operation_verifier_from_env({"SIMPLELAY_L3_MODE": "maybe"})
