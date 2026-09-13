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
    """press가 release될 때까지 멈춰 있는 어댑터 -- 즉시 반환하는 mock으로는
    '정지가 명령 처리를 기다리는' 결함이 드러나지 않는다(교차 리뷰 #2)."""

    def __init__(self) -> None:
        super().__init__()
        self.entered = threading.Event()
        self.release = threading.Event()

    def press(self, button_id: str) -> None:
        super().press(button_id)
        self.entered.set()
        assert self.release.wait(timeout=5)


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
