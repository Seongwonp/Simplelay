"""개발자 모드 — 안전 불변식을 먼저 못 박는다.

하드웨어가 도착한 날 가장 먼저 필요한 것은 "올바른 가전과 노드를 골라 한 축을
안전하게 움직이고 즉시 멈추는 것"이다. 그 전에 계약이 흔들리지 않게 한다.

- 허용 목록 밖의 명령은 기계에 **닿지 않는다** (셸·raw·여러 명령 숨기기 포함)
- 제어권은 한 번에 하나 -- ControlArbiter에서 원자적으로 얻는다
- heartbeat가 끊기면 스스로 멈추고 세션을 닫는다 (판정은 단조 시계)
- 긴급 정지는 세션이 없어도, 명령이 틀려도, **느린 명령이 진행 중이어도**
  항상 먼저 닿는다
- 정지 실패는 세션 폐기 ≠ 장치 사용 가능 -- fault로 잠그고, 정지가 실제로
  확인될 때만 푼다
- 매 명령에서 대상 가전을 다시 확인한다 / 등록 안 된 버튼은 누르지 않는다
- 보정 안 된 가전은 누르지 않는다 / jog는 짧은 TTL로만 나간다
- 모든 요청은 request_id로 로그에 남고, 로그는 커지지 않는다
- Phase 1은 mock 어댑터 전용이다
"""

import threading
import time as real_time
from datetime import datetime, timedelta, timezone

import pytest

from rpi.services.control_arbiter import (
    ControlArbiter,
    ControlConflictError,
    ControlFaultedError,
)
from rpi.services.developer_session import (
    MAX_JOG_MM,
    DevAxis,
    DevCommandKind,
    DevCommandRejected,
    DeveloperSessionManager,
    DevSessionConflict,
    DevSessionExpired,
    DevTargetUnknownError,
    MockMotionAdapter,
    parse_dev_command,
)

_T0 = datetime(2026, 9, 24, 10, 0, tzinfo=timezone.utc)


class _Clock:
    """벽시계와 단조 시계를 함께 흉내 낸다. advance()는 둘 다 흐르게 하고,
    warp_wall()은 벽시계만 튼다(시스템 시각 변경 시나리오)."""

    def __init__(self) -> None:
        self.t = _T0
        self.mono_s = 1000.0

    def now(self) -> datetime:
        return self.t

    def mono(self) -> float:
        return self.mono_s

    def advance(self, seconds: float) -> None:
        self.t += timedelta(seconds=seconds)
        self.mono_s += seconds

    def warp_wall(self, seconds: float) -> None:
        self.t += timedelta(seconds=seconds)


def _manager(
    calibrated: bool = True,
    adapter: MockMotionAdapter | None = None,
    arbiter: ControlArbiter | None = None,
    known_appliance=None,
    known_button=None,
    **kwargs,
):
    adapter = adapter if adapter is not None else MockMotionAdapter()
    clock = _Clock()
    arbiter = arbiter if arbiter is not None else ControlArbiter()
    state = {"calibrated": calibrated}
    manager = DeveloperSessionManager(
        adapter=adapter,
        clock=clock,
        arbiter=arbiter,
        is_calibrated=lambda _appliance: state["calibrated"],
        known_appliance=known_appliance,
        known_button=known_button,
        monotonic=clock.mono,
        **kwargs,
    )
    return manager, adapter, clock, state, arbiter


# ── 명령 파서 ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("text", "normalized"),
    [
        ("status", "status"),
        ("  HOME ", "home"),
        ("sensor read", "sensor read"),
        ("stop", "stop"),
        ("jog x + 1", "jog x + 1"),
        ("jog Y - 0.5", "jog y - 0.5"),
        ("jog z + 0.2", "jog z + 0.2"),
        ("press BT-05", "press BT-05"),
    ],
)
def test_allowlisted_commands_are_normalized(text, normalized) -> None:
    assert parse_dev_command(text).normalized() == normalized


@pytest.mark.parametrize(
    "text",
    [
        "",
        "reboot",
        "status; rm -rf /",
        "status\nhome",
        "jog x + 1\x00",
        "jog x 1",
        "jog w + 1",
        "jog x * 1",
        "jog x + 0",
        "jog x + -1",
        f"jog x + {MAX_JOG_MM + 0.1}",
        "jog x + 1e3",
        "jog x + 1 extra",
        "press",
        "press BT 05",
        "press $(whoami)",
        "sensor",
        "sensor write",
        "G1 X10",
    ],
)
def test_anything_outside_the_allowlist_is_rejected(text) -> None:
    with pytest.raises(DevCommandRejected):
        parse_dev_command(text)


