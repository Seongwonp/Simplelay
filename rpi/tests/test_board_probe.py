import json
import sys
from types import SimpleNamespace

import pytest

from rpi.tools.board_probe import core
from rpi.tools.board_probe.active import run_active
from rpi.tools.board_probe import active


@pytest.mark.parametrize("real_types", [False, True])
def test_raw_dbus_values_survive_save(tmp_path, monkeypatch, real_types):
    class Variant:
        def __init__(self, signature, value):
            self.signature, self.value = signature, value
    if real_types:
        Variant = pytest.importorskip("dbus_fast").Variant
    else:
        monkeypatch.setitem(sys.modules, "dbus_fast", SimpleNamespace(Variant=Variant))
    class Unknown:
        def __repr__(self):
            return "opaque reply"
    reply = Variant("a{sv}", {"data": Variant("ay", b"\x00\xff"),
                               "struct": Variant("(ogai)", ["/device", "ai", [1, 2]])})
    report = {"timestamp_utc": "2000-01-01T00:00:00+00:00", "checks": [],
              "reply": reply, "unknown": Unknown(), "keys": {1: "one", "1": "text"}}
    saved = json.loads(core.save(report, tmp_path).read_text(encoding="utf-8"))
    assert saved["reply"]["__dbus__"] == "variant"
    assert saved["reply"]["signature"] == "a{sv}"
    assert saved["reply"]["value"]["data"]["value"] == {"__dbus__": "bytes", "value": [0, 255]}
    assert saved["reply"]["value"]["struct"]["signature"] == "(ogai)"
    assert saved["reply"]["value"]["struct"]["value"] == ["/device", "ai", [1, 2]]
    assert saved["unknown"]["repr"] == "opaque reply"
    assert saved["unknown"]["type"].endswith("Unknown")
    assert saved["keys"]["value"] == [[1, "one"], ["1", "text"]]


def test_raw_fallback_handles_cycles_and_broken_repr():
    class Broken:
        def __repr__(self):
            raise ValueError("broken repr")
    cycle = []
    cycle.append(cycle)
    result = json.loads(json.dumps(core.raw_json([cycle, Broken(), (b"a",)])))
    assert result[0][0]["type"] == "builtins.list"
    assert result[1]["repr"] == "<repr unavailable>"
    assert result[2]["__dbus__"] == "tuple"


def test_minimal_call_timeout_is_recorded(monkeypatch, check):
    import asyncio
    async def blocked(c, r):
        r["call_attempted"] = True
        await asyncio.sleep(60)
    monkeypatch.setattr(core, "dbus_probe", blocked)
    result = core.run_check(check, "app", timeout_s=0.01)
    assert result["min_call_ok"] is False
    assert result["error"] == ["TimeoutError"]


def test_restart_without_minimal_call_does_not_restart(monkeypatch):
    monkeypatch.setattr(active.subprocess, "run", lambda *a, **kw: pytest.fail("restart called"))
    cfg = {"status_url": "http://localhost/status", "app_account": "app",
           "checks": [{"id": "target", "kind": "dbus_service", "safe_read_only": True}],
           "active": [{"kind": "restart", "unit": "target.service", "check_id": "target"}]}
    result = run_active(cfg, True, lambda _: '{"running": false}')[0]
    assert result["recovery_failed"] is True
    assert result["recovery_ms"] is None
    assert "minimal call" in result["error"]


@pytest.mark.parametrize("eventually_recovers", [False, True])
def test_restart_requires_target_call(monkeypatch, eventually_recovers):
    monkeypatch.setattr(active.subprocess, "run", lambda *a, **kw: None)
    ticks = iter(range(100))
    monkeypatch.setattr(active.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(active.time, "sleep", lambda _: None)
    calls = []
    def probe(c, app_account, **kwargs):
        calls.append(c)
        return {"min_call_ok": eventually_recovers and len(calls) >= 2,
                "call_attempted": True, "error": ["target unavailable"]}
    monkeypatch.setattr(core, "run_check", probe)
    target = {"id": "target", "kind": "dbus_method", "target": "org.example.Target",
              "safe_read_only": True, "call": {"member": "Ping"}}
    cfg = {"status_url": "http://localhost/status", "app_account": "app", "checks": [target],
           "active": [{"kind": "restart", "unit": "target.service", "check_id": "target",
                       "recovery_timeout_s": 5, "reconnect_status_url": "http://localhost/status"}]}
    result = run_active(cfg, True, lambda _: '{"running": false}')[0]
    assert len(calls) >= 2
    assert all(c is target for c in calls)
    assert result["ok"] is eventually_recovers
    assert result["recovery_failed"] is (not eventually_recovers)
    if eventually_recovers:
        assert result["recovery_ms"] is not None
    else:
        assert result["recovery_ms"] is None
        assert "target unavailable" in result["error"]


@pytest.mark.parametrize("effective_uid", [0, 1001])
def test_account_uses_kernel_identity(monkeypatch, check, effective_uid):
    monkeypatch.setattr(core.os, "geteuid", lambda: effective_uid, raising=False)
    monkeypatch.setattr(core.os, "getuid", lambda: 1000, raising=False)
    monkeypatch.setitem(sys.modules, "pwd", SimpleNamespace(
        getpwuid=lambda uid: SimpleNamespace(pw_name={0: "root", 1000: "login", 1001: "service"}[uid])))
    for name in ("LOGNAME", "USER", "LNAME", "USERNAME"):
        monkeypatch.setenv(name, "app")
    who = core.account()
    assert who["name"] == ("root" if effective_uid == 0 else "service")
    assert who["effective_uid"] == effective_uid
    assert who["effective_name"] == who["name"]
    assert who["real_uid"] == 1000 and who["real_name"] == "login"
    assert who["root_only"] is (effective_uid == 0)
    result = core.run_check(check, "app", dbus_runner=lambda c, r: r.update(call_attempted=True, min_call_ok=True))
    assert result["app_permission"] is False


def test_windows_identity_never_claims_app_permission(monkeypatch, check):
    monkeypatch.delattr(core.os, "geteuid", raising=False)
    who = core.account()
    assert who["uid"] == "unsupported"
    result = core.run_check(check, who["name"], dbus_runner=lambda c, r: r.update(call_attempted=True, min_call_ok=True))
    assert result["app_permission"] is False


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
                                   error_name="org.freedesktop.DBus.Error.AccessDenied", body=body, signature="s")
    monkeypatch.setitem(sys.modules, "dbus_fast", SimpleNamespace(
        MessageFlag=MessageFlag, MessageType=MessageType, Message=SimpleNamespace,
        BusType=SimpleNamespace(SYSTEM=0, SESSION=1)))
    monkeypatch.setitem(sys.modules, "dbus_fast.aio", SimpleNamespace(MessageBus=lambda **kw: Bus()))
    check.update(path="/org/example/Private", call={"interface": "org.example.Private", "member": "GetStatus"})
    r = core.run_check(check, "app", {"name": "app", "uid": 1000, "root_only": False})
    assert r["introspect_ok"] is (not deny_intro)
    assert r["min_call_ok"] is (not deny_call)
    if not deny_call:
        assert r["reply_signature"] == "s"
    assert calls == ["NameHasOwner", "Introspect", "GetStatus", "disconnect"]
