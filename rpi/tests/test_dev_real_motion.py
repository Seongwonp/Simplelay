"""개발자 모드 실물 경로(RPi5 쪽) — 2026-10-10, **실물 미검증**.

``SIMPLELAY_DEV_MODE``와 ``SIMPLELAY_DEV_REAL_MOTION`` 둘 다 켜졌을 때만 개발자 API가 RPi4 링크
(``dev_motion`` 프레임)로 간다. RPi4는 가짜 링크(아래 ``FakeDevLink``)다 — ActClientController의
``dev_motion_link()``·``dev_motion()``·``request_drive_stop()`` 모양만 흉내 낸다. 양쪽 실제 구현을 맞물린
시험은 rpi4/tests/test_dev_motion_link.py.

못 박는 것:
- env가 하나라도 없으면 지금과 똑같이 모의다(실물 어댑터를 만들지 않는다)
- RPi4가 모의 모션이거나(act_info.motion != serial), 개발자 조작을 모르는 옛 판이거나(dev_motion_protocol 없음),
  링크가 끊겼거나, 비상정지가 걸렸거나 모르면 RPi4에 아무것도 보내지 않고 거절한다
- 한 번 조그 상한(기본 1 mm, 설정해도 5 mm 넘지 않음)을 넘으면 보내지 않고 거절한다
- 정지(/dev/stop·일반 /stop·세션 끝·heartbeat 끊김)는 RPi4로 간다. 옛 RPi4면 abort(drive)로라도 간다
- 움직인 뒤 실패(알람·기한 초과)는 정지를 보내고, 움직이기 전 거절은 정지 없이 그 이유로 답한다
- 화면이 '실제 장치'/'모의'를 가를 수 있게 상태 응답에 motion_target을 싣는다
"""

from __future__ import annotations

import threading
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
import rpi.api.dev_router as dev_router
from rpi.main import app
from rpi.services.act_client import ActLinkError
from rpi.services.control_arbiter import ControlArbiter
from rpi.services.dev_real_motion import (
    DEV_REAL_MAX_STEP_ENV,
    DEV_REAL_MOTION_ENV,
    REAL_MAX_STEP_CEILING_MM,
    ActDevMotionAdapter,
    real_max_step_from_env,
)
from rpi.services.developer_session import DeveloperSessionManager

TOKEN = "dev-token-for-tests-0123456789"
_T0 = datetime(2026, 10, 10, 10, 0, tzinfo=timezone.utc)


class _Clock:
    def __init__(self) -> None:
        self.t = _T0
        self.mono_s = 1000.0

    def now(self) -> datetime:
        return self.t

    def mono(self) -> float:
        return self.mono_s

    def advance(self, seconds: float) -> None:
        self.t += timedelta(seconds=seconds)
        self.mono_s += seconds


class FakeDevLink:
    """ActClientController의 개발자 조작 면만 흉내 낸 RPi4."""

    def __init__(self) -> None:
        self.link_up = True
        self.act_info: dict = {"motion": "serial", "execute_protocol": 2, "dev_motion_protocol": 1}
        self.estop_latched: bool | None = False
        self.sent: list[tuple[str, dict]] = []
        self.drive_stops = 0
        #: op → 돌려줄 답(없으면 ok). 호출 가능하면 불러서 쓴다.
        self.replies: dict[str, object] = {}
        self.fail_with: Exception | None = None

    def dev_motion_link(self) -> dict:
        return {"link_up": self.link_up, "act_info": dict(self.act_info), "estop_latched": self.estop_latched}

    def dev_motion(self, op: str, timeout_s: float, **fields) -> dict:
        self.sent.append((op, dict(fields)))
        if self.fail_with is not None and op != "stop":
            raise self.fail_with
        reply = self.replies.get(op)
        if callable(reply):
            reply = reply(fields)
        if reply is None:
            reply = {"ok": True, "op": op, "homed": True, "x_mm": 10.0, "y_mm": 20.0}
        return dict(reply)

    def request_drive_stop(self) -> None:
        self.drive_stops += 1

    def ops(self) -> list[str]:
        return [op for op, _ in self.sent]