def test_jog_parses_axis_direction_and_amount() -> None:
    command = parse_dev_command("jog y - 2.5")
    assert command.kind is DevCommandKind.JOG
    assert command.axis is DevAxis.Y
    assert command.direction == -1
    assert command.amount_mm == 2.5


def test_rejected_command_never_reaches_the_adapter() -> None:
    manager, adapter, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "status; home")

    assert result.accepted is False
    assert adapter.motion_calls() == []


# ── 제어권 ────────────────────────────────────────────────────────────────


def test_only_one_session_holds_control() -> None:
    manager, _, _, _, _ = _manager()
    manager.start("microwave", "node-1")

    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-1")


def test_session_is_refused_while_normal_execution_runs() -> None:
    manager, _, _, _, arbiter = _manager()
    arbiter.acquire(ControlArbiter.EXECUTION)

    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-1")
    assert manager.session is None
    # 거절된 시작이 남의 제어권을 건드리지 않는다.
    assert arbiter.holder == ControlArbiter.EXECUTION


def test_open_session_holds_the_arbiter_until_it_ends() -> None:
    manager, _, _, _, arbiter = _manager()
    assert arbiter.holder is None

    session = manager.start("microwave", "node-1")
    assert arbiter.holder == ControlArbiter.DEVELOPER
    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.EXECUTION)

    manager.end(session.session_id)
    assert arbiter.holder is None
    arbiter.acquire(ControlArbiter.EXECUTION)


def test_start_races_with_execution_grant_only_one_winner() -> None:
    """세션 시작과 일반 실행 시작이 동시에 와도 한쪽만 이긴다."""
    for _ in range(50):
        manager, _, _, _, arbiter = _manager()
        results: dict[str, bool] = {}
        barrier = threading.Barrier(2)

        def dev(m=manager, r=results, b=barrier) -> None:
            b.wait()
            try:
                m.start("microwave", "node-1")
                r["dev"] = True
            except DevSessionConflict:
                r["dev"] = False

        def execution(a=arbiter, r=results, b=barrier) -> None:
            b.wait()
            try:
                a.acquire(ControlArbiter.EXECUTION)
                r["exec"] = True
            except ControlConflictError:
                r["exec"] = False

        t1 = threading.Thread(target=dev)
        t2 = threading.Thread(target=execution)
        t1.start(); t2.start(); t1.join(); t2.join()

        assert sorted(results.values()) == [False, True], results


def test_command_for_a_different_appliance_is_refused() -> None:
    manager, adapter, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "induction", "jog x + 1")

    assert result.accepted is False
    assert adapter.motion_calls() == []


def test_stale_session_id_is_refused() -> None:
    manager, adapter, _, _, _ = _manager()
    old = manager.start("microwave", "node-1")
    manager.end(old.session_id)
    manager.start("microwave", "node-1")

    result = manager.submit(old.session_id, "microwave", "home")

    assert result.accepted is False
    assert adapter.motion_calls() == []


def test_unknown_appliance_cannot_open_a_session() -> None:
    manager, _, _, _, arbiter = _manager(
        known_appliance=lambda appliance_id: appliance_id == "microwave"
    )

    with pytest.raises(DevTargetUnknownError):
        manager.start("ghost", "node-1")
    # 거절이 제어권을 점유하지 않는다.
    assert arbiter.holder is None
    manager.start("microwave", "node-1")


def test_unregistered_button_is_not_pressed() -> None:
    manager, adapter, _, _, _ = _manager(
        known_button=lambda appliance_id, button_id: button_id == "BT-01"
    )
    session = manager.start("microwave", "node-1")

    blocked = manager.submit(session.session_id, "microwave", "press BT-99")
    assert blocked.accepted is False
    assert adapter.motion_calls() == []

    allowed = manager.submit(session.session_id, "microwave", "press BT-01")
    assert allowed.accepted is True
    assert adapter.motion_calls() == [("press", "BT-01")]


# ── heartbeat ─────────────────────────────────────────────────────────────


def test_missing_heartbeat_stops_and_closes_the_session() -> None:
    manager, adapter, clock, _, arbiter = _manager()
    session = manager.start("microwave", "node-1")
    manager.submit(session.session_id, "microwave", "jog x + 1")

    clock.advance(3)
    reason = manager.tick()

    assert reason == "heartbeat_timeout"
    assert adapter.stops() == ["heartbeat_timeout"]
    assert manager.session is None
    assert arbiter.holder is None  # 제어권도 반납됐다
    after = manager.submit(session.session_id, "microwave", "jog x + 1")
    assert after.accepted is False
    assert len(adapter.motion_calls()) == 1


def test_heartbeat_keeps_the_session_alive() -> None:
    manager, adapter, clock, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    for _ in range(5):
        clock.advance(1.5)
        manager.heartbeat(session.session_id)

    assert manager.tick() is None
    assert adapter.stops() == []


