"""제어권 중재자 — 일반 실행과 개발자 세션의 원자적 상호 배제.

Phase 0의 "서로 조회" 연결(execution_busy ↔ blocks_execution)은 두 락을
반대 순서로 잡아 교착이 가능했다(후속 교차 리뷰 #1). 여기서 못 박는 계약:

- 제어권은 acquire 한 곳에서 확인과 점유가 원자적이다 — 경합해도 둘 다
  통과하는 창이 없다.
- fault(정지 미확인)가 걸리면 어느 쪽도 제어권을 얻지 못한다.
- 실행기는 실행 시작에 제어권을 얻고, 어떤 경로로 끝나든(성공·실패·예외)
  반납한다.
"""

import threading

import pytest

from rpi.api import SimpleLayService
from rpi.controller import (
    ClosedLoopController,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import RuleBasedIntentResolver
from rpi.services.control_arbiter import (
    ControlArbiter,
    ControlConflictError,
    ControlFaultedError,
)
from rpi.verifier import MockVerifier


def _controller(outcomes=None):
    grbl = MockGrblClient()
    controller = ClosedLoopController(
        grbl,
        MockVerifier(outcomes or [True] * 50),
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
    )
    return controller, grbl


def _service(arbiter, controller=None):
    return SimpleLayService(
        RuleBasedIntentResolver(),
        controller if controller is not None else _controller()[0],
        control_arbiter=arbiter,
    )


# ── 중재자 단독 계약 ─────────────────────────────────────────────────────


def test_only_one_holder_at_a_time_and_release_frees_it() -> None:
    arbiter = ControlArbiter()
    arbiter.acquire(ControlArbiter.EXECUTION)

    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.DEVELOPER)
    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.EXECUTION)

    arbiter.release(ControlArbiter.EXECUTION)
    arbiter.acquire(ControlArbiter.DEVELOPER)
    assert arbiter.holder == ControlArbiter.DEVELOPER


def test_release_of_a_holder_you_do_not_have_is_a_noop() -> None:
    arbiter = ControlArbiter()
    arbiter.acquire(ControlArbiter.DEVELOPER)

    # 정지 경로는 여러 갈래라 이중 반납이 자연스럽게 생긴다 — 남의 것을
    # 벗겨내면 안 된다.
    arbiter.release(ControlArbiter.EXECUTION)
    assert arbiter.holder == ControlArbiter.DEVELOPER


def test_fault_locks_out_both_sides_until_cleared() -> None:
    arbiter = ControlArbiter()
    arbiter.trip_fault("stop_unconfirmed:heartbeat_timeout")

    with pytest.raises(ControlFaultedError):
        arbiter.acquire(ControlArbiter.EXECUTION)
    with pytest.raises(ControlFaultedError):
        arbiter.acquire(ControlArbiter.DEVELOPER)

    arbiter.clear_fault()
    arbiter.acquire(ControlArbiter.EXECUTION)


def test_conflict_error_names_the_current_holder() -> None:
    arbiter = ControlArbiter()
    arbiter.acquire(ControlArbiter.DEVELOPER)

    with pytest.raises(ControlConflictError) as exc_info:
        arbiter.acquire(ControlArbiter.EXECUTION)
    assert exc_info.value.holder == ControlArbiter.DEVELOPER
    # 사용자에게 보여줄 문구 — 내부 식별자가 아니라 상황 설명이어야 한다.
    assert "개발자 세션" in str(exc_info.value)


def test_concurrent_acquire_never_grants_two_holders() -> None:
    """경합 검증 — 확인과 점유가 원자적이지 않으면 active가 2를 찍는다."""
    arbiter = ControlArbiter()
    active = 0
    active_lock = threading.Lock()
    overlap: list[int] = []
    barrier = threading.Barrier(8)

    def worker(holder: str) -> None:
        nonlocal active
        barrier.wait()
        for _ in range(200):
            try:
                arbiter.acquire(holder)
            except ControlConflictError:
                continue
            with active_lock:
                active += 1
                if active > 1:
                    overlap.append(active)
            with active_lock:
                active -= 1
            arbiter.release(holder)

    threads = [
        threading.Thread(
            target=worker,
            args=(
                ControlArbiter.EXECUTION if i % 2 else ControlArbiter.DEVELOPER,
            ),
        )
        for i in range(8)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert overlap == []
    assert arbiter.holder is None


# ── 실행기 배선 ──────────────────────────────────────────────────────────


def test_execution_is_refused_while_developer_holds_control() -> None:
    arbiter = ControlArbiter()
    controller, grbl = _controller()
    service = _service(arbiter, controller)
    arbiter.acquire(ControlArbiter.DEVELOPER)

    with pytest.raises(ControlConflictError):
        service.execute_purpose("우유 데워줘")
    # 거절된 실행은 기계에 닿지 않는다.
    assert grbl.commands == []


def test_execution_is_refused_while_faulted() -> None:
    arbiter = ControlArbiter()
    service = _service(arbiter)
    arbiter.trip_fault("stop_unconfirmed:emergency_stop")

    with pytest.raises(ControlFaultedError):
        service.execute_purpose("우유 데워줘")


def test_execution_releases_control_on_success_and_failure() -> None:
    arbiter = ControlArbiter()
    service = _service(arbiter)
    service.execute_purpose("우유 데워줘")
    assert arbiter.holder is None

    failing = _service(arbiter, _controller([False] * 50)[0])
    failing.execute_purpose("우유 데워줘")
    assert arbiter.holder is None


def test_execution_releases_control_when_the_controller_raises() -> None:
    class _Exploding:
        def execute(self, buttons) -> ExecutionResult:
            raise RuntimeError("uart down")

    arbiter = ControlArbiter()
    service = SimpleLayService(
        RuleBasedIntentResolver(), _Exploding(), control_arbiter=arbiter
    )

    with pytest.raises(RuntimeError):
        service.execute_purpose("우유 데워줘")
    assert arbiter.holder is None


def test_developer_cannot_take_control_during_a_running_execution() -> None:
    """실행이 도는 동안 developer acquire는 거절되고, 끝나면 얻어진다."""
    started = threading.Event()
    release = threading.Event()

    class _Blocking:
        def execute(self, buttons) -> ExecutionResult:
            started.set()
            release.wait(timeout=5)
            return ExecutionResult(ExecutionStatus.SUCCEEDED, ())

    arbiter = ControlArbiter()
    service = SimpleLayService(
        RuleBasedIntentResolver(), _Blocking(), control_arbiter=arbiter
    )
    service.submit_purpose("우유 데워줘")
    assert started.wait(timeout=5)

    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.DEVELOPER)

    release.set()
    for _ in range(100):
        if not service.status().running:
            break
        threading.Event().wait(0.01)
    arbiter.acquire(ControlArbiter.DEVELOPER)
    assert arbiter.holder == ControlArbiter.DEVELOPER
