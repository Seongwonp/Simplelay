"""Seams using the received sketch's wire shapes, not line-json/v0 replies."""

from __future__ import annotations

import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import (
    InMemoryLinePipe, MotionPositionMismatch, MotionPressFailed, MotionReset,
    MotionStopped, MotionTimeout,
)
from rpi.controller.touchbridge_motion import TouchBridgeConfig, TouchBridgeMotionClient


class ReceivedSketch:
    """Only USB v2 shapes emitted by handleJson/handleEvent in the received ino."""

    def __init__(self):
        self.pipe = InMemoryLinePipe()
        self.closed = threading.Event()
        self.move_started = threading.Event()
        self.commands = []
        self.position = (12.5, 20.25)
        self.homed = True
        self.hold_moves = False
        self.omit_positioned = False
        self.press_error = None
        self.press_script = None  # [(state, fields)] replaces the default press replies
        self.move_reject = None  # state answered instead of RECEIVED (e.g. ERROR_NOT_HOMED)
        self.move = None
        self.token = "0123456789abcdef"
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def send(self, command, state, **fields):
        self.pipe.device.write_line(json.dumps(
            {"version": 2, "commandId": command["commandId"], "state": state, **fields}
        ))

    def finish_move(self):
        command = self.move
        self.position = command["target"]["xMm"], command["target"]["yMm"]
        if not self.omit_positioned:
            self.send(command, "POSITIONED", position={"xMm": self.position[0], "yMm": self.position[1]},
                      errorMm=0.0, positionToken=self.token)
        self.send(command, "COMPLETED")

    def _run(self):
        while not self.closed.is_set():
            line = self.pipe.device.read_line(0.02)
            if line is None:
                continue
            command = json.loads(line)
            self.commands.append(command)
            action = command["action"]
            if action == "status":
                self.send(command, "COMPLETED", homed=self.homed,
                          position={"xMm": self.position[0], "yMm": self.position[1]})
            elif action == "move_only" and self.move_reject is not None:
                self.send(command, self.move_reject)
            elif action == "move_only":
                self.move = command
                self.send(command, "RECEIVED")
                self.send(command, "MOVING")
                self.move_started.set()
                if not self.hold_moves:
                    self.finish_move()
            elif action == "press" and self.press_script is not None:
                for state, fields in self.press_script:
                    self.send(command, state, **fields)
            elif action == "press":
                self.send(command, "RECEIVED")
                self.send(command, "PRESSING")
                if self.press_error:
                    self.send(command, self.press_error, message="BOT_TIMEOUT")
                else:
                    self.send(command, "COMPLETED")
            elif action == "home":
                self.position = (0.0, 0.0)
                self.homed = True
                self.send(command, "HOMED", homed=True)
                self.send(command, "COMPLETED", homed=True)
            elif action == "stop":
                if self.move is not None:
                    self.send(self.move, "STOPPED")
                self.send(command, "STOPPED")

    def close(self):
        self.closed.set()
        self.thread.join(1)


@pytest.fixture
def rig():
    mcu = ReceivedSketch()
    config = TouchBridgeConfig(status_timeout_s=0.3, connect_timeout_s=0.5,
                               move_timeout_s=0.5, press_timeout_s=0.3)
    unclaimed = []
    client = TouchBridgeMotionClient(mcu.pipe.host, config, on_unclaimed_line=unclaimed.append)
    try:
        yield client, mcu, unclaimed
    finally:
        client.close()
        mcu.close()


def test_connect_reads_real_v2_status_without_counts_configuration_or_automatic_home(rig):
    client, mcu, _ = rig
    status = client.connect()
    assert status.homed and status.a_counts is None and status.b_counts is None
    assert client.position_xy(status) == (12.5, 20.25)
    assert client.not_ready_reason() is None
    assert [c["action"] for c in mcu.commands] == ["status"]


def test_move_and_press_keep_mm_and_received_position_token_in_the_same_command_chain(rig):
    client, mcu, _ = rig
    client.connect()
    observed = []
    client.press_with_observation(PressCommand("start", x_mm=80.75, y_mm=42.5),
                                  lambda: observed.append([c["action"] for c in mcu.commands]))
    move, press = mcu.commands[-2:]
    assert move["target"] == {"xMm": 80.75, "yMm": 42.5}
    assert "a" not in move and "b" not in move
    assert press["positionToken"] == mcu.token
    assert move["commandId"] != press["commandId"]
    assert observed == [["status", "move_only"]]
    assert client.last_position == {"x_mm": 80.75, "y_mm": 42.5}