def test_heartbeat_after_expiry_is_an_error_and_already_stopped() -> None:
    manager, adapter, clock, _, _ = _manager()
    session = manager.start("microwave", "node-1")
    clock.advance(3)

    with pytest.raises(DevSessionExpired):
        manager.heartbeat(session.session_id)
    assert adapter.stops() == ["heartbeat_timeout"]


def test_new_session_can_start_after_expiry() -> None:
    manager, _, clock, _, _ = _manager()
    manager.start("microwave", "node-1")
    clock.advance(3)

    fresh = manager.start("microwave", "node-2")

    assert fresh.node_id == "node-2"


def test_expiry_follows_the_monotonic_clock_not_the_wall_clock() -> None:
    """시스템 시각을 앞뒤로 틀어도 heartbeat TTL은 흔들리지 않는다."""
    manager, adapter, clock, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    # 벽시계만 하루 뒤로 -- NTP 보정·수동 변경 시나리오. 만료 아님.
    clock.warp_wall(86400)
    assert manager.tick() is None
    assert manager.session is not None

    # 벽시계만 과거로 틀어도, 단조 시계가 지나면 만료다.
    clock.warp_wall(-172800)
    clock.mono_s += 3
    assert manager.tick() == "heartbeat_timeout"
    assert adapter.stops() == ["heartbeat_timeout"]
    assert manager.submit(
        session.session_id, "microwave", "home"
    ).accepted is False


def test_watchdog_thread_expires_sessions_without_external_ticks() -> None:
    """자체 감시 -- 아무도 tick()을 불러 주지 않아도 스스로 멈춘다."""
    adapter = MockMotionAdapter()
    arbiter = ControlArbiter()
    manager = DeveloperSessionManager(
        adapter=adapter,
        clock=type("_C", (), {"now": staticmethod(lambda: _T0)})(),
        arbiter=arbiter,
        is_calibrated=lambda _a: True,
        heartbeat_ttl=timedelta(seconds=0.05),
        monotonic=real_time.monotonic,
        watchdog_interval_s=0.02,
    )
    manager.start("microwave", "node-1")

    deadline = real_time.monotonic() + 2.0
    while manager.session is not None and real_time.monotonic() < deadline:
        real_time.sleep(0.01)

    assert manager.session is None
    assert adapter.stops() == ["heartbeat_timeout"]
    assert arbiter.holder is None
    manager.close()


def test_close_stops_an_open_session_and_refuses_new_ones() -> None:
    manager, adapter, _, _, arbiter = _manager()
    manager.start("microwave", "node-1")

    manager.close()

    assert adapter.stops() == ["server_shutdown"]
    assert manager.session is None
    assert arbiter.holder is None
    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-1")


# ── 정지 ──────────────────────────────────────────────────────────────────


def test_emergency_stop_reaches_adapter_without_any_session() -> None:
    manager, adapter, _, _, _ = _manager()

    manager.emergency_stop()

    assert adapter.stops() == ["emergency_stop"]


def test_emergency_stop_ends_the_session() -> None:
    manager, adapter, _, _, arbiter = _manager()
    session = manager.start("microwave", "node-1")

    manager.emergency_stop()

    assert manager.session is None
    assert arbiter.holder is None
    assert adapter.stops() == ["emergency_stop"]
    assert manager.submit(session.session_id, "microwave", "home").accepted is False


def test_stop_command_works_even_with_wrong_session_or_appliance() -> None:
    manager, adapter, _, _, _ = _manager()
    manager.start("microwave", "node-1")

    result = manager.submit("not-a-session", "induction", "stop")

    assert result.accepted is True
    assert adapter.stops() == ["user_stop"]
    assert manager.session is None


class _BrokenStopAdapter(MockMotionAdapter):
    """stop이 실패하는 어댑터 -- broken=False로 바꾸면 다시 성공한다."""

    def __init__(self) -> None:
        super().__init__()
        self.broken = True

    def stop(self, reason: str) -> None:
        super().stop(reason)
        if self.broken:
            raise RuntimeError("link down")


def test_failed_stop_closes_the_session_but_locks_the_machine() -> None:
    """정지 실패 = 세션 폐기 + 장치 잠금. 세션만 지우고 끝이 아니다."""
    adapter = _BrokenStopAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    manager.start("microwave", "node-1")

    with pytest.raises(RuntimeError):
        manager.emergency_stop()

    # 기계 상태를 모르는 채로 제어권을 남기지 않는다.
    assert manager.session is None
    assert adapter.stops() == ["emergency_stop"]
    # 그러나 장치는 사용 가능이 아니다 -- 실행도 새 세션도 잠긴다.
    assert (arbiter.fault_reason or "").startswith("stop_unconfirmed:")
    with pytest.raises(ControlFaultedError):
        arbiter.acquire(ControlArbiter.EXECUTION)
    with pytest.raises(ControlFaultedError):
        manager.start("microwave", "node-1")


