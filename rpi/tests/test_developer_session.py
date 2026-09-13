"""개발자 모드 Phase 0 — 안전 불변식을 먼저 못 박는다.

하드웨어가 도착한 날 가장 먼저 필요한 것은 "올바른 가전과 노드를 골라 한 축을
안전하게 움직이고 즉시 멈추는 것"이다. 그 전에 계약이 흔들리지 않게 한다.

- 허용 목록 밖의 명령은 기계에 **닿지 않는다** (셸·raw·여러 명령 숨기기 포함)
- 제어권은 한 번에 하나 -- 다른 세션·일반 실행과 동시에 움직이지 않는다
- heartbeat가 끊기면 스스로 멈추고 세션을 닫는다
- 긴급 정지는 세션이 없어도, 명령이 틀려도 항상 먼저 닿는다
- 매 명령에서 대상 가전을 다시 확인한다
- 보정 안 된 가전은 누르지 않는다
- jog는 짧은 TTL로만 나간다
- 모든 요청은 request_id로 로그에 남고, 로그는 커지지 않는다
"""

from datetime import datetime, timedelta, timezone

import pytest

from rpi.services.developer_session import (
    MAX_JOG_MM,
    DevAxis,
    DevCommandKind,
    DevCommandRejected,
    DeveloperSessionManager,
    DevSessionConflict,
    DevSessionExpired,
    MockMotionAdapter,
    parse_dev_command,
)

_T0 = datetime(2026, 9, 24, 10, 0, tzinfo=timezone.utc)


class _Clock:
    def __init__(self) -> None:
        self.t = _T0

    def now(self) -> datetime:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += timedelta(seconds=seconds)


def _manager(busy: bool = False, calibrated: bool = True):
    adapter = MockMotionAdapter()
    clock = _Clock()
    state = {"busy": busy, "calibrated": calibrated}
    manager = DeveloperSessionManager(
        adapter=adapter,
        clock=clock,
        execution_busy=lambda: state["busy"],
        is_calibrated=lambda _appliance: state["calibrated"],
    )
    return manager, adapter, clock, state


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
    manager, adapter, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "status; home")

    assert result.accepted is False
    assert adapter.motion_calls() == []


# ── 제어권 ────────────────────────────────────────────────────────────────


def test_only_one_session_holds_control() -> None:
    manager, _, _, _ = _manager()
    manager.start("microwave", "node-1")

    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-1")


def test_session_is_refused_while_normal_execution_runs() -> None:
    manager, _, _, _ = _manager(busy=True)

    with pytest.raises(DevSessionConflict):
        manager.start("microwave", "node-1")
    assert manager.session is None


def test_commands_are_refused_if_normal_execution_starts_meanwhile() -> None:
    manager, adapter, _, state = _manager()
    session = manager.start("microwave", "node-1")
    state["busy"] = True

    result = manager.submit(session.session_id, "microwave", "jog x + 1")

    assert result.accepted is False
    assert adapter.motion_calls() == []


def test_open_session_blocks_normal_execution() -> None:
    manager, _, _, _ = _manager()
    assert manager.blocks_execution() is False

    session = manager.start("microwave", "node-1")
    assert manager.blocks_execution() is True

    manager.end(session.session_id)
    assert manager.blocks_execution() is False


def test_command_for_a_different_appliance_is_refused() -> None:
    manager, adapter, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "induction", "jog x + 1")

    assert result.accepted is False
    assert adapter.motion_calls() == []


def test_stale_session_id_is_refused() -> None:
    manager, adapter, _, _ = _manager()
    old = manager.start("microwave", "node-1")
    manager.end(old.session_id)
    manager.start("microwave", "node-1")

    result = manager.submit(old.session_id, "microwave", "home")

    assert result.accepted is False
    assert adapter.motion_calls() == []


# ── heartbeat ─────────────────────────────────────────────────────────────


def test_missing_heartbeat_stops_and_closes_the_session() -> None:
    manager, adapter, clock, _ = _manager()
    session = manager.start("microwave", "node-1")
    manager.submit(session.session_id, "microwave", "jog x + 1")

    clock.advance(3)
    reason = manager.tick()

    assert reason == "heartbeat_timeout"
    assert adapter.stops() == ["heartbeat_timeout"]
    assert manager.session is None
    after = manager.submit(session.session_id, "microwave", "jog x + 1")
    assert after.accepted is False
    assert len(adapter.motion_calls()) == 1


def test_heartbeat_keeps_the_session_alive() -> None:
    manager, adapter, clock, _ = _manager()
    session = manager.start("microwave", "node-1")

    for _ in range(5):
        clock.advance(1.5)
        manager.heartbeat(session.session_id)

    assert manager.tick() is None
    assert adapter.stops() == []


