"""공간 존재 + 노드 전원 상태 기계 — 거리 단계가 곧 전원 단계.

여기서 못 박는 계약:

- 먼 구역은 노드를 깨우고, 가까운 구역은 화면을 켜며, 가까운 구역 **체류**만
  액추에이터 전원을 넣는다. 전원 동작은 AT_DEVICE 출입 간선에만 있다.
- 히스테리시스로 경계에 선 사람이 상태를 흔들지 않는다.
- 감지 두절은 켜져 있던 것만 끄고 IDLE로 내린다.
- 실행 중에는 사람이 떠나도 전원을 끊지 않고, 실행이 끝난 뒤 강등한다.
- 시계는 모두 가짜 단조 시계로 쥔다 — 실제 시간에 기대는 테스트는 흔들린다.
"""

from __future__ import annotations

import random
import threading

import pytest

from rpi.services.presence_state import (
    ACTIONS,
    POWER_PROFILES,
    NodeState,
    PowerProfile,
    PresenceConfig,
    PresenceStateMachine,
    Transition,
)


class FakeClock:
    def __init__(self, start: float = 1000.0) -> None:
        self.now = start
        self._lock = threading.Lock()

    def __call__(self) -> float:
        with self._lock:
            return self.now

    def advance(self, seconds: float) -> None:
        with self._lock:
            self.now += seconds


def _machine(config: PresenceConfig | None = None):
    clock = FakeClock()
    return PresenceStateMachine(config, monotonic=clock), clock


def _edges(transitions: list[Transition]):
    return [(t.previous, t.current, t.actions) for t in transitions]


def _to_at_device(machine: PresenceStateMachine, clock: FakeClock) -> None:
    machine.observe(3.0)
    machine.observe(0.8)
    clock.advance(1.5)
    machine.observe(0.8)
    assert machine.state is NodeState.AT_DEVICE


# ── 기본 승격 ──


def test_far_detection_wakes_node():
    machine, clock = _machine()
    transitions = machine.observe(4.0)
    assert _edges(transitions) == [
        (NodeState.IDLE, NodeState.ROOM_PRESENT, ("wake_node", "generate_suggestions"))
    ]
    assert transitions[0].reason == "entered_far"
    assert transitions[0].at_s == clock.now
    assert machine.state is NodeState.ROOM_PRESENT


def test_near_detection_turns_screen_on():
    machine, _ = _machine()
    machine.observe(4.0)
    transitions = machine.observe(0.9)
    assert _edges(transitions) == [
        (NodeState.ROOM_PRESENT, NodeState.APPROACHING, ("screen_on", "show_suggestion"))
    ]
    assert machine.profile.screen_on is True
    assert machine.profile.actuator_powered is False


def test_dwell_promotes_to_at_device_and_enables_actuator_power():
    machine, clock = _machine()
    machine.observe(4.0)
    machine.observe(0.9)
    clock.advance(1.0)
    assert machine.observe(0.9) == []
    clock.advance(0.5)
    transitions = machine.tick()
    assert _edges(transitions) == [
        (NodeState.APPROACHING, NodeState.AT_DEVICE, ("enable_actuator_power",))
    ]
    assert transitions[0].reason == "near_dwell"
    assert machine.profile.actuator_powered is True


def test_dwell_promotion_also_happens_on_observe():
    machine, clock = _machine()
    machine.observe(0.9)
    clock.advance(1.5)
    transitions = machine.observe(0.9)
    assert [t.current for t in transitions] == [NodeState.AT_DEVICE]


def test_first_detection_already_near_emits_ordered_chain():
    machine, _ = _machine()
    transitions = machine.observe(0.5)
    assert _edges(transitions) == [
        (NodeState.IDLE, NodeState.ROOM_PRESENT, ("wake_node", "generate_suggestions")),
        (NodeState.ROOM_PRESENT, NodeState.APPROACHING, ("screen_on", "show_suggestion")),
    ]
    assert machine.state is NodeState.APPROACHING


def test_all_emitted_actions_are_in_vocabulary():
    machine, clock = _machine()
    machine.phone_arriving()
    _to_at_device(machine, clock)
    machine.observe(3.0)
    machine.observe(0.5)
    clock.advance(31.0)
    machine.tick()
    for transition in machine.history():
        assert set(transition.actions) <= ACTIONS


# ── 강등 ──


def test_moving_away_steps_down_one_stage_per_boundary():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    transitions = machine.observe(3.0)
    assert _edges(transitions) == [
        (NodeState.AT_DEVICE, NodeState.APPROACHING, ("disable_actuator_power",)),
        (NodeState.APPROACHING, NodeState.ROOM_PRESENT, ("screen_off",)),
    ]
    transitions = machine.observe(6.0)
    assert _edges(transitions) == [
        (NodeState.ROOM_PRESENT, NodeState.IDLE, ("sleep_node",))
    ]
    assert machine.state is NodeState.IDLE