def test_confirmed_stop_clears_the_fault() -> None:
    """복구는 명시적이다 -- 이후 긴급 정지가 실제로 확인되면 푼다."""
    adapter = _BrokenStopAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    manager.start("microwave", "node-1")
    with pytest.raises(RuntimeError):
        manager.emergency_stop()

    adapter.broken = False
    manager.emergency_stop()  # 이번에는 확인됨

    assert arbiter.fault_reason is None
    manager.start("microwave", "node-1")  # 다시 열린다


def test_user_stop_reports_failure_instead_of_pretending() -> None:
    adapter = _BrokenStopAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "stop")

    assert result.accepted is False
    assert "확인하지 못했" in (result.reason or "")
    assert (arbiter.fault_reason or "").startswith("stop_unconfirmed:")


def test_idle_stop_failure_does_not_lock_the_machine() -> None:
    """세션 없이(움직이던 주체 없음) 정지가 실패한 것은 잠글 일이 아니다 --
    유휴 상태의 어댑터 단절로 시스템 전체가 잠기면 안 된다."""
    adapter = _BrokenStopAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)

    with pytest.raises(RuntimeError):
        manager.emergency_stop()

    assert arbiter.fault_reason is None


# ── 정지 vs 느린 명령 (락 밖 디스패치) ───────────────────────────────────


class _SlowPressAdapter(MockMotionAdapter):
    """press가 **전달 후 응답 대기** 중에 멈춰 있는 어댑터(기록이 먼저) --
    즉시 반환하는 mock으로는 '정지가 명령 처리를 기다리는' 결함이 드러나지
    않는다(교차 리뷰 #2). '전달 직전' 지연은 _GatedPressAdapter가 재현한다."""

    def __init__(self) -> None:
        super().__init__()
        self.entered = threading.Event()
        self.release = threading.Event()

    def press(self, button_id: str) -> None:
        super().press(button_id)
        self.entered.set()
        assert self.release.wait(timeout=5)


class _GatedPressAdapter(MockMotionAdapter):
    """press가 **전달 직전에** 멈춰 있는 어댑터(기록이 게이트 뒤) --
    '정지가 먼저 기계에 닿고, 그 뒤에야 명령이 전달되는' 경합을 실제
    호출 순서로 재현한다(후속 리뷰 1.1-#2의 fake 보강)."""

    def __init__(self) -> None:
        super().__init__()
        self.arrived = threading.Event()
        self.gate = threading.Event()

    def press(self, button_id: str) -> None:
        self.arrived.set()
        assert self.gate.wait(timeout=5)
        super().press(button_id)


def test_emergency_stop_does_not_wait_for_a_slow_command() -> None:
    adapter = _SlowPressAdapter()
    manager, _, _, _, _ = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    worker = threading.Thread(
        target=manager.submit,
        args=(session.session_id, "microwave", "press BT-05"),
    )
    worker.start()
    assert adapter.entered.wait(timeout=5)  # press가 어댑터 안에서 블로킹 중

    done = threading.Event()

    def stop() -> None:
        manager.emergency_stop()
        done.set()

    stopper = threading.Thread(target=stop)
    stopper.start()
    # press가 아직 블로킹 중인데도 정지가 어댑터에 닿고 반환된다.
    assert done.wait(timeout=2), "정지가 느린 명령을 기다리고 있다"
    assert "stop" in [c[0] for c in adapter.calls]
    assert manager.session is None

    adapter.release.set()
    worker.join(timeout=5)
    stopper.join(timeout=5)


def test_command_that_raced_past_a_stop_is_stopped_again() -> None:
    """정지 뒤에 어댑터에 닿은(늦은) 명령은 감지되어 즉시 재정지된다 --
    단순히 호출을 락 밖으로 옮기기만 하면 생기는 구멍(교차 리뷰 #2)."""
    adapter = _SlowPressAdapter()
    manager, _, _, _, _ = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    results: list = []
    worker = threading.Thread(
        target=lambda: results.append(
            manager.submit(session.session_id, "microwave", "press BT-05")
        )
    )
    worker.start()
    assert adapter.entered.wait(timeout=5)

    stopper = threading.Thread(target=manager.emergency_stop)
    stopper.start()
    deadline = real_time.monotonic() + 2
    while "stop" not in [c[0] for c in adapter.calls]:
        assert real_time.monotonic() < deadline
        real_time.sleep(0.005)

    adapter.release.set()  # 이제 press가 (정지 뒤에) 끝난다
    worker.join(timeout=5)
    stopper.join(timeout=5)

    [result] = results
    assert result.accepted is False
    # 최종 상태는 '멈춤' -- 늦은 명령 뒤에 정지가 한 번 더 나갔다.
    assert adapter.stops()[-1] == "stop_after_late_command"