def test_heartbeat_after_expiry_is_an_error_and_already_stopped() -> None:
    manager, adapter, clock, _ = _manager()
    session = manager.start("microwave", "node-1")
    clock.advance(3)

    with pytest.raises(DevSessionExpired):
        manager.heartbeat(session.session_id)
    assert adapter.stops() == ["heartbeat_timeout"]


def test_new_session_can_start_after_expiry() -> None:
    manager, _, clock, _ = _manager()
    manager.start("microwave", "node-1")
    clock.advance(3)

    fresh = manager.start("microwave", "node-2")

    assert fresh.node_id == "node-2"


# ── 정지 ──────────────────────────────────────────────────────────────────


def test_emergency_stop_reaches_adapter_without_any_session() -> None:
    manager, adapter, _, _ = _manager()

    manager.emergency_stop()

    assert adapter.stops() == ["emergency_stop"]


def test_emergency_stop_ends_the_session() -> None:
    manager, adapter, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    manager.emergency_stop()

    assert manager.session is None
    assert adapter.stops() == ["emergency_stop"]
    assert manager.submit(session.session_id, "microwave", "home").accepted is False


def test_stop_command_works_even_with_wrong_session_or_appliance() -> None:
    manager, adapter, _, _ = _manager()
    manager.start("microwave", "node-1")

    result = manager.submit("not-a-session", "induction", "stop")

    assert result.accepted is True
    assert adapter.stops() == ["user_stop"]
    assert manager.session is None


def test_session_closes_even_if_the_adapter_stop_raises() -> None:
    class _Broken(MockMotionAdapter):
        def stop(self, reason: str) -> None:
            super().stop(reason)
            raise RuntimeError("link down")

    adapter = _Broken()
    clock = _Clock()
    manager = DeveloperSessionManager(
        adapter=adapter,
        clock=clock,
        execution_busy=lambda: False,
        is_calibrated=lambda _a: True,
    )
    manager.start("microwave", "node-1")

    with pytest.raises(RuntimeError):
        manager.emergency_stop()

    # 기계 상태를 모르는 채로 제어권을 남기지 않는다.
    assert manager.session is None
    assert adapter.stops() == ["emergency_stop"]


# ── press · jog ───────────────────────────────────────────────────────────


def test_press_is_blocked_until_calibrated() -> None:
    manager, adapter, _, state = _manager(calibrated=False)
    session = manager.start("microwave", "node-1")

    blocked = manager.submit(session.session_id, "microwave", "press BT-05")
    assert blocked.accepted is False
    assert adapter.motion_calls() == []

    state["calibrated"] = True
    allowed = manager.submit(session.session_id, "microwave", "press BT-05")
    assert allowed.accepted is True
    assert adapter.motion_calls() == [("press", "BT-05")]


def test_jog_is_sent_only_with_a_short_ttl() -> None:
    manager, adapter, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    manager.submit(session.session_id, "microwave", "jog z - 0.2")

    [(name, axis, direction, amount, ttl)] = adapter.motion_calls()
    assert (name, axis, direction, amount) == ("jog", DevAxis.Z, -1, 0.2)
    assert 0 < ttl <= 0.5


def test_sensor_read_returns_values_and_is_marked_mock() -> None:
    manager, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    result = manager.submit(session.session_id, "microwave", "sensor read")

    assert result.accepted is True
    assert result.sensor is not None
    assert all(entry.mock for entry in manager.log())


# ── 로그 ──────────────────────────────────────────────────────────────────


def test_every_request_is_logged_with_its_request_id() -> None:
    manager, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    manager.submit(session.session_id, "microwave", "jog x + 1", request_id="r-ok")
    manager.submit(session.session_id, "microwave", "reboot", request_id="r-bad")

    by_id = {e.request_id: e for e in manager.log() if e.request_id}
    assert by_id["r-ok"].event == "command_accepted"
    assert by_id["r-ok"].detail == "jog x + 1"
    assert by_id["r-ok"].session_id == session.session_id
    assert by_id["r-bad"].event == "command_rejected"


def test_log_is_a_bounded_ring_buffer() -> None:
    manager, _, _, _ = _manager()
    session = manager.start("microwave", "node-1")

    for i in range(DeveloperSessionManager.LOG_LIMIT + 50):
        manager.submit(session.session_id, "microwave", "status", request_id=f"r{i}")

    log = manager.log()
    assert len(log) == DeveloperSessionManager.LOG_LIMIT
    assert log[-1].request_id == f"r{DeveloperSessionManager.LOG_LIMIT + 49}"