def test_actuator_power_actions_only_on_at_device_edges():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    machine.observe(10.0)
    machine.observe(0.3)
    machine.observe(4.0)
    for transition in machine.history():
        touches_power = {"enable_actuator_power", "disable_actuator_power"} & set(
            transition.actions
        )
        if touches_power:
            assert NodeState.AT_DEVICE in (transition.previous, transition.current)


# ── 히스테리시스 ──


def test_hysteresis_oscillating_just_outside_near_enter_does_not_flap():
    machine, clock = _machine()
    machine.observe(4.0)
    machine.observe(0.95)
    assert machine.state is NodeState.APPROACHING
    for distance in (1.1, 1.2, 1.1, 1.2, 1.15, 1.2, 1.1, 1.2):
        clock.advance(0.1)
        assert machine.observe(distance) == []
        assert machine.state is NodeState.APPROACHING
    # near_exit_m(1.3)를 넘어야 나간다.
    transitions = machine.observe(1.31)
    assert [t.current for t in transitions] == [NodeState.ROOM_PRESENT]


def test_hysteresis_approaching_from_far_needs_near_enter():
    machine, _ = _machine()
    machine.observe(4.0)
    assert machine.observe(1.2) == []
    assert machine.state is NodeState.ROOM_PRESENT


def test_hysteresis_far_boundary():
    machine, _ = _machine()
    assert machine.observe(5.3) == []  # 들어올 때는 5.0 이하
    assert machine.state is NodeState.IDLE
    machine.observe(5.0)
    assert machine.state is NodeState.ROOM_PRESENT
    for distance in (5.2, 5.4, 5.5, 5.3):
        assert machine.observe(distance) == []
    assert [t.current for t in machine.observe(5.6)] == [NodeState.IDLE]


# ── 짧은 방문 ──


def test_short_near_visit_never_powers_actuator():
    machine, clock = _machine()
    machine.observe(4.0)
    machine.observe(0.8)
    clock.advance(1.0)
    machine.observe(0.8)
    clock.advance(0.4)
    machine.observe(3.0)
    clock.advance(5.0)
    machine.tick()
    assert all(t.current is not NodeState.AT_DEVICE for t in machine.history())
    assert all("enable_actuator_power" not in t.actions for t in machine.history())


def test_detection_gap_restarts_dwell():
    machine, clock = _machine()
    machine.observe(0.8)
    clock.advance(1.0)
    machine.observe(None)  # 한 틱 못 봤다 — 보지 못한 시간은 체류가 아니다
    clock.advance(0.2)
    machine.observe(0.8)
    clock.advance(1.0)
    assert machine.tick() == []
    assert machine.state is NodeState.APPROACHING
    clock.advance(0.5)
    assert [t.current for t in machine.tick()] == [NodeState.AT_DEVICE]


# ── 감지 두절 ──


def test_lost_timeout_returns_to_idle_with_power_off_actions():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    clock.advance(29.9)
    assert machine.observe(None) == []
    assert machine.tick() == []
    assert machine.state is NodeState.AT_DEVICE
    clock.advance(0.1)
    transitions = machine.tick()
    assert _edges(transitions) == [
        (
            NodeState.AT_DEVICE,
            NodeState.IDLE,
            ("disable_actuator_power", "screen_off", "sleep_node"),
        )
    ]
    assert transitions[0].reason == "lost_timeout"
    assert machine.profile.actuator_powered is False


def test_lost_timeout_from_room_present_only_sleeps_node():
    machine, clock = _machine()
    machine.observe(4.0)
    clock.advance(30.0)
    transitions = machine.observe(None)
    assert _edges(transitions) == [
        (NodeState.ROOM_PRESENT, NodeState.IDLE, ("sleep_node",))
    ]


def test_lost_timeout_not_reached_stays():
    machine, clock = _machine()
    machine.observe(0.8)
    for _ in range(10):
        clock.advance(2.0)
        machine.observe(None)
        machine.tick()
    assert machine.state is NodeState.APPROACHING


def test_redetection_resets_lost_timer():
    machine, clock = _machine()
    machine.observe(4.0)
    clock.advance(25.0)
    machine.observe(4.0)
    clock.advance(25.0)
    assert machine.tick() == []
    assert machine.state is NodeState.ROOM_PRESENT


def test_idle_tick_does_nothing():
    machine, clock = _machine()
    clock.advance(1000.0)
    assert machine.tick() == []
    assert machine.observe(None) == []
    assert machine.history() == []


# ── 실행 고정 ──