def test_control_is_not_released_until_the_late_command_is_dead() -> None:
    """정지 성공 ≠ 제어권 반납. 이전 명령이 어댑터 안에 살아 있는 동안은
    stopping 상태로 남아 새 실행·새 세션이 거절되고, 그 명령의 무효화
    (재정지 확인) 뒤에야 제어권이 나간다(후속 리뷰 1.1-#1)."""
    adapter = _GatedPressAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    results: list = []
    worker = threading.Thread(
        target=lambda: results.append(
            manager.submit(session.session_id, "microwave", "press BT-05")
        )
    )
    worker.start()
    assert adapter.arrived.wait(timeout=5)  # press가 전달 직전에 멈춰 있다

    manager.emergency_stop()  # 즉시 반환 -- 명령을 기다리지 않는다
    assert manager.session is None
    assert adapter.stops() == ["emergency_stop"]  # 정지는 이미 기계에 닿았다

    # stopping 상태 -- "마지막 호출이 stop"이지만 이전 press가 살아 있으므로
    # 어느 쪽도 제어권을 얻지 못한다.
    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.EXECUTION)
    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-2")

    adapter.gate.set()  # 이제야 press가 (정지 뒤에) 전달된다
    worker.join(timeout=5)
    [result] = results
    assert result.accepted is False
    # 어댑터 명령 흐름: stop → 늦은 press → 재정지. 마지막은 항상 stop이다.
    assert [c[0] for c in adapter.calls] == ["stop", "press", "stop"]
    assert adapter.stops() == ["emergency_stop", "stop_after_late_command"]
    # 무효화가 확인된 뒤에야 제어권이 나간다.
    arbiter.acquire(ControlArbiter.EXECUTION)


def test_dispatch_exception_still_settles_with_a_stop() -> None:
    """어댑터 예외로 끝난 명령은 전달 여부를 모른다 -- 정리(정지)를
    건너뛰지 않는다(후속 리뷰 1.1-#2). 정지가 확인되면 세션은 유지된다."""

    class _ExplodingPress(MockMotionAdapter):
        def press(self, button_id: str) -> None:
            super().press(button_id)
            raise RuntimeError("uart timeout mid-flight")

    adapter = _ExplodingPress()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "press BT-05")

    assert result.accepted is False
    assert "정지를 보냈습니다" in (result.reason or "")
    assert adapter.stops() == ["command_error"]
    # 정지가 확인됐으니 세션·제어권은 유지 -- 다시 시도할 수 있다.
    assert manager.session is not None
    assert arbiter.holder == ControlArbiter.DEVELOPER
    assert manager.submit(session.session_id, "microwave", "home").accepted


def test_dispatch_exception_with_unconfirmed_stop_locks_the_machine() -> None:
    """명령도 예외, 정리 정지도 실패 -- 동작·정지 어느 쪽도 확인하지
    못했으므로 세션 폐기 + 장치 잠금이다(후속 리뷰 1.1-#2)."""

    class _DeadLink(MockMotionAdapter):
        def press(self, button_id: str) -> None:
            super().press(button_id)
            raise RuntimeError("link down")

        def stop(self, reason: str) -> None:
            super().stop(reason)
            raise RuntimeError("link down")

    adapter = _DeadLink()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "press BT-05")

    assert result.accepted is False
    assert "잠갔" in (result.reason or "")
    assert manager.session is None
    assert (arbiter.fault_reason or "").startswith("stop_unconfirmed:")
    with pytest.raises(ControlFaultedError):
        arbiter.acquire(ControlArbiter.EXECUTION)


class _BlockedRecoveryAdapter(MockMotionAdapter):
    """press는 예외로 끝나고, 그 **복구 정지(command_error)** 가 게이트에서
    멈춰 있는 어댑터 -- '명령은 끝났지만 안전 정리는 진행 중'인 창을
    결정적으로 재현한다(후속 리뷰 1.2). recovery_fails로 그 정리의
    성공/실패를 고른다. 다른 이유의 stop(긴급 정지 등)은 즉시 통과한다."""

    def __init__(self, *, recovery_fails: bool) -> None:
        super().__init__()
        self.recovery_fails = recovery_fails
        self.recovery_entered = threading.Event()
        self.recovery_gate = threading.Event()

    def press(self, button_id: str) -> None:
        super().press(button_id)
        raise RuntimeError("uart timeout mid-flight")

    def stop(self, reason: str) -> None:
        if reason == "command_error":
            self.recovery_entered.set()
            assert self.recovery_gate.wait(timeout=5)
            super().stop(reason)
            if self.recovery_fails:
                raise RuntimeError("link down")
            return
        super().stop(reason)


