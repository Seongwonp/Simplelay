"""Host regression checks with synthetic v2 responses, without hardware."""

import json

import pytest

from rpi.controller.serial_motion import MotionPositionMismatch, MotionReset, MotionRefused
from rpi.tests.test_touchbridge_motion import rig  # noqa: F401
from rpi4.models.act_messages import DevMotionMsg, parse_act_message
from rpi4.services.dev_motion import DevMotionService


def test_press_here_consumes_existing_position_token_without_xy_or_origin(rig):
    client, mcu, _ = rig
    client.connect()
    client.move_to(14, 23)
    before = len(mcu.commands)
    client.press_here()
    assert [c['action'] for c in mcu.commands[before:]] == ['status', 'press']
    assert client.last_position == {'x_mm': 14, 'y_mm': 23}
    with pytest.raises(MotionRefused):
        client.press_here()
    assert sum(c['action'] == 'press' for c in mcu.commands) == 1


def test_press_here_without_token_does_not_send_press(rig):
    client, mcu, _ = rig
    client.connect()
    with pytest.raises(MotionRefused):
        client.press_here()
    assert not any(c['action'] in ('press', 'home', 'move_only') for c in mcu.commands)


def test_press_here_checks_reported_position_before_sending(rig):
    client, mcu, _ = rig
    client.connect()
    client.move_to(14, 23)
    mcu.position = (0, 0)
    with pytest.raises(MotionPositionMismatch):
        client.press_here()
    assert not client.homed
    assert not any(c['action'] == 'press' for c in mcu.commands)


def test_status_started_before_boot_cannot_restore_old_origin(rig, monkeypatch):
    client, _, _ = rig
    client.connect()
    def old_reply(*args, **kwargs):
        client._booted()
        return {'homed': True, 'position': {'xMm': 22, 'yMm': 33}, '_rx_seq': 999}
    monkeypatch.setattr(client, '_exchange', old_reply)
    with pytest.raises(MotionReset):
        client.status()
    assert not client.homed
    assert client.last_position is None


def test_late_status_cannot_overwrite_newer_origin_state(rig, monkeypatch):
    client, _, _ = rig
    client.connect()
    client._position_seq = 100
    monkeypatch.setattr(client, '_exchange', lambda *a, **kw: {
        'homed': False, 'position': {'xMm': 0, 'yMm': 0}, '_rx_seq': 1})
    assert client.status().homed is True
    assert client.homed
    assert client.last_position == {'x_mm': 12.5, 'y_mm': 20.25}


def test_trace_is_bounded_sanitized_and_keeps_wire_ids(rig):
    client, mcu, _ = rig
    client.connect()
    client.move_to(14, 23)
    client.press_here()
    rows = client.motion_trace()
    assert any(r.get('action') == 'press' and r['direction'] == 'tx' for r in rows)
    assert any(r.get('state') == 'COMPLETED' and r['direction'] == 'rx' for r in rows)
    assert all('generation' in r and 'seq' in r and 'elapsed_ms' in r for r in rows)
    for _ in range(150):
        client._trace_event('rx', {'commandId': 'bounded', 'state': 'COMPLETED',
                                  'token': 'secret', 'message': 'secret'})
    assert len(client.motion_trace()) <= 100
    assert 'secret' not in json.dumps(client.motion_trace())


def test_dev_press_here_wire_and_result_trace(rig):
    client, mcu, _ = rig
    client.connect()
    client.move_to(14, 23)
    msg = parse_act_message(json.dumps({'type': 'dev_motion', 'request_id': 'tap-1', 'op': 'press_here'}))
    assert isinstance(msg, DevMotionMsg)
    before = len(mcu.commands)
    result = DevMotionService(client).run(msg)
    assert result['ok'] is True
    assert result['motion_trace']
    assert [c['action'] for c in mcu.commands[before:]] == ['status', 'press']


def test_dev_trace_read_has_no_hardware_io(rig):
    client, mcu, _ = rig
    client.connect()
    before = len(mcu.commands)
    result = DevMotionService(client).trace()
    assert result['motion_trace']
    assert len(mcu.commands) == before


def test_reboot_report_cannot_be_cleared_by_status_only(rig):
    client, _, _ = rig
    client.connect()
    client._booted()
    assert client.status().homed is False
    assert not client.homed


def test_trace_context_binds_tx_and_rx_to_one_rpi4_request(rig):
    client, _, _ = rig
    client.connect()
    with client.diagnostic_context('run-1028'):
        client.move_to(14, 23)
        client.press_here()
    rows = [r for r in client.motion_trace() if r.get('context_id') == 'run-1028']
    assert {r['direction'] for r in rows} == {'tx', 'rx'}
    tx = {r['commandId'] for r in rows if r['direction'] == 'tx'}
    assert tx == {r['commandId'] for r in rows if r['direction'] == 'rx'}


def test_missing_position_is_not_replaced_with_requested_target(rig, monkeypatch):
    client, _, _ = rig
    client.connect()
    move = client.move_to
    def forget(x, y):
        move(x, y)
        client._position = None
    monkeypatch.setattr(client, 'move_to', forget)
    result = DevMotionService(client).run(DevMotionMsg('missing-pos', 'jog', axis='x', delta_mm=1))
    assert result['target_x_mm'] == 13.5
    assert result['x_mm'] is None and result['y_mm'] is None
    assert 'error_mm' not in result


def test_single_press_cannot_clear_a_stop_that_already_arrived(rig):
    client, mcu, _ = rig
    client.connect()
    client.move_to(14, 23)
    client.request_stop()
    result = DevMotionService(client).run(DevMotionMsg('stopped-tap', 'press_here'))
    assert result['ok'] is False
    assert client._stopped.is_set()
    assert not any(c['action'] == 'press' for c in mcu.commands)


def test_status_from_before_explicit_home_cannot_restore_old_coordinates(rig, monkeypatch):
    client, _, _ = rig
    client.connect()
    exchange = client._exchange
    first = True
    def delayed(action, timeout, **fields):
        nonlocal first
        reply = exchange(action, timeout, **fields)
        if action == 'status' and first:
            first = False
            client.home()
            reply['_rx_seq'] = client._rx_seq + 1
        return reply
    monkeypatch.setattr(client, '_exchange', delayed)
    with pytest.raises(MotionReset):
        client.status()
    assert client.position_xy() == (0, 0)


def test_invalid_large_coordinate_cannot_break_diagnostic_collection(rig):
    client, _, _ = rig
    client._trace_event('rx', {'position': {'xMm': 10 ** 400, 'yMm': 1}})
    assert 'x_mm' not in client.motion_trace()[-1]
