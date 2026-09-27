import pytest

from rpi4.parking_simulator import Mapping, ParkingSimulator, Phase, Point, rehearsal


def ready(edge='top'):
    sim = ParkingSimulator(Mapping(Point(.8, .7), Point(.5, 0 if edge == 'top' else 1), edge))
    sim.locate_at_park()
    sim.begin()
    sim.sequence_finished()
    return sim


def ack(sim):
    sim.acknowledge(sim.pending.id, success=True)


@pytest.mark.parametrize('edge', ['top', 'bottom'])
def test_wait_without_press_and_park_only_after_observed_end(edge):
    sim = ready(edge)
    assert sim.pending.kind == 'retract'
    ack(sim)
    assert sim.pending.target == sim.mapping.stop
    ack(sim)
    assert sim.phase == Phase.WAITING
    assert sim.z_retracted
    assert sim.pending is None
    assert not sim.operation_ended
    sim.confirm_operation_ended()
    ack(sim)
    assert sim.pending.target == sim.mapping.park
    ack(sim)
    assert sim.phase == Phase.PARKED


def test_stop_press_is_not_appliance_stop_evidence_and_requests_are_idempotent():
    sim = ready()
    ack(sim)
    ack(sim)
    sim.request_appliance_stop()
    sim.request_appliance_stop()
    ack(sim)
    ack(sim)
    sim.request_appliance_stop()
    assert sim.phase == Phase.STOP_CHECK
    assert sim.stop_press_confirmed and not sim.operation_ended
    assert [a.kind for a in sim.history].count('press_stop') == 1


def test_stop_requested_while_approaching_waits_for_position_ack():
    sim = ready()
    sim.request_appliance_stop()
    assert sim.pending.kind == 'retract'
    ack(sim)
    assert sim.pending.kind == 'move'
    ack(sim)
    assert sim.pending.kind == 'press_stop'


@pytest.mark.parametrize('reason', ['actuator_emergency_stop', 'link_lost', 'z_jammed'])
def test_fault_latches_without_automatic_movement_or_late_ack(reason):
    sim = ready()
    stale = sim.pending.id
    before = list(sim.history)
    sim.lock(reason)
    for operation in (sim.begin, sim.request_appliance_stop, sim.confirm_operation_ended,
                      sim.locate_at_park, lambda: sim.acknowledge(stale, success=True)):
        with pytest.raises(ValueError):
            operation()
    assert sim.history == before
    assert sim.phase == Phase.LOCKED


def test_retraction_failure_prevents_xy_movement():
    sim = ready()
    sim.acknowledge(sim.pending.id, success=False)
    assert sim.phase == Phase.LOCKED
    assert [a.kind for a in sim.history] == ['retract']


def test_stale_ack_does_not_advance_and_new_cycle_resets_evidence():
    sim = ready()
    first = sim.pending.id
    ack(sim)
    with pytest.raises(ValueError):
        sim.acknowledge(first, success=True)
    ack(sim)
    sim.confirm_operation_ended()
    ack(sim)
    ack(sim)
    sim.begin()
    assert not sim.operation_ended
    assert sim.phase == Phase.INPUT
    with pytest.raises(ValueError):
        sim.request_appliance_stop()


@pytest.mark.parametrize('value', [True, float('nan'), float('inf'), -1, 1.1, '0'])
def test_mapping_rejects_invalid_coordinates(value):
    with pytest.raises(ValueError):
        Point(value, 0)


def test_mapping_requires_explicit_distinct_stop_and_edge_park():
    with pytest.raises(ValueError):
        Mapping(Point(.5, 0), Point(.5, 0), 'top')
    with pytest.raises(ValueError):
        Mapping(Point(.5, .5), Point(.5, .2), 'top')
    with pytest.raises(ValueError):
        Mapping(None, Point(.5, 0), 'top')


def test_cli_rehearsal_separates_wait_press_and_appliance_end():
    waiting, pressed, parked = rehearsal()
    assert waiting['phase'] == 'waiting_above_stop'
    assert pressed['stop_press_confirmed'] and not pressed['operation_ended']
    assert parked['phase'] == 'parked' and parked['operation_ended']
    assert all(x['execution_mode'] == 'mock' for x in (waiting, pressed, parked))
