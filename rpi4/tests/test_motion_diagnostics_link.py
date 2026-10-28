"""API to signed board link to synthetic motion MCU; no physical movement."""

import asyncio
import time
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
import rpi.api.dev_router as dev_router
from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.touchbridge_motion import TouchBridgeConfig, TouchBridgeMotionClient
from rpi.main import app
from rpi.services.act_client import ActClient
from rpi.services.act_client_controller import ActClientController, start_background_loop
from rpi.tests.test_touchbridge_motion import ReceivedSketch
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor
from rpi4.services.dev_motion import DevMotionService
from rpi4.tests.test_dev_motion_link import _PipeWriter, _manager


TOKEN = 'motion-diagnostics-test-token-1028'


@pytest.fixture(params=[None, 'motion-pair-test-key-1028'], ids=['plain', 'signed'])
def api_link(request, monkeypatch):
    loop, thread = start_background_loop()
    mcu = ReceivedSketch()
    motion = TouchBridgeMotionClient(mcu.pipe.host, TouchBridgeConfig(
        status_timeout_s=.3, connect_timeout_s=.5, move_timeout_s=3, press_timeout_s=.5))
    motion.connect()

    async def build():
        r4, r5 = asyncio.StreamReader(), asyncio.StreamReader()
        controller = ClosedLoopController(grbl=MockGrblClient(), verifier=MockVerifier(outcomes=[True]),
                                          alerts=MockAlertSink(), safety=MockSafetyController())
        executor = ActExecutor(reader=r4, writer=_PipeWriter(loop, r5), controller=controller,
                               dev_motion=DevMotionService(motion), link_key=request.param)
        executor.act_info = {'motion': 'serial', 'outlet': 'none', 'done_watch': []}
        task = asyncio.create_task(executor.run())
        client = ActClient(r5, _PipeWriter(loop, r4), hello=True, link_key=request.param)
        await client.start()
        return task, client

    task, client = asyncio.run_coroutine_threadsafe(build(), loop).result(5)
    act = ActClientController(loop, client)
    deadline = time.monotonic() + 3
    while not act.dev_motion_link()['act_info'].get('dev_motion_protocol') and time.monotonic() < deadline:
        time.sleep(.01)
    manager = _manager(act)
    monkeypatch.setenv('SIMPLELAY_API_KEY', TOKEN)
    monkeypatch.setenv('SIMPLELAY_DEV_MODE', '1')
    monkeypatch.setenv('SIMPLELAY_DEV_REAL_MOTION', '1')
    monkeypatch.setenv(dev_router.DEV_TOKEN_ENV, TOKEN)
    monkeypatch.setattr(deps, 'get_developer_session_manager', lambda: manager)
    monkeypatch.setattr(deps, 'get_control_arbiter', lambda: manager._arbiter)
    monkeypatch.setattr(dev_router, 'get_dev_api_state', lambda: state)
    state = dev_router.DevApiState()
    api = TestClient(app)
    headers = {'X-Dev-Token': TOKEN, 'X-API-Key': TOKEN}
    try:
        opened = api.post('/dev/sessions', headers=headers, json={'appliance_id': 'microwave', 'node_id': 'phone'})
        assert opened.status_code == 201, opened.text
        session = opened.json()
        headers['X-Dev-Session-Secret'] = session['session_secret']
        url = f"/dev/sessions/{session['session_id']}/commands"
        yield api, headers, url, mcu, motion
    finally:
        manager.close()
        asyncio.run_coroutine_threadsafe(client.stop(), loop).result(5)
        loop.call_soon_threadsafe(task.cancel)
        time.sleep(.05)
        loop.call_soon_threadsafe(loop.stop)
        thread.join(2)
        motion.close()
        mcu.close()


def test_api_single_press_and_trace_use_real_link_implementations(api_link):
    api, headers, url, mcu, motion = api_link
    def command(text, rid):
        return api.post(url, headers=headers, json={'appliance_id': 'microwave', 'text': text, 'request_id': rid})
    assert command('jog x + 1', 'move-1').status_code == 200
    before = len(mcu.commands)
    response = command('press_here', 'press-1')
    assert response.status_code == 200, response.text
    assert command('press_here', 'press-1').status_code == 409
    assert [c['action'] for c in mcu.commands[before:]] == ['status', 'press']
    trace = api.get('/dev/motion-trace', headers=headers)
    assert trace.status_code == 200
    rows = trace.json()['rows']
    assert any(r.get('action') == 'press' and r.get('context_id') for r in rows)
    assert 'positionToken' not in trace.text
    assert motion.position_xy() == (13.5, 20.25)


def test_trace_while_moving_does_not_wait_for_motion_or_block_stop(api_link):
    api, headers, url, mcu, _ = api_link
    mcu.hold_moves = True
    with ThreadPoolExecutor() as pool:
        move = pool.submit(api.post, url, headers=headers,
                           json={'appliance_id': 'microwave', 'text': 'jog x + 1', 'request_id': 'slow-1'})
        assert mcu.move_started.wait(1)
        started = time.monotonic()
        trace = api.get('/dev/motion-trace', headers=headers)
        assert trace.status_code == 200
        assert time.monotonic() - started < 1
        assert not move.done()
        stopped = api.post('/dev/stop', headers=headers)
        assert stopped.status_code == 200
        assert move.result(3).status_code == 409
    assert any(c['action'] == 'stop' for c in mcu.commands)
    assert not any(c['action'] == 'press' for c in mcu.commands)