class _Rig:
    def __init__(self, monkeypatch, *, max_step_mm: float = 1.0) -> None:
        self.clock = _Clock()
        self.link = FakeDevLink()
        self.adapter = ActDevMotionAdapter(lambda: self.link, max_step_mm=max_step_mm)
        self.arbiter = ControlArbiter()
        self.manager = DeveloperSessionManager(
            adapter=self.adapter,
            clock=self.clock,
            arbiter=self.arbiter,
            is_calibrated=lambda _a: True,
            known_appliance=lambda a: a == "microwave",
            known_button=lambda _a, b: b in {"BT-01", "BT-05"},
            monotonic=self.clock.mono,
            allow_real_adapter=True,
        )
        self.api_state = dev_router.DevApiState(monotonic=self.clock.mono)
        monkeypatch.setattr(deps, "get_developer_session_manager", lambda: self.manager)
        monkeypatch.setattr(deps, "get_control_arbiter", lambda: self.arbiter)
        monkeypatch.setattr(dev_router, "get_dev_api_state", lambda: self.api_state)
        deps.get_service.cache_clear()
        self.client = TestClient(app)

    def headers(self, secret=None) -> dict:
        h = {"X-Dev-Token": TOKEN}
        if secret is not None:
            h["X-Dev-Session-Secret"] = secret
        return h

    def open_session(self):
        res = self.client.post("/dev/sessions", json={"appliance_id": "microwave", "node_id": "phone"},
                               headers=self.headers())
        assert res.status_code == 201, res.json()
        body = res.json()
        return body["session_id"], body["session_secret"]

    def command(self, sid, secret, text, request_id=None):
        payload = {"appliance_id": "microwave", "text": text}
        if request_id is not None:
            payload["request_id"] = request_id
        return self.client.post(f"/dev/sessions/{sid}/commands", json=payload, headers=self.headers(secret))