def test_completed_without_positioned_never_presses_even_after_a_previous_good_move(rig):
    client, mcu, _ = rig
    client.connect()
    client.move_to(1, 2)
    mcu.omit_positioned = True
    with pytest.raises(MotionPositionMismatch):
        client.press(PressCommand("start", x_mm=3, y_mm=4))
    assert "press" not in [c["action"] for c in mcu.commands]


def test_status_during_move_and_wrong_ids_do_not_consume_movement_events(rig):
    client, mcu, unclaimed = rig
    client.connect()
    mcu.hold_moves = True
    with ThreadPoolExecutor() as pool:
        move = pool.submit(client.move_to, 3, 4)
        assert mcu.move_started.wait(1)
        mcu.send({"commandId": "someone-else"}, "COMPLETED")
        assert client.status().homed
        assert not move.done()
        mcu.finish_move()
        move.result(timeout=1)
    assert client.last_position == {"x_mm": 3, "y_mm": 4}
    assert any("someone-else" in line for line in unclaimed)


def test_stop_goes_out_while_movement_waits_and_ack_is_bound_to_its_id(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.hold_moves = True
    with ThreadPoolExecutor() as pool:
        move = pool.submit(client.move_to, 3, 4)
        assert mcu.move_started.wait(1)
        assert client.request_stop()
        stop_id = client.last_stop_id
        report = client.confirm_stop(stop_id=stop_id)
        with pytest.raises(MotionStopped):
            move.result(timeout=1)
    assert report.stop_id == stop_id and report.sent
    assert report.level == "mcu_ack"  # never claims physical verification
    assert report.ack_ms is not None
    assert "엔코더" in report.detail


def test_bot_failure_is_not_a_motion_success_or_an_automatic_repress(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.press_error = "ERROR_TIMEOUT"
    with pytest.raises(MotionPressFailed) as result:
        client.press(PressCommand("start", x_mm=3, y_mm=4))
    assert result.value.press_outcome == "unknown"
    assert [c["action"] for c in mcu.commands].count("press") == 1


def test_restart_fails_an_outstanding_move_instead_of_accepting_a_late_completion(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.hold_moves = True
    with ThreadPoolExecutor() as pool:
        move = pool.submit(client.move_to, 3, 4)
        assert mcu.move_started.wait(1)
        mcu.pipe.device.write_line("Touch Bridge CoreXY v4 ready (BLE: device, key=none)")
        with pytest.raises(MotionReset):
            move.result(timeout=1)
    assert client.needs_reconnect and not client.homed
    assert client.last_position is None


def test_timeout_ends_the_request_and_sends_the_original_stop_action(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.hold_moves = True
    with pytest.raises(MotionTimeout):
        client.move_to(3, 4)
    assert client.confirm_stop().level == "mcu_ack"
    assert [c["action"] for c in mcu.commands][-1] == "stop"


def test_unhomed_is_reported_without_inserting_home(rig):
    client, mcu, _ = rig
    mcu.homed = False
    assert not client.connect().homed
    assert "좌표 기준" in client.not_ready_reason()
    assert [c["action"] for c in mcu.commands] == ["status"]


def test_wire_length_and_nonfinite_input_are_rejected_before_writing(rig):
    client, mcu, _ = rig
    from rpi.controller.serial_motion import MotionRefused

    with pytest.raises(MotionRefused):
        client._exchange("status", 0.1, padding="x" * 255)
    with pytest.raises(MotionRefused):
        client.move_to(float("nan"), 3)
    assert mcu.commands == []


@pytest.mark.parametrize("value", ["nan", "inf", "0", "-1"])
def test_invalid_timeouts_do_not_create_a_link(value):
    with pytest.raises(ValueError):
        TouchBridgeConfig.from_env({"SIMPLELAY_MOTION_MOVE_TIMEOUT_S": value})


def test_build_executor_and_dev_service_use_touchbridge_without_encoder_config(monkeypatch, rig):
    import rpi4.act_main as act_main
    from rpi4.models.act_messages import DevMotionMsg
    from rpi.services.dev_real_motion import ActDevMotionAdapter

    client, mcu, _ = rig
    client.close()  # the factory below must be the only reader on this USB pipe
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PROTOCOL", "touchbridge-v2")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/received-sketch")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda *_: mcu.pipe.host)
    # Build through the real factory, not a stub returning the desired class.
    built = None
    try:
        built, safety = act_main._build_motion()
        assert isinstance(built, TouchBridgeMotionClient)
        assert built.position_xy() == (12.5, 20.25)
        monkeypatch.setattr(act_main, "_build_motion", lambda **_: (built, safety))
        executor = act_main._build_executor(object(), object())
        act_main._describe_act(executor, outlet_kind="none", motion_kind="serial")
        assert executor._motion_stop is built
        assert executor.act_info["motion_protocol"] == "touchbridge-v2"
        service = executor._dev_motion
        assert service.run(DevMotionMsg("status-1", "status")) == {
            "ok": True, "homed": True, "x_mm": 12.5, "y_mm": 20.25,
        }
        assert service.run(DevMotionMsg("jog-1", "jog", axis="x", delta_mm=1))["ok"]
        assert service.run(DevMotionMsg("jog-2", "jog", axis="y", delta_mm=1))["ok"]
        assert "home" not in [c["action"] for c in mcu.commands]
        assert service.run(DevMotionMsg("press-1", "press", label="start"))["ok"]
        assert ActDevMotionAdapter._supports_dev({"act_info": {
            **executor.act_info, "dev_motion_protocol": 2,
        }})
    finally:
        if act_main._motion_watch is not None:
            act_main._motion_watch.stop()
            act_main._motion_watch = None
        if act_main._motion_retry is not None:
            act_main._motion_retry.stop()
            act_main._motion_retry = None
        if built is not None:
            built.close()


def test_bad_protocol_is_rejected_before_opening_a_port(monkeypatch):
    import rpi4.act_main as act_main

    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PROTOCOL", "typo")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    opened = []
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda *_: opened.append(True))
    with pytest.raises(RuntimeError, match="SIMPLELAY_MOTION_PROTOCOL"):
        act_main._build_motion()
    assert opened == []


def test_late_processing_of_an_old_status_does_not_overwrite_newer_arrival(rig, monkeypatch):
    client, mcu, _ = rig
    client.connect()
    status_received, release_status = threading.Event(), threading.Event()
    original = client._exchange

    def gated(action, timeout, **fields):
        reply = original(action, timeout, **fields)
        if action == "status":
            status_received.set()
            assert release_status.wait(2)
        return reply

    monkeypatch.setattr(client, "_exchange", gated)
    with ThreadPoolExecutor() as pool:
        old_status = pool.submit(client.status)
        assert status_received.wait(1)
        try:
            client.move_to(40, 50)
        finally:
            release_status.set()
        old_status.result(timeout=1)
    assert client.last_position == {"x_mm": 40, "y_mm": 50}


def test_reader_failure_wakes_the_waiter_and_reports_link_loss():
    mcu = ReceivedSketch()
    down = threading.Event()

    class Transport:
        def write_line(self, line):
            mcu.pipe.host.write_line(line)

        def read_line(self, timeout):
            if down.is_set():
                raise OSError("USB lost")
            return mcu.pipe.host.read_line(min(timeout, 0.02))

    client = TouchBridgeMotionClient(Transport())
    try:
        client.connect()
        mcu.hold_moves = True
        with ThreadPoolExecutor() as pool:
            move = pool.submit(client.move_to, 3, 4)
            assert mcu.move_started.wait(1)
            down.set()
            with pytest.raises(OSError, match="연결 끊김"):
                move.result(timeout=1)
        assert client.needs_reconnect
        assert client.link_not_ready_reason() is not None
    finally:
        client.close()
        mcu.close()


# ── 2026-10-24: remaining v2 state shapes of the received sketch (banner "v4") ──

from rpi.controller.closed_loop import motion_abort_reason  # noqa: E402
from rpi.controller.serial_motion import (  # noqa: E402
    MotionAlarm, MotionNotReady, MotionRefused,
)


def _held_move(client, mcu, pool):
    mcu.hold_moves = True
    move = pool.submit(client.move_to, 3, 4)
    assert mcu.move_started.wait(1)
    return move


@pytest.mark.parametrize(("state", "fields", "kind", "abort"), [
    ("ERROR_STALL", {}, MotionAlarm, "motion_alarm: ERROR_STALL"),
    ("ERROR_TIMEOUT", {}, MotionAlarm, "motion_alarm: ERROR_TIMEOUT"),
    ("ERROR_LIMIT", {}, MotionRefused, None),
    ("ERROR_POSITION", {"position": {"xMm": 2.9, "yMm": 6.1}, "errorMm": 2.1}, MotionAlarm,
     "motion_alarm: ERROR_POSITION"),
])
def test_movement_errors_keep_the_firmware_reason_and_never_press(rig, state, fields, kind, abort):
    client, mcu, _ = rig
    client.connect()
    with ThreadPoolExecutor() as pool:
        move = _held_move(client, mcu, pool)
        mcu.send(mcu.move, state, **fields)
        with pytest.raises(kind) as raised:
            move.result(timeout=1)
    assert state in str(raised.value)
    assert motion_abort_reason(raised.value) == abort
    assert client._token is None
    assert "press" not in [c["action"] for c in mcu.commands]


def test_position_error_keeps_the_reported_position_for_the_operator(rig):
    client, mcu, _ = rig
    client.connect()
    with ThreadPoolExecutor() as pool:
        move = _held_move(client, mcu, pool)
        mcu.send(mcu.move, "ERROR_POSITION", position={"xMm": 2.9, "yMm": 6.1}, errorMm=2.1)
        with pytest.raises(MotionAlarm):
            move.result(timeout=1)
    assert client.last_position == {"x_mm": 2.9, "y_mm": 6.1}


def test_not_homed_reply_clears_the_homed_flag_without_sending_home(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.move_reject = "ERROR_NOT_HOMED"
    with pytest.raises(MotionNotReady):
        client.move_to(3, 4)
    assert not client.homed
    assert "home" not in [c["action"] for c in mcu.commands]


def test_busy_reply_is_a_refusal_before_motion(rig):
    client, mcu, _ = rig
    client.connect()
    original = mcu.send

    def busy(command, state, **fields):
        if command.get("action") == "move_only" and state == "RECEIVED":
            return original(command, "ERROR_PROTOCOL", message="BUSY")
        if command.get("action") == "move_only":
            return None
        return original(command, state, **fields)

    mcu.send = busy
    with pytest.raises(MotionRefused) as raised:
        client.move_to(3, 4)
    assert raised.value.code == "busy"


@pytest.mark.parametrize("script", [
    [("ERROR_INVALID_TOKEN", {})],
    [("ERROR_PROTOCOL", {"message": "AUTH_REQUIRED"})],
])
def test_press_rejected_before_received_is_known_not_pressed(rig, script):
    client, mcu, _ = rig
    client.connect()
    mcu.press_script = script
    with pytest.raises(MotionPressFailed) as raised:
        client.press(PressCommand("start", x_mm=3, y_mm=4))
    assert raised.value.press_outcome == "not_pressed"


@pytest.mark.parametrize(("state", "message"), [
    ("ERROR_PROTOCOL", "BOT_BUSY"),
    ("ERROR_PROTOCOL", "BOT_LOW_BATTERY"),
    ("ERROR_TIMEOUT", "ACK_TIMEOUT"),
    ("ERROR_TIMEOUT", "BOT_TIMEOUT"),
    ("ERROR_TIMEOUT", None),  # failActive(ERROR_TIMEOUT) carries no message on the JSON path
])
def test_press_errors_after_pressing_are_unknown_and_never_repressed(rig, state, message):
    client, mcu, _ = rig
    client.connect()
    fields = {} if message is None else {"message": message}
    mcu.press_script = [("RECEIVED", {}), ("PRESSING", {}), (state, fields)]
    with pytest.raises(MotionPressFailed) as raised:
        client.press(PressCommand("start", x_mm=3, y_mm=4))
    assert raised.value.press_outcome == "unknown"
    assert raised.value.reason == state
    assert motion_abort_reason(raised.value) == f"motion_press_failed: {state}"
    assert [c["action"] for c in mcu.commands].count("press") == 1


def test_press_without_any_final_reply_is_unknown_and_sends_stop(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.press_script = [("RECEIVED", {}), ("PRESSING", {})]
    with pytest.raises(MotionTimeout) as raised:
        client.press(PressCommand("start", x_mm=3, y_mm=4))
    assert getattr(raised.value, "press_outcome", None) == "unknown"
    assert motion_abort_reason(raised.value) is not None  # closed loop must not press again
    assert client.confirm_stop().level == "mcu_ack"
    actions = [c["action"] for c in mcu.commands]
    assert actions.count("press") == 1 and actions[-1] == "stop"


def test_device_side_stop_during_move_is_not_retried_by_the_closed_loop(rig):
    """STOPPED without a host stop (e.g. the owner's BLE app) must end the run, not trigger a retry."""
    client, mcu, _ = rig
    client.connect()
    with ThreadPoolExecutor() as pool:
        move = _held_move(client, mcu, pool)
        mcu.send(mcu.move, "STOPPED")
        with pytest.raises(MotionStopped) as raised:
            move.result(timeout=1)
    assert motion_abort_reason(raised.value) == "motion_stopped"


def test_stop_after_pressing_leaves_the_press_unknown(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.press_script = [("RECEIVED", {}), ("PRESSING", {}), ("STOPPED", {})]
    with pytest.raises(MotionStopped) as raised:
        client.press(PressCommand("start", x_mm=3, y_mm=4))
    assert raised.value.press_outcome == "unknown"
    assert [c["action"] for c in mcu.commands].count("press") == 1


def test_host_requested_stop_keeps_the_existing_stop_semantics(rig):
    client, mcu, _ = rig
    client.connect()
    with ThreadPoolExecutor() as pool:
        move = _held_move(client, mcu, pool)
        assert client.request_stop()
        with pytest.raises(MotionStopped) as raised:
            move.result(timeout=1)
    # the closed loop already knows about its own stop; no device-stop abort reason is added
    assert motion_abort_reason(raised.value) is None


def test_stop_is_written_even_while_the_link_is_marked_for_reconnect(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.pipe.device.write_line("Touch Bridge CoreXY v4 ready (BLE: device, key=none)")
    deadline = time.monotonic() + 1
    while not client.needs_reconnect and time.monotonic() < deadline:
        time.sleep(0.01)
    assert client.needs_reconnect
    assert client.request_stop()
    assert client.confirm_stop().level == "mcu_ack"
    assert mcu.commands[-1]["action"] == "stop"


def test_malformed_and_foreign_lines_are_ignored_while_a_move_completes(rig):
    client, mcu, unclaimed = rig
    client.connect()
    with ThreadPoolExecutor() as pool:
        move = _held_move(client, mcu, pool)
        for junk in ("ERROR:JSON", "{\"version\":2,\"commandId\":", "{\"version\":1,\"state\":\"COMPLETED\"}",
                     "[1,2]", "\x00\xff garbage", "HOMED", "STOPPED"):
            mcu.pipe.device.write_line(junk)
        mcu.send({"commandId": "unknown-id"}, "STOPPED")
        assert not move.done()
        mcu.finish_move()
        move.result(timeout=1)
    assert client.last_position == {"x_mm": 3, "y_mm": 4}
    assert "ERROR:JSON" in unclaimed and any("unknown-id" in line for line in unclaimed)


def test_banner_version_is_recorded_and_a_new_status_reconnects_without_home(rig):
    client, mcu, _ = rig
    client.connect()
    mcu.pipe.device.write_line("Touch Bridge CoreXY v4 ready (BLE: device, key=none)")
    deadline = time.monotonic() + 1
    while not client.needs_reconnect and time.monotonic() < deadline:
        time.sleep(0.01)
    assert client.ready_info["fw"] == "Touch Bridge CoreXY v4"
    mcu.homed = False  # firmware restarts unhomed
    status = client.connect()
    assert not client.needs_reconnect and not status.homed
    assert "home" not in [c["action"] for c in mcu.commands]