def test_control_is_held_while_the_recovery_stop_is_still_running() -> None:
    """명령 완료 ≠ 안전 정리 완료. 복구 정지가 어댑터 안에 살아 있는 동안
    별도 긴급 정지가 와도 제어권은 반납되지 않는다(후속 리뷰 1.2) --
    이전에는 settle 초입의 _inflight=False 때문에 이 창에서 반납됐다."""
    adapter = _BlockedRecoveryAdapter(recovery_fails=False)
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    results: list = []
    worker = threading.Thread(
        target=lambda: results.append(
            manager.submit(session.session_id, "microwave", "press BT-05")
        )
    )
    worker.start()
    assert adapter.recovery_entered.wait(timeout=5)  # 정리 정지가 진행 중

    manager.emergency_stop()  # 즉시 반환 -- 정리를 기다리지 않는다
    assert manager.session is None

    # 정리가 끝나기 전에는 어느 쪽도 제어권을 얻지 못한다.
    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.EXECUTION)
    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-2")

    adapter.recovery_gate.set()
    worker.join(timeout=5)
    [result] = results
    assert result.accepted is False
    # 정리 완료 뒤에야 제어권이 나가고, fault 없이 정상 재개된다.
    assert arbiter.fault_reason is None
    arbiter.acquire(ControlArbiter.EXECUTION)


def test_stale_recovery_failure_does_not_kill_the_next_session() -> None:
    """지연된 복구 정지가 **실패**해도, 그 사이 별도 정지가 이미 닫은
    세션 세대를 넘어 현재 세션을 폐기하거나 제어권을 벗겨내지 않는다
    (후속 리뷰 1.2 -- 세대(epoch) 확인 후에만 자기 세션을 닫는다)."""
    adapter = _BlockedRecoveryAdapter(recovery_fails=True)
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    results: list = []
    worker = threading.Thread(
        target=lambda: results.append(
            manager.submit(session.session_id, "microwave", "press BT-05")
        )
    )
    worker.start()
    assert adapter.recovery_entered.wait(timeout=5)

    manager.emergency_stop()  # 세션 A를 닫는다(epoch 증가)

    adapter.recovery_gate.set()  # 이제 A의 복구 정지가 '실패'로 끝난다
    worker.join(timeout=5)
    [result] = results
    assert result.accepted is False

    # 정리 실패 = 기계 상태 불명 -- 잠그는 것이 맞다. 그러나 남의 세션을
    # 닫는 일은 없다(이 시점에 세션이 없었고, 있었다면 그 소유였다).
    assert (arbiter.fault_reason or "").startswith("stop_unconfirmed:")
    assert manager.session is None
    with pytest.raises(ControlFaultedError):
        arbiter.acquire(ControlArbiter.EXECUTION)

    # 문서화된 복구 절차: 긴급 정지가 실제로 확인되면 풀린다.
    manager.emergency_stop()
    assert arbiter.fault_reason is None
    manager.start("microwave", "node-2")


def test_stale_settle_success_does_not_clear_someone_elses_fault() -> None:
    """오래된 정리의 성공(재정지 확인)이 그 사이 다른 주체가 건 fault를
    해제하면 안 된다(후속 리뷰 1.2) -- fault 해제는 긴급 정지 확인
    경로(_send_stop) 하나뿐이다."""
    adapter = _GatedPressAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    worker = threading.Thread(
        target=manager.submit,
        args=(session.session_id, "microwave", "press BT-05"),
    )
    worker.start()
    assert adapter.arrived.wait(timeout=5)

    manager.emergency_stop()
    # 그 사이 다른 경로(예: 다른 장치의 정지 미확인)가 fault를 걸었다.
    arbiter.trip_fault("stop_unconfirmed:elsewhere")

    adapter.gate.set()  # 늦은 press → settle의 재정지는 '성공'한다
    worker.join(timeout=5)

    # 재정지가 성공해도 남의 fault는 그대로다.
    assert arbiter.fault_reason == "stop_unconfirmed:elsewhere"