@pytest.fixture()
def rig(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
    monkeypatch.setenv(DEV_REAL_MOTION_ENV, "1")
    monkeypatch.setenv(dev_router.DEV_TOKEN_ENV, TOKEN)
    deps.get_service.cache_clear()
    yield lambda **kw: _Rig(monkeypatch, **kw)
    deps.get_service.cache_clear()


def _code(res) -> str:
    return res.json()["detail"]["code"]


# ── 켜는 조건 ───────────────────────────────────────────────────────────────

_DEPS = ("get_service", "get_control_arbiter", "get_developer_session_manager",
         "get_appliance_registry", "get_readiness_registry")


@pytest.fixture()
def fresh_deps(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    for name in _DEPS:
        getattr(deps, name).cache_clear()
    yield
    manager = deps.get_developer_session_manager() if deps.developer_mode_enabled() else None
    if manager is not None:
        manager.close()
    for name in _DEPS:
        getattr(deps, name).cache_clear()


def test_real_adapter_is_not_built_without_the_real_motion_env(fresh_deps, monkeypatch) -> None:
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
    monkeypatch.delenv(DEV_REAL_MOTION_ENV, raising=False)
    assert deps.dev_real_motion_enabled() is False
    manager = deps.get_developer_session_manager()
    assert manager is not None and manager.is_mock is True


def test_real_motion_env_alone_does_not_open_the_dev_api(fresh_deps, monkeypatch) -> None:
    monkeypatch.delenv("SIMPLELAY_DEV_MODE", raising=False)
    monkeypatch.setenv(DEV_REAL_MOTION_ENV, "1")
    assert deps.dev_real_motion_enabled() is False
    assert deps.get_developer_session_manager() is None
    res = TestClient(app).get("/dev/state", headers={"X-Dev-Token": TOKEN})
    assert res.status_code == 404


def test_both_envs_build_the_real_adapter(fresh_deps, monkeypatch) -> None:
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
    monkeypatch.setenv(DEV_REAL_MOTION_ENV, "1")
    monkeypatch.setenv(dev_router.DEV_TOKEN_ENV, TOKEN)
    assert deps.dev_real_motion_enabled() is True
    manager = deps.get_developer_session_manager()
    assert manager.is_mock is False
    body = TestClient(app).get("/dev/state", headers={"X-Dev-Token": TOKEN}).json()
    assert body["mock"] is False and body["motion_target"] == "real"
    # 기본 실행 경로(ACT_MODE 미설정)에는 RPi4 링크가 없다 — 실물 준비 안 됨으로 보인다.
    assert body["real_motion_ready"] is False
    assert body["real_motion_reason"]


def test_a_non_mock_manager_without_the_env_is_still_refused(rig, monkeypatch) -> None:
    r = rig()
    monkeypatch.delenv(DEV_REAL_MOTION_ENV, raising=False)
    res = r.client.get("/dev/state", headers=r.headers())
    assert res.status_code == 503 and _code(res) == "real_adapter_not_allowed"


def test_state_reports_the_real_target_and_its_readiness(rig) -> None:
    r = rig()
    body = r.client.get("/dev/state", headers=r.headers()).json()
    assert body["mock"] is False
    assert body["motion_target"] == "real"
    assert body["real_motion_ready"] is True and body["real_motion_reason"] is None
    assert body["max_jog_mm"] == 1.0
    r.link.act_info["motion"] = "mock"
    body = r.client.get("/dev/state", headers=r.headers()).json()
    assert body["real_motion_ready"] is False and "모의" in body["real_motion_reason"]


def test_max_step_env_is_capped(monkeypatch) -> None:
    monkeypatch.delenv(DEV_REAL_MAX_STEP_ENV, raising=False)
    assert real_max_step_from_env() == 1.0
    monkeypatch.setenv(DEV_REAL_MAX_STEP_ENV, "50")
    assert real_max_step_from_env() == REAL_MAX_STEP_CEILING_MM
    assert REAL_MAX_STEP_CEILING_MM <= 10.0
    monkeypatch.setenv(DEV_REAL_MAX_STEP_ENV, "0")
    with pytest.raises(RuntimeError, match=DEV_REAL_MAX_STEP_ENV):
        real_max_step_from_env()


# ── 거절(아무것도 보내지 않는다) ─────────────────────────────────────────────


def test_jog_is_refused_when_rpi4_motion_is_mock(rig) -> None:
    r = rig()
    r.link.act_info["motion"] = "mock"
    sid, secret = r.open_session()
    res = r.command(sid, secret, "jog x + 1")
    assert res.status_code == 409 and _code(res) == "motion_mock"
    assert r.link.ops() == []
    # 움직이기 전 거절은 세션을 닫지 않는다.
    assert r.client.get("/dev/state", headers=r.headers()).json()["phase"] == "active"


def test_old_rpi4_without_dev_support_is_refused(rig) -> None:
    r = rig()
    del r.link.act_info["dev_motion_protocol"]
    sid, secret = r.open_session()
    res = r.command(sid, secret, "home")
    assert res.status_code == 409 and _code(res) == "dev_protocol_unsupported"
    assert r.link.ops() == []


def test_jog_step_over_the_cap_is_refused(rig) -> None:
    r = rig(max_step_mm=1.0)
    sid, secret = r.open_session()
    res = r.command(sid, secret, "jog x + 2")
    assert res.status_code == 422 and _code(res) == "step_too_large"
    assert r.link.ops() == []
    ok = r.command(sid, secret, "jog x + 1")
    assert ok.status_code == 200
    assert r.link.sent == [("jog", {"axis": "x", "delta_mm": 1.0})]


def test_jog_is_refused_while_the_estop_is_latched_or_unknown(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    r.link.estop_latched = True
    res = r.command(sid, secret, "jog y - 1")
    assert res.status_code == 423 and _code(res) == "estop_latched"
    r.link.estop_latched = None
    res = r.command(sid, secret, "jog y - 1")
    assert res.status_code == 409 and _code(res) == "estop_unknown"
    assert r.link.ops() == []


def test_jog_is_refused_while_the_link_is_down(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    r.link.link_up = False
    res = r.command(sid, secret, "jog x + 1")
    assert res.status_code == 503 and _code(res) == "link_down"
    assert r.link.ops() == []


def test_session_is_refused_while_a_normal_execution_holds_control(rig) -> None:
    r = rig()
    r.arbiter.acquire(ControlArbiter.EXECUTION)
    res = r.client.post("/dev/sessions", json={"appliance_id": "microwave", "node_id": "phone"},
                        headers=r.headers())
    assert res.status_code == 409 and _code(res) == "execution_busy"
    assert r.link.ops() == []


def test_rpi4_refusals_are_surfaced_with_their_reason(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    r.link.replies["jog"] = {"ok": False, "op": "jog", "reason": "not_homed", "moved": False,
                             "detail": "원점 복귀가 확인되지 않았어요"}
    res = r.command(sid, secret, "jog x + 1")
    assert res.status_code == 409 and _code(res) == "not_homed"
    r.link.replies["jog"] = {"ok": False, "op": "jog", "reason": "execution_busy", "moved": False,
                             "detail": "일반 실행 중이에요"}
    res = r.command(sid, secret, "jog x + 1")
    assert res.status_code == 409 and _code(res) == "execution_busy"
    # 움직이기 전 거절에는 정지를 따로 보내지 않는다.
    assert "stop" not in r.link.ops()


# ── 정지 ────────────────────────────────────────────────────────────────────


def test_dev_stop_is_forwarded_to_rpi4(rig) -> None:
    r = rig()
    r.open_session()
    res = r.client.post("/dev/stop", headers=r.headers())
    # 2026-10-13: 단계 없는 답(개발자 조작 규약 1 RPi4)은 '보냄'까지다 — 확인으로 올리지 않는다.
    assert res.status_code == 200
    assert r.link.ops()[-1] == "stop"


# ── 정지 확인 단계(2026-10-13) ───────────────────────────────────────────────


@pytest.mark.parametrize(("level", "ack_ms", "phrase"), [
    ("mcu_ack", 12, "모션 보드가 정지를 확인했어요 (12 ms)"),
    ("verified", 9, "멈춘 것을 확인했어요"),
])
def test_dev_stop_is_confirmed_only_from_the_mcu_ack_up(rig, level, ack_ms, phrase) -> None:
    r = rig()
    r.link.act_info["dev_motion_protocol"] = 2
    r.link.replies["stop"] = {"ok": True, "op": "stop", "stop_level": level, "ack_ms": ack_ms}
    r.open_session()
    body = r.client.post("/dev/stop", headers=r.headers()).json()
    assert body["confirmed"] is True
    assert body["stop_level"] == level and body["stop_ack_ms"] == ack_ms
    assert phrase in body["message"]


@pytest.mark.parametrize("reply", [
    {"ok": True, "op": "stop"},                                          # 옛 RPi4(규약 1) — 단계 없음
    {"ok": True, "op": "stop", "stop_level": "sent", "ack_ms": None},     # MCU가 답하지 않음
    {"ok": True, "op": "stop", "stop_level": "stopped_for_sure"},         # 모르는 값은 낮춰 읽는다
], ids=["old_rpi4", "sent", "unknown_level"])
def test_dev_stop_that_was_only_sent_is_not_reported_as_confirmed(rig, reply) -> None:
    r = rig()
    r.link.replies["stop"] = reply
    r.open_session()
    body = r.client.post("/dev/stop", headers=r.headers()).json()
    assert body["confirmed"] is False
    assert body["stop_level"] == "sent" and body["stop_ack_ms"] is None
    assert "정지 명령을 보냈어요" in body["message"] and "확인했" not in body["message"]
    # 보낸 것은 확실하다 — 잠그지는 않는다(잠금은 RPi4에 닿지 못했을 때).
    assert body["state"]["phase"] == "idle"


def test_dev_stop_on_an_old_rpi4_drive_abort_is_only_sent(rig) -> None:
    r = rig()
    del r.link.act_info["dev_motion_protocol"]
    r.open_session()
    body = r.client.post("/dev/stop", headers=r.headers()).json()
    assert r.link.drive_stops == 1
    assert body["confirmed"] is False and body["stop_level"] == "sent"


def test_session_end_says_what_the_stop_reached(rig) -> None:
    r = rig()
    r.link.replies["stop"] = {"ok": True, "op": "stop", "stop_level": "mcu_ack", "ack_ms": 30}
    sid, secret = r.open_session()
    body = r.client.post(f"/dev/sessions/{sid}/end", headers=r.headers(secret)).json()
    assert body["confirmed"] is True and body["stop_level"] == "mcu_ack"
    assert "(30 ms)" in body["message"]

    r.link.replies["stop"] = {"ok": True, "op": "stop"}
    sid, secret = r.open_session()
    body = r.client.post(f"/dev/sessions/{sid}/end", headers=r.headers(secret)).json()
    assert body["confirmed"] is False and body["stop_level"] == "sent"
    assert "정지 명령을 보냈어요" in body["message"]


def test_link_down_stop_has_no_level(rig) -> None:
    r = rig()
    r.open_session()
    r.link.link_up = False
    body = r.client.post("/dev/stop", headers=r.headers()).json()
    assert body["confirmed"] is False and body["stop_level"] is None


def test_global_stop_also_reaches_rpi4(rig) -> None:
    r = rig()
    r.open_session()
    res = r.client.post("/stop")
    assert res.status_code == 200
    assert "stop" in r.link.ops()
    assert r.client.get("/dev/state", headers=r.headers()).json()["phase"] == "idle"


def test_stop_command_in_session_is_forwarded(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    res = r.command(sid, secret, "stop")
    assert res.status_code == 200
    assert r.link.ops() == ["stop"]


def test_heartbeat_loss_sends_a_stop_to_rpi4(rig) -> None:
    r = rig()
    r.open_session()
    r.clock.advance(r.manager.heartbeat_ttl_s + 0.1)
    assert r.manager.tick() == "heartbeat_timeout"
    assert r.link.ops() == ["stop"]
    assert r.client.get("/dev/state", headers=r.headers()).json()["phase"] == "idle"


def test_stop_on_an_old_rpi4_falls_back_to_a_drive_abort(rig) -> None:
    r = rig()
    del r.link.act_info["dev_motion_protocol"]
    r.open_session()
    res = r.client.post("/dev/stop", headers=r.headers())
    assert res.status_code == 200
    assert r.link.drive_stops == 1
    assert "stop" not in r.link.ops()


def test_stop_unconfirmed_when_the_link_is_down_locks_the_device(rig) -> None:
    r = rig()
    r.open_session()
    r.link.link_up = False
    res = r.client.post("/dev/stop", headers=r.headers())
    assert res.json()["confirmed"] is False
    assert res.json()["state"]["phase"] == "fault"


# ── 움직인 뒤 실패 ──────────────────────────────────────────────────────────


def test_failure_after_moving_sends_a_stop_and_keeps_the_detail(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    r.link.replies["jog"] = {"ok": False, "op": "jog", "reason": "motion_alarm", "moved": None,
                             "detail": "MCU 알람: stall"}
    res = r.command(sid, secret, "jog x + 1")
    assert res.status_code == 502 and _code(res) == "command_error"
    assert "stall" in res.json()["detail"]["message"]
    assert r.link.ops() == ["jog", "stop"]


def test_link_error_mid_command_sends_a_stop(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    r.link.fail_with = ActLinkError("RPi4 연결이 끊겼어요 (EOF)")
    res = r.command(sid, secret, "home")
    assert res.status_code == 502 and _code(res) == "command_error"
    assert r.link.ops() == ["home", "stop"]


def test_each_jog_is_one_request_with_one_result(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    assert r.command(sid, secret, "jog x + 1", request_id="j1").status_code == 200
    dup = r.command(sid, secret, "jog x + 1", request_id="j1")
    assert dup.status_code == 409 and _code(dup) == "duplicate_request"
    assert r.link.ops() == ["jog"]


def test_press_and_sensor_read_go_to_rpi4(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    assert r.command(sid, secret, "press BT-05").status_code == 200
    assert r.link.sent[-1] == ("press", {"label": "BT-05"})
    res = r.command(sid, secret, "sensor read")
    assert res.status_code == 200
    assert res.json()["sensor"] == {"x_mm": 10.0, "y_mm": 20.0, "homed": 1.0}


def test_stop_during_a_slow_jog_marks_the_late_result_stale(rig) -> None:
    r = rig()
    sid, secret = r.open_session()
    gate = threading.Event()

    def slow(fields):
        gate.wait(5)
        return {"ok": True, "op": "jog", "homed": True, "x_mm": 1.0, "y_mm": 0.0}

    r.link.replies["jog"] = slow
    out: dict = {}
    worker = threading.Thread(target=lambda: out.setdefault("res", r.command(sid, secret, "jog x + 1")))
    worker.start()
    for _ in range(200):
        if r.link.ops() == ["jog"]:
            break
        threading.Event().wait(0.01)
    r.manager.emergency_stop("emergency_stop")
    gate.set()
    worker.join(5)
    assert out["res"].status_code == 409 and _code(out["res"]) == "stop_race"
    assert r.link.ops() == ["jog", "stop", "stop"]


def test_link_down_for_an_auth_failure_says_so_in_the_reason() -> None:
    """링크 인증(2026-10-12): 키가 맞지 않아 내려간 링크는 /dev/state real_motion_reason에 그 이유를 보인다."""
    from rpi.services.act_client import ActClient

    link = FakeDevLink()
    link.link_up = False
    snap = link.dev_motion_link()
    link.dev_motion_link = lambda: {**snap, "link_reason": ActClient.AUTH_FAILED_REASON}  # type: ignore[method-assign]
    code, message = ActDevMotionAdapter(lambda: link).availability()
    assert code == "link_down"
    assert "인증 실패" in message and "SIMPLELAY_LINK_KEY" in message
