import json
import sys
from types import SimpleNamespace

import pytest

from rpi.tools.board_probe import core
from rpi.tools.board_probe.active import run_active


@pytest.fixture
def check():
    return {"id": "private-id", "kind": "dbus_method", "target": "org.example.Private"}


@pytest.mark.parametrize("root,matching,success", [(False, True, True), (True, True, True), (False, False, True), (False, True, False)])
def test_permission_separate_from_presence(check, root, matching, success):
    def fake(c, r):
        r.update(present=True, introspect_ok=True, signatures="private-signature", call_attempted=True)
        if not success:
            raise PermissionError("private-denial")
        r["min_call_ok"] = True
    r = core.run_check(check, "app", {"name": "app" if matching else "other", "uid": 0 if root else 1000, "root_only": root}, fake)
    assert r["present"] is True
    assert r["introspect_ok"] is True
    assert r["app_permission"] is (success and matching and not root)
    assert r["min_call_ok"] is success
    assert r["latency_ms"] >= 0
    report = {"timestamp_utc": "2000-01-01T00:00:00+00:00", "checks": [r]}
    assert "private" not in core.summary(report).lower()


def test_absent_not_permission(check):
    r = core.run_check(check, "app", dbus_runner=lambda c, r: r.update(present=False))
    assert r["app_permission"] is None
    assert r["min_call_ok"] is None


@pytest.mark.parametrize("status", [{"running": True}, {}, {"running": 0}, {"running": "false"}])
def test_active_refuses_uncertain_status(status):
    with pytest.raises(RuntimeError):
        run_active({"status_url": "http://localhost/status"}, True, lambda _: json.dumps(status))


def test_active_needs_ack_before_network():
    with pytest.raises(ValueError):
        run_active({}, False, lambda _: pytest.fail("network called"))


def test_local_boundary(tmp_path):
    with pytest.raises(ValueError):
        core.outside(core.ROOT / "data" / "probe.json")
    report = {"timestamp_utc": "2000-01-01T00:00:00+00:00", "checks": []}
    path = core.save(report, tmp_path)
    assert json.loads(path.read_text(encoding="utf-8")) == report


def test_serial_never_opens(tmp_path, monkeypatch):
    port = tmp_path / "serial"
    port.touch()
    monkeypatch.setattr(core.os, "open", lambda *a: pytest.fail("serial opened"))
    r = core.run_check({"id": "uart", "kind": "serial_port", "target": str(port)}, "app")
    assert r["present"] is True
    assert not r["call_attempted"]


@pytest.mark.parametrize("deny_intro,deny_call", [(False, False), (True, False), (False, True)])
def test_dbus_transport_fixtures(check, monkeypatch, deny_intro, deny_call):
    MessageFlag = SimpleNamespace(NO_AUTO_START=2)
    MessageType = SimpleNamespace(ERROR=3, METHOD_RETURN=2)
    calls = []
    class Bus:
        async def connect(self):
            return self

        def disconnect(self):
            calls.append("disconnect")

        async def call(self, msg):
            assert msg.flags & MessageFlag.NO_AUTO_START
            calls.append(msg.member)
            denied = (msg.member == "Introspect" and deny_intro) or (msg.member == "GetStatus" and deny_call)
            body = [True] if msg.member == "NameHasOwner" else ["<node><interface name='org.example.Private'><method name='GetStatus'><arg type='s' direction='out'/></method></interface></node>"]
            return SimpleNamespace(message_type=MessageType.ERROR if denied else MessageType.METHOD_RETURN,
                                   error_name="org.freedesktop.DBus.Error.AccessDenied", body=body)
    monkeypatch.setitem(sys.modules, "dbus_fast", SimpleNamespace(
        MessageFlag=MessageFlag, MessageType=MessageType, Message=SimpleNamespace,
        BusType=SimpleNamespace(SYSTEM=0, SESSION=1)))
    monkeypatch.setitem(sys.modules, "dbus_fast.aio", SimpleNamespace(MessageBus=lambda **kw: Bus()))
    check.update(path="/org/example/Private", call={"interface": "org.example.Private", "member": "GetStatus"})
    r = core.run_check(check, "app", {"name": "app", "uid": 1000, "root_only": False})
    assert r["introspect_ok"] is (not deny_intro)
    assert r["min_call_ok"] is (not deny_call)
    assert calls == ["NameHasOwner", "Introspect", "GetStatus", "disconnect"]
