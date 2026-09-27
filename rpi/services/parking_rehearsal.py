"""Serialized browser events for the independent, mock-only parking model."""
from threading import Lock
from uuid import uuid4

from rpi4.parking_simulator import Mapping, ParkingSimulator, Point


class StaleRehearsal(ValueError):
    pass


class ParkingRehearsal:
    def __init__(self):
        self._lock = Lock()
        self._revision = 0
        self._session = uuid4().hex
        self._sim = ParkingSimulator(Mapping(Point(.8, .7), Point(.5, 0), 'top'))

    def _snapshot(self):
        sim = self._sim
        return {**sim.snapshot(), 'revision': self._revision, 'session': self._session,
                'position': None if sim.position is None else [sim.position.x, sim.position.y],
                'z_retracted': sim.z_retracted,
                'mapping': {'stop': [sim.mapping.stop.x, sim.mapping.stop.y],
                            'park': [sim.mapping.park.x, sim.mapping.park.y], 'edge': sim.mapping.edge},
                'pending': None if sim.pending is None else {
                    'id': sim.pending.id, 'kind': sim.pending.kind,
                    'target': None if sim.pending.target is None else [sim.pending.target.x, sim.pending.target.y]},
                'actions': sim.snapshot()['actions'][-80:]}

    def snapshot(self):
        with self._lock:
            return self._snapshot()

    def event(self, session, revision, event, *, action_id=None, mapping=None, sequence_position=None):
        with self._lock:
            if session != self._session or revision != self._revision:
                raise StaleRehearsal('화면 상태가 변경됐어요. 새 상태를 확인하고 다시 선택해 주세요.')
            sim = self._sim
            if event == 'new':
                if mapping is None:
                    raise ValueError('mapping required')
                self._sim = ParkingSimulator(mapping)
                self._session = uuid4().hex
            elif event == 'locate':
                sim.locate_at_park()
            elif event == 'begin':
                sim.begin()
            elif event == 'sequence_finished':
                sim.sequence_finished(sequence_position)
            elif event == 'stop':
                sim.request_appliance_stop()
            elif event in ('ack', 'fail'):
                sim.acknowledge(action_id, success=event == 'ack')
            elif event == 'ended':
                sim.confirm_operation_ended()
            elif event in ('estop', 'link_lost'):
                sim.lock('actuator_emergency_stop' if event == 'estop' else event)
            else:
                raise ValueError('unknown rehearsal event')
            self._revision += 1
            return self._snapshot()