def test_execution_pins_at_device_until_end_execution():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    machine.begin_execution()
    assert machine.executing is True

    assert machine.observe(3.0) == []
    assert machine.observe(9.0) == []
    clock.advance(60.0)
    assert machine.observe(None) == []
    assert machine.tick() == []
    assert machine.state is NodeState.AT_DEVICE
    assert machine.profile.actuator_powered is True

    transitions = machine.end_execution()
    assert machine.executing is False
    assert _edges(transitions) == [
        (NodeState.AT_DEVICE, NodeState.APPROACHING, ("disable_actuator_power",)),
        (NodeState.APPROACHING, NodeState.ROOM_PRESENT, ("screen_off",)),
        (NodeState.ROOM_PRESENT, NodeState.IDLE, ("sleep_node",)),
    ]
    assert all(t.reason.endswith("_after_execution") for t in transitions)


def test_execution_person_left_to_far_demotes_to_room_present_on_end():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    machine.begin_execution()
    clock.advance(2.0)
    machine.observe(3.0)
    transitions = machine.end_execution()
    assert [t.current for t in transitions] == [
        NodeState.APPROACHING,
        NodeState.ROOM_PRESENT,
    ]
    assert machine.state is NodeState.ROOM_PRESENT


def test_execution_lost_during_execution_applies_lost_on_end():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    machine.begin_execution()
    clock.advance(45.0)
    machine.tick()
    transitions = machine.end_execution()
    assert _edges(transitions) == [
        (
            NodeState.AT_DEVICE,
            NodeState.IDLE,
            ("disable_actuator_power", "screen_off", "sleep_node"),
        )
    ]
    assert transitions[0].reason == "lost_timeout_after_execution"


def test_execution_person_still_near_stays_at_device():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    machine.begin_execution()
    clock.advance(3.0)
    machine.observe(0.7)
    assert machine.end_execution() == []
    assert machine.state is NodeState.AT_DEVICE


def test_end_execution_without_begin_is_noop():
    machine, _ = _machine()
    assert machine.end_execution() == []


@pytest.mark.parametrize("distances", [[], [4.0], [0.8]])
def test_begin_execution_outside_at_device_raises(distances):
    machine, _ = _machine()
    for distance in distances:
        machine.observe(distance)
    with pytest.raises(RuntimeError):
        machine.begin_execution()
    assert machine.executing is False


def test_begin_execution_twice_raises():
    machine, clock = _machine()
    _to_at_device(machine, clock)
    machine.begin_execution()
    with pytest.raises(RuntimeError):
        machine.begin_execution()


# ── S0 귀가 신호 ──


def test_phone_arriving_emits_precompute_once_within_ttl_and_expires():
    machine, clock = _machine()
    transition = machine.phone_arriving()
    assert transition is not None
    assert transition.previous is NodeState.IDLE
    assert transition.current is NodeState.IDLE
    assert transition.reason == "arrival_hint"
    assert transition.actions == ("precompute_suggestions",)
    assert machine.state is NodeState.IDLE
    assert machine.arrival_hint_active() is True

    clock.advance(300.0)
    assert machine.phone_arriving() is None
    clock.advance(299.9)
    assert machine.arrival_hint_active() is True
    clock.advance(0.1)
    assert machine.arrival_hint_active() is False

    again = machine.phone_arriving()
    assert again is not None and again.actions == ("precompute_suggestions",)
    assert [t.reason for t in machine.history()] == ["arrival_hint", "arrival_hint"]


def test_phone_arriving_when_already_awake_records_hint_only():
    machine, _ = _machine()
    machine.observe(4.0)
    assert machine.phone_arriving() is None
    assert machine.arrival_hint_active() is True
    assert machine.state is NodeState.ROOM_PRESENT


# ── 잘못된 입력 ──


@pytest.mark.parametrize(
    "bad", [float("nan"), -0.1, -5.0, float("inf"), float("-inf"), True, "1.0", object()]
)
def test_invalid_distances_are_ignored(bad):
    machine, clock = _machine()
    assert machine.observe(bad) == []
    assert machine.state is NodeState.IDLE

    machine.observe(0.8)
    clock.advance(1.0)
    assert machine.observe(bad) == []
    clock.advance(0.6)
    # 잘못된 틱은 체류를 끊지도 늘리지도 않는다.
    assert [t.current for t in machine.tick()] == [NodeState.AT_DEVICE]


def test_zero_distance_is_valid_near():
    machine, _ = _machine()
    assert [t.current for t in machine.observe(0)] == [
        NodeState.ROOM_PRESENT,
        NodeState.APPROACHING,
    ]


# ── 전원 프로파일 ──


def test_profile_per_state_matches_power_profiles():
    machine, clock = _machine()
    assert machine.profile == POWER_PROFILES[NodeState.IDLE]
    machine.observe(4.0)
    assert machine.profile == POWER_PROFILES[NodeState.ROOM_PRESENT]
    machine.observe(0.8)
    assert machine.profile == POWER_PROFILES[NodeState.APPROACHING]
    clock.advance(1.5)
    machine.tick()
    assert machine.profile == POWER_PROFILES[NodeState.AT_DEVICE]