class _GatedStopAdapter(MockMotionAdapter):
    """**긴급 정지의 stop 호출**이 게이트에서 응답 대기 중인 상황을
    재현한다(후속 리뷰 1.3). fail_once=True면 그 정지가 게이트 해제 후
    실패로 끝난다(한 번만 -- 이후 복구 절차 검증용). 다른 이유의 stop은
    즉시 통과한다."""

    def __init__(self, *, fail_once: bool = False) -> None:
        super().__init__()
        self.fail_once = fail_once
        self.stop_entered = threading.Event()
        self.stop_gate = threading.Event()

    def stop(self, reason: str) -> None:
        if reason == "emergency_stop":
            self.stop_entered.set()
            assert self.stop_gate.wait(timeout=5)
            super().stop(reason)
            if self.fail_once:
                self.fail_once = False
                raise RuntimeError("link down")
            return
        super().stop(reason)


def _gate_settle(manager):
    """정상 완료 판정(stale 검사)과 _finish_settle 사이를 멈추는 테스트
    이음새 -- 리뷰 1.3의 경합 창을 결정적으로 연다."""
    entered = threading.Event()
    gate = threading.Event()
    original = manager._finish_settle

    def gated(result, **kwargs):
        entered.set()
        assert gate.wait(timeout=5)
        return original(result, **kwargs)

    manager._finish_settle = gated
    return entered, gate


def test_normal_completion_does_not_release_while_a_stop_awaits_confirmation() -> None:
    """정상 완료 직후 긴급 정지가 반납을 위임하고 어댑터에서 지연되는 창 --
    위임(_release_owed)은 '반납 부탁'이지 '정지 확인'이 아니므로, settle은
    그 정지가 확인되기 전에는 제어권을 내주지 않는다(후속 리뷰 1.3)."""
    adapter = _GatedStopAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")
    settle_entered, settle_gate = _gate_settle(manager)

    results: list = []
    worker = threading.Thread(
        target=lambda: results.append(
            manager.submit(session.session_id, "microwave", "home")
        )
    )
    worker.start()
    assert settle_entered.wait(timeout=5)  # 정상 완료 판정 직후에서 정지

    stopper = threading.Thread(target=manager.emergency_stop)
    stopper.start()
    assert adapter.stop_entered.wait(timeout=5)  # 긴급 정지가 응답 대기 중

    settle_gate.set()  # 정상 완료 재개 -- 위임을 발견하지만
    worker.join(timeout=5)
    [result] = results
    assert result.accepted is True  # 명령 자체는 정지 전에 끝났다

    # 1.3 회귀 지점: 정지가 아직 확인되지 않았으므로 반납하지 않는다.
    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.EXECUTION)

    adapter.stop_gate.set()
    stopper.join(timeout=5)
    # 정지가 확인된 뒤에야 제어권이 나간다.
    arbiter.acquire(ControlArbiter.EXECUTION)
    assert arbiter.fault_reason is None


def test_normal_completion_with_failing_late_stop_ends_locked() -> None:
    """같은 창에서 지연된 긴급 정지가 **실패**로 끝나면 -- 새 실행이 이미
    돌고 있는 게 아니라, 아무도 제어권을 얻지 못한 채 fault로 잠겨 있어야
    한다(후속 리뷰 1.3)."""
    adapter = _GatedStopAdapter(fail_once=True)
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")
    settle_entered, settle_gate = _gate_settle(manager)

    worker = threading.Thread(
        target=manager.submit,
        args=(session.session_id, "microwave", "home"),
    )
    worker.start()
    assert settle_entered.wait(timeout=5)

    stop_errors: list = []

    def run_stop() -> None:
        try:
            manager.emergency_stop()
        except RuntimeError as exc:
            stop_errors.append(exc)

    stopper = threading.Thread(target=run_stop)
    stopper.start()
    assert adapter.stop_entered.wait(timeout=5)

    settle_gate.set()
    worker.join(timeout=5)
    with pytest.raises(ControlConflictError):
        arbiter.acquire(ControlArbiter.EXECUTION)  # 확인 전 -- 여전히 보류

    adapter.stop_gate.set()
    stopper.join(timeout=5)
    assert stop_errors  # 정지 실패는 호출자에게 그대로 올라갔다
    assert (arbiter.fault_reason or "").startswith("stop_unconfirmed:")
    with pytest.raises(ControlFaultedError):
        arbiter.acquire(ControlArbiter.EXECUTION)

    # 문서화된 복구: 긴급 정지가 실제로 확인되면 풀린다(fail_once 소진).
    manager.emergency_stop()
    assert arbiter.fault_reason is None
    arbiter.acquire(ControlArbiter.EXECUTION)


