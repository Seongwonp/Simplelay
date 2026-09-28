"""Independent multi-appliance rehearsal. No executor or hardware dependencies."""
from copy import deepcopy
from threading import Lock
from uuid import uuid4

from .parking_rehearsal import StaleRehearsal


class RoutineRehearsal:
    def __init__(self):
        self._lock = Lock()
        self._reset()

    def _reset(self):
        self._state = {
            'session': uuid4().hex, 'revision': 0, 'phase': 'draft',
            'execution_mode': 'mock', 'stop_requested': False,
            'reason': '합성 이력: 저녁에 공기청정기와 선풍기를 함께 사용한 예시',
            'items': [
                {'id': 'purifier', 'name': '공기청정기', 'action': '켜기',
                 'selected': True, 'status': 'not_started', 'receipt': 'not_dispatched', 'confirmation': 'none'},
                {'id': 'fan', 'name': '선풍기', 'action': '약풍으로 켜기',
                 'selected': True, 'status': 'not_started', 'receipt': 'not_dispatched', 'confirmation': 'none'},
            ],
        }

    def snapshot(self):
        with self._lock:
            return deepcopy(self._state)

    def event(self, session, revision, event, selected=None):
        with self._lock:
            s = self._state
            if session != s['session'] or revision != s['revision']:
                raise StaleRehearsal('다른 화면에서 변경됐어요. 최신 미리보기를 확인하세요.')
            if event == 'reset':
                if s['phase'] in ('running', 'stopping'):
                    raise ValueError('진행 중에는 새 시나리오를 시작할 수 없어요.')
                self._reset()
                return deepcopy(self._state)
            if event == 'review':
                if s['phase'] not in ('draft', 'review'):
                    raise ValueError('실행을 시작한 구성은 수정할 수 없어요.')
                valid = {item['id'] for item in s['items']}
                if (not isinstance(selected, list) or not selected
                        or any(not isinstance(value, str) for value in selected)
                        or len(set(selected)) != len(selected) or not set(selected) <= valid):
                    raise ValueError('실행할 가전을 하나 이상 선택하세요.')
                for item in s['items']:
                    item['selected'] = item['id'] in selected
                    item['status'] = 'not_started' if item['selected'] else 'excluded'
                s['phase'] = 'review'
            elif event == 'approve':
                if s['phase'] != 'review':
                    raise ValueError('먼저 새 미리보기를 확인하세요.')
                s['phase'] = 'running'
                self._start_next()
            elif event in ('success', 'failure', 'link_lost', 'stop', 'stop_confirmed'):
                active = next((i for i in s['items'] if i['status'] == 'running'), None)
                if active is None or s['phase'] not in ('running', 'stopping'):
                    raise ValueError('결과를 주입할 진행 중 가전이 없어요.')
                if event == 'stop':
                    if s['stop_requested']:
                        raise ValueError('이미 정지를 요청했어요.')
                    s['stop_requested'] = True
                    s['phase'] = 'stopping'
                    self._cancel_waiting()
                elif event == 'stop_confirmed':
                    if s['phase'] != 'stopping':
                        raise ValueError('정지 요청이 먼저 필요해요.')
                    active.update(status='stopped', receipt='accepted', confirmation='mock_stop')
                    s['phase'] = 'halted'
                elif event == 'link_lost':
                    active.update(status='unconfirmed', confirmation='none')
                    self._cancel_waiting()
                    s['phase'] = 'unconfirmed'
                elif event == 'failure':
                    active.update(status='failed', receipt='accepted', confirmation='mock_failure')
                    self._cancel_waiting()
                    s['phase'] = 'halted'
                else:
                    active.update(status='succeeded', receipt='accepted', confirmation='mock_operation')
                    if s['stop_requested']:
                        s['phase'] = 'halted'
                    else:
                        self._start_next()
            else:
                raise ValueError('unknown routine event')
            s['revision'] += 1
            return deepcopy(s)

    def _cancel_waiting(self):
        for item in self._state['items']:
            if item['selected'] and item['status'] == 'not_started':
                item['status'] = 'cancelled'

    def _start_next(self):
        item = next((i for i in self._state['items']
                     if i['selected'] and i['status'] == 'not_started'), None)
        if item is None:
            self._state['phase'] = 'completed'
        else:
            # Sending a mock command alone does not prove receipt or success.
            item.update(status='running', receipt='unknown', confirmation='none')
