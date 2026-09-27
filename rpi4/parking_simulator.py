"""Pure stop/parking rehearsal. No motor, API, sensor or protocol adapter.

Coordinates are normalized simulation coordinates, NOT millimetres or motor steps.
Every acknowledgement and appliance observation is injected mock evidence.
Run: python -m rpi4.parking_simulator
"""
from dataclasses import dataclass
from enum import Enum
import json
import math


@dataclass(frozen=True)
class Point:
    x: float
    y: float

    def __post_init__(self):
        for value in (self.x, self.y):
            if type(value) not in (float, int) or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError('normalized coordinates must be finite numbers in [0, 1]')


@dataclass(frozen=True)
class Mapping:
    stop: Point
    park: Point
    edge: str

    def __post_init__(self):
        if not isinstance(self.stop, Point) or not isinstance(self.park, Point):
            raise ValueError('explicit stop and park points required')
        if self.edge not in ('top', 'bottom'):
            raise ValueError('park edge must be top or bottom')
        if self.park.y != (0 if self.edge == 'top' else 1):
            raise ValueError('park must lie on the selected simulation edge')
        if self.stop == self.park:
            raise ValueError('stop and park must be separate')


class Phase(str, Enum):
    UNLOCATED = 'unlocated'
    PARKED = 'parked'
    INPUT = 'button_sequence'
    MOVING = 'awaiting_motion_ack'
    WAITING = 'waiting_above_stop'
    STOP_CHECK = 'awaiting_appliance_stop_confirmation'
    LOCKED = 'locked_manual_recovery_required'


@dataclass(frozen=True)
class Action:
    id: int
    kind: str
    target: Point | None = None


class ParkingSimulator:
    """Single-threaded explicit-event model; never automatically retries a press.

    No elapsed time proves completion. Failed/unknown movement, link loss and
    actuator E-stop lock the session. Recovery requires a new, located session.
    """
    def __init__(self, mapping: Mapping):
        if not isinstance(mapping, Mapping):
            raise ValueError('mapping required')
        self.mapping = mapping
        self.phase = Phase.UNLOCATED
        self.pending: Action | None = None
        self.history: list[Action] = []
        self.position: Point | None = None
        self.z_retracted = False
        self.stop_requested = False
        self.stop_press_confirmed = False
        self.operation_ended = False
        self.reason: str | None = None
        self._after_retract = 'stop'

    def locate_at_park(self):
        if self.phase != Phase.UNLOCATED:
            raise ValueError('location initialization only allowed for a new session')
        self.position = self.mapping.park
        self.z_retracted = True
        self.phase = Phase.PARKED

    def begin(self):
        if self.phase != Phase.PARKED:
            raise ValueError('must be parked before starting a sequence')
        self.stop_requested = self.stop_press_confirmed = self.operation_ended = False
        self.position = None
        self.z_retracted = False
        self.phase = Phase.INPUT

    def sequence_finished(self):
        if self.phase != Phase.INPUT:
            raise ValueError('no button sequence in progress')
        # Input completion does not mean the appliance operation has ended.
        self._retract('stop')

    def _issue(self, kind, target=None):
        if self.pending is not None or self.phase == Phase.LOCKED:
            raise ValueError('cannot issue another action')
        if kind == 'move' and not self.z_retracted:
            raise ValueError('XY movement requires retraction evidence')
        self.pending = Action(len(self.history) + 1, kind, target)
        self.history.append(self.pending)
        self.phase = Phase.MOVING

    def _retract(self, destination):
        self._after_retract = destination
        self._issue('retract')

    def request_appliance_stop(self):
        if self.phase not in (Phase.WAITING, Phase.MOVING, Phase.STOP_CHECK):
            # During button input, sequence cancellation must be settled first.
            raise ValueError('stop route unavailable; input cancellation is not implemented here')
        self.stop_requested = True
        if self.phase == Phase.WAITING and not self.operation_ended:
            self._press_stop()

    def _press_stop(self):
        if self.position != self.mapping.stop or not self.z_retracted:
            raise ValueError('stop position and Z retraction must be confirmed')
        self.z_retracted = False
        self._issue('press_stop')

    def acknowledge(self, action_id: int, *, success: bool):
        if type(action_id) is not int or type(success) is not bool:
            raise ValueError('typed acknowledgement required')
        if self.phase == Phase.LOCKED or self.pending is None or self.pending.id != action_id:
            raise ValueError('stale or unrelated acknowledgement')
        action, self.pending = self.pending, None
        if not success:
            self.lock('motion_failed_or_unconfirmed')
            return
        if action.kind == 'retract':
            self.z_retracted = True
            if self._after_retract == 'stop_check':
                self.phase = Phase.STOP_CHECK
            else:
                target = self.mapping.park if self._after_retract == 'park' else self.mapping.stop
                self._issue('move', target)
        elif action.kind == 'move':
            self.position = action.target
            if action.target == self.mapping.park:
                self.phase = Phase.PARKED
            else:
                self.phase = Phase.WAITING
                if self.stop_requested:
                    self._press_stop()
        elif action.kind == 'press_stop':
            self.stop_press_confirmed = True
            self._retract('stop_check')

    def confirm_operation_ended(self):
        if self.phase not in (Phase.WAITING, Phase.STOP_CHECK):
            raise ValueError('settle pending motion before observing appliance end')
        self.operation_ended = True
        self._retract('park')

    def lock(self, reason='actuator_emergency_stop'):
        # Never restart or route to the stop button after actuator power removal.
        self.reason = reason
        self.pending = None
        self.position = None
        self.z_retracted = False
        self.phase = Phase.LOCKED

    def snapshot(self):
        return dict(execution_mode='mock', phase=self.phase.value,
                    stop_requested=self.stop_requested,
                    stop_press_confirmed=self.stop_press_confirmed,
                    operation_ended=self.operation_ended, reason=self.reason,
                    actions=[dict(id=a.id, kind=a.kind,
                                  target=None if a.target is None else [a.target.x, a.target.y])
                             for a in self.history])


def rehearsal():
    sim = ParkingSimulator(Mapping(Point(.8, .7), Point(.5, 0), 'top'))
    sim.locate_at_park()
    sim.begin()
    sim.sequence_finished()
    for _ in range(2):
        sim.acknowledge(sim.pending.id, success=True)
    waiting = sim.snapshot()
    sim.request_appliance_stop()
    for _ in range(2):
        sim.acknowledge(sim.pending.id, success=True)
    pressed_not_stopped = sim.snapshot()
    sim.confirm_operation_ended()
    for _ in range(2):
        sim.acknowledge(sim.pending.id, success=True)
    return [waiting, pressed_not_stopped, sim.snapshot()]


if __name__ == '__main__':
    print(json.dumps(rehearsal(), indent=2))