def test_a_late_stop_confirmation_cannot_clear_a_newer_fault() -> None:
    """오래 걸린 정지의 성공 응답이, 그 정지가 시작된 **뒤에** 걸린 새
    fault를 해제하면 안 된다 -- fault 세대(fault_seq) 대조(후속 리뷰 1.3)."""
    adapter = _GatedStopAdapter()
    manager, _, _, _, arbiter = _manager(adapter=adapter)
    arbiter.trip_fault("stop_unconfirmed:before")

    stopper = threading.Thread(target=manager.emergency_stop)
    stopper.start()
    assert adapter.stop_entered.wait(timeout=5)  # 정지가 응답 대기 중

    arbiter.trip_fault("stop_unconfirmed:newer")  # 그 사이의 새 사건

    adapter.stop_gate.set()
    stopper.join(timeout=5)

    assert arbiter.fault_reason == "stop_unconfirmed:newer"


def test_close_and_start_race_never_leaves_a_session() -> None:
    """종료 표시와 세션 생성이 같은 락으로 직렬화된다(후속 리뷰 1.1-#3) --
    어느 순서로 겹쳐도 종료된 매니저에 세션이 남지 않는다."""
    for _ in range(50):
        manager, _, _, _, arbiter = _manager()
        barrier = threading.Barrier(2)

        def opener(m=manager, b=barrier) -> None:
            b.wait()
            try:
                m.start("microwave", "node-1")
            except DevSessionConflict:
                pass

        def closer(m=manager, b=barrier) -> None:
            b.wait()
            m.close()

        t1 = threading.Thread(target=opener)
        t2 = threading.Thread(target=closer)
        t1.start(); t2.start(); t1.join(); t2.join()

        assert manager.session is None
        assert arbiter.holder is None


def test_heartbeat_expiry_is_not_blocked_by_a_slow_command() -> None:
    adapter = _SlowPressAdapter()
    manager, _, clock, _, _ = _manager(adapter=adapter)
    session = manager.start("microwave", "node-1")

    worker = threading.Thread(
        target=manager.submit,
        args=(session.session_id, "microwave", "press BT-05"),
    )
    worker.start()
    assert adapter.entered.wait(timeout=5)

    clock.advance(3)
    assert manager.tick() == "heartbeat_timeout"  # 블로킹 없이 즉시
    assert manager.session is None

    adapter.release.set()
    worker.join(timeout=5)


# ── mock 강제 ─────────────────────────────────────────────────────────────


def test_a_real_adapter_is_refused_without_the_explicit_flag() -> None:
    clock = _Clock()
    with pytest.raises(RuntimeError, match="mock"):
        DeveloperSessionManager(
            adapter=MockMotionAdapter(is_mock=False),  # 실물인 척하는 어댑터
            clock=clock,
            arbiter=ControlArbiter(),
            is_calibrated=lambda _a: True,
            monotonic=clock.mono,
        )


# ── press · jog ───────────────────────────────────────────────────────────


def test_press_is_blocked_until_calibrated() -> None:
    manager, adapter, _, state, _ = _manager(calibrated=False)
    session = manager.start("microwave", "node-1")

    blocked = manager.submit(session.session_id, "microwave", "press BT-05")
    assert blocked.accepted is False
    assert adapter.motion_calls() == []

    state["calibrated"] = True
    allowed = manager.submit(session.session_id, "microwave", "press BT-05")
    assert allowed.accepted is True
    assert adapter.motion_calls() == [("press", "BT-05")]


def test_jog_is_sent_only_with_a_short_ttl() -> None:
    manager, adapter, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    manager.submit(session.session_id, "microwave", "jog z - 0.2")

    [(name, axis, direction, amount, ttl)] = adapter.motion_calls()
    assert (name, axis, direction, amount) == ("jog", DevAxis.Z, -1, 0.2)
    assert 0 < ttl <= 0.5


def test_sensor_read_returns_values_and_is_marked_mock() -> None:
    manager, _, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "sensor read")

    assert result.accepted is True
    assert result.sensor is not None
    assert all(entry.mock for entry in manager.log())


# ── 로그 ──────────────────────────────────────────────────────────────────


def test_every_request_is_logged_with_its_request_id() -> None:
    manager, _, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    manager.submit(session.session_id, "microwave", "jog x + 1", request_id="r-ok")
    manager.submit(session.session_id, "microwave", "reboot", request_id="r-bad")

    by_id = {e.request_id: e for e in manager.log() if e.request_id}
    assert by_id["r-ok"].event == "command_accepted"
    assert by_id["r-ok"].detail == "jog x + 1"
    assert by_id["r-ok"].session_id == session.session_id
    assert by_id["r-bad"].event == "command_rejected"


def test_log_is_a_bounded_ring_buffer() -> None:
    manager, _, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    for i in range(DeveloperSessionManager.LOG_LIMIT + 50):
        manager.submit(session.session_id, "microwave", "status", request_id=f"r{i}")

    log = manager.log()
    assert len(log) == DeveloperSessionManager.LOG_LIMIT
    assert log[-1].request_id == f"r{DeveloperSessionManager.LOG_LIMIT + 49}"
