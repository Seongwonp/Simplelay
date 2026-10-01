import json
from datetime import datetime, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.api.dev_router import dev_router, require_dev_access
from rpi.services.probe_history import load_last_probe
from rpi.services.readiness import ApplianceReadiness, ReadinessCheck, ReadinessRegistry


@pytest.mark.parametrize("stamp", ["2000-01-01T00:00:00+00:00", datetime.now(timezone.utc).isoformat()])
def test_history_success_never_enables_live_gate(tmp_path, monkeypatch, stamp):
    monkeypatch.setenv("SIMPLELAY_PROBE_HISTORY_DIR", str(tmp_path))
    (tmp_path / "20261001.json").write_text(json.dumps({"timestamp_utc": stamp, "checks": [
        {"kind": "dbus_method", "id": "PRIVATE", "target": "PRIVATE", "error": "PRIVATE",
         "present": True, "introspect_ok": True, "app_permission": True, "min_call_ok": True}]}), encoding="utf-8")
    registry = ReadinessRegistry()
    registry.report(ApplianceReadiness.of("old", {c: True for c in ReadinessCheck}, checked_at=datetime(2000, 1, 1, tzinfo=timezone.utc)))
    registry.report(ApplianceReadiness.of("failed", {c: False for c in ReadinessCheck}, checked_at=datetime.now(timezone.utc)))
    before = [registry.get(k) for k in ("unknown", "old", "failed")]
    app = FastAPI()
    app.include_router(dev_router)
    app.dependency_overrides[require_dev_access] = lambda: object()
    response = TestClient(app).get("/dev/diagnostics/board-probe")
    assert response.status_code == 200
    assert response.json()["historical_only"] is True
    assert "이전 점검 기록" in response.json()["label"]
    assert "PRIVATE" not in response.text
    after = [registry.get(k) for k in ("unknown", "old", "failed")]
    assert before == after
    assert all(not r.can_execute for r in after)
    from rpi.tests.test_appliance_readiness import _setup
    from rpi.api.service import ApplianceNotReadyError
    service, node, _ = _setup(readiness=registry)
    with pytest.raises(ApplianceNotReadyError):
        service.execute_buttons(("전원",), appliance_id="fan")
    assert node.calls == []


def test_opt_in_and_corrupt_latest(tmp_path, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_PROBE_HISTORY_DIR", raising=False)
    assert load_last_probe() is None
    monkeypatch.setenv("SIMPLELAY_PROBE_HISTORY_DIR", str(tmp_path))
    assert load_last_probe() is None
    (tmp_path / "2.json").write_text("broken")
    with pytest.raises(ValueError):
        load_last_probe()


def test_diagnostic_keeps_dev_auth(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_DEV_MODE", raising=False)
    app = FastAPI()
    app.include_router(dev_router)
    assert TestClient(app).get("/dev/diagnostics/board-probe").status_code == 404