def test_power_profiles_table():
    assert set(POWER_PROFILES) == set(NodeState)
    for state, profile in POWER_PROFILES.items():
        assert isinstance(profile, PowerProfile)
        assert profile.state is state
        assert profile.radar is True
        low, high = profile.estimated_watts
        assert 0 < low <= high

    idle = POWER_PROFILES[NodeState.IDLE]
    assert (idle.node_awake, idle.screen_on, idle.actuator_powered) == (False, False, False)
    assert idle.estimated_watts == (0.3, 0.5)
    assert POWER_PROFILES[NodeState.ROOM_PRESENT].estimated_watts == (0.8, 0.8)
    assert POWER_PROFILES[NodeState.APPROACHING].screen_on is True
    assert POWER_PROFILES[NodeState.APPROACHING].estimated_watts == (2.0, 2.0)
    at_device = POWER_PROFILES[NodeState.AT_DEVICE]
    assert at_device.actuator_powered is True
    assert at_device.estimated_watts == (5.0, 5.0)
    # 액추에이터 전원은 AT_DEVICE에만.
    assert [s for s, p in POWER_PROFILES.items() if p.actuator_powered] == [
        NodeState.AT_DEVICE
    ]
    with pytest.raises(TypeError):
        POWER_PROFILES[NodeState.IDLE] = at_device  # type: ignore[index]


# ── 설정 ──


def test_config_defaults():
    cfg = PresenceConfig()
    assert (cfg.far_enter_m, cfg.far_exit_m) == (5.0, 5.5)
    assert (cfg.near_enter_m, cfg.near_exit_m) == (1.0, 1.3)
    assert cfg.at_device_dwell_s == 1.5
    assert cfg.lost_timeout_s == 30.0
    assert cfg.arrival_hint_ttl_s == 600.0


@pytest.mark.parametrize(
    "kwargs",
    [
        {"near_enter_m": 1.5, "near_exit_m": 1.3},
        {"far_enter_m": 1.2},
        {"far_enter_m": 6.0},
        {"near_enter_m": 0.0},
        {"lost_timeout_s": 0.0},
        {"at_device_dwell_s": -1.0},
        {"arrival_hint_ttl_s": 0.0},
    ],
)
def test_config_rejects_inconsistent_values(kwargs):
    with pytest.raises(ValueError):
        PresenceConfig(**kwargs)


def test_custom_config_is_used():
    machine, clock = _machine(PresenceConfig(at_device_dwell_s=0.0, lost_timeout_s=5.0))
    assert [t.current for t in machine.observe(0.5)] == [
        NodeState.ROOM_PRESENT,
        NodeState.APPROACHING,
        NodeState.AT_DEVICE,
    ]
    clock.advance(5.0)
    assert [t.current for t in machine.tick()] == [NodeState.IDLE]


# ── 이력 ──


def test_history_bounded_to_100():
    machine, _ = _machine()
    for _ in range(80):
        machine.observe(4.0)
        machine.observe(8.0)
    history = machine.history()
    assert len(history) == 100
    assert history[-1].current is NodeState.IDLE
    history.clear()  # 사본이다
    assert len(machine.history()) == 100


# ── 스레드 안전 ──


def test_thread_safety_smoke():
    machine, clock = _machine()
    errors: list[BaseException] = []
    start = threading.Barrier(6)

    def observer(seed: int) -> None:
        rng = random.Random(seed)
        try:
            start.wait()
            for _ in range(500):
                choice = rng.random()
                if choice < 0.1:
                    machine.observe(None)
                elif choice < 0.15:
                    machine.observe(float("nan"))
                else:
                    machine.observe(rng.uniform(0.0, 7.0))
        except BaseException as exc:  # noqa: BLE001 - 스모크: 무엇이든 실패다
            errors.append(exc)

    def ticker() -> None:
        try:
            start.wait()
            for _ in range(500):
                clock.advance(0.05)
                machine.tick()
                machine.phone_arriving()
                if machine.state is NodeState.AT_DEVICE:
                    try:
                        machine.begin_execution()
                    except RuntimeError:
                        pass  # 경합으로 그 사이 강등됐을 수 있다
                machine.end_execution()
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=observer, args=(i,)) for i in range(4)]
    threads += [threading.Thread(target=ticker) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert not any(thread.is_alive() for thread in threads)
    assert errors == []
    assert machine.state in set(NodeState)
    assert machine.profile == POWER_PROFILES[machine.state]
    history = machine.history()
    assert len(history) <= 100
    # 이력 안의 연속 전이는 서로 이어져야 한다(찢어진 쓰기가 없다).
    for before, after in zip(history, history[1:]):
        assert before.current is after.previous
