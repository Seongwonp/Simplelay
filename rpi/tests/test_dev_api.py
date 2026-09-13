"""개발자 API (Phase 2) — 권한·세션 소유권·생명주기 통합 테스트.

이 파일이 못 박는 것 (mock 어댑터 기준):

- 꺼져 있으면 없다(404), 켜져도 토큰이 없으면 닫힌다(503)
- 토큰 없음·틀림·대입 시도는 거절되고, **거절은 어댑터에 닿지 않는다**
- 세션은 연 클라이언트만 쓰고 갱신한다 — 비밀값은 시작 응답에만 한 번
- stopping·fault·session_expired·execution_busy가 응답에서 구분된다
- 명령 길이·빈도 제한, 같은 request_id 재전송은 한 번만 실행
- 종료 중에는 세션을 열지 않는다
- 정지는 빈도 제한에 걸리지 않고, 개발자 토큰 없는 /stop도 세션을 멈춘다

검증하지 **않는** 것: 실물 어댑터, 네트워크 지연·재연결, 여러 워커 프로세스.
"""

import threading
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
import rpi.api.dev_router as dev_router
from rpi.main import app
from rpi.services.control_arbiter import ControlArbiter
from rpi.services.developer_session import (
    DeveloperSessionManager,
    MockMotionAdapter,
)

TOKEN = "dev-token-for-tests-0123456789"
_T0 = datetime(2026, 9, 24, 10, 0, tzinfo=timezone.utc)


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


class _Rig:
    """테스트 한 건의 서버 조립 — 시계·어댑터·중재자를 쥔 매니저를 끼운다."""

    def __init__(self, monkeypatch, adapter=None, calibrated=True) -> None:
        self.clock = _Clock()
        self.adapter = adapter if adapter is not None else MockMotionAdapter()
        self.arbiter = ControlArbiter()
        self.calibrated = calibrated
        self.manager = DeveloperSessionManager(
            adapter=self.adapter,
            clock=self.clock,
            arbiter=self.arbiter,
            is_calibrated=lambda _a: self.calibrated,
            known_appliance=lambda a: a == "microwave",
            known_button=lambda _a, b: b in {"BT-01", "BT-05"},
            monotonic=self.clock.mono,
        )
        self.api_state = dev_router.DevApiState(monotonic=self.clock.mono)
        monkeypatch.setattr(deps, "get_developer_session_manager", lambda: self.manager)
        monkeypatch.setattr(deps, "get_control_arbiter", lambda: self.arbiter)
        monkeypatch.setattr(dev_router, "get_dev_api_state", lambda: self.api_state)
        deps.get_service.cache_clear()  # 실행기가 같은 중재자를 잡게
        self.client = TestClient(app)

    def headers(self, token=TOKEN, secret=None) -> dict:
        h = {}
        if token is not None:
            h["X-Dev-Token"] = token
        if secret is not None:
            h["X-Dev-Session-Secret"] = secret
        return h

    def start(self, appliance="microwave"):
        res = self.client.post(
            "/dev/sessions",
            json={"appliance_id": appliance, "node_id": "node-1"},
            headers=self.headers(),
        )
        return res

    def open_session(self):
        res = self.start()
        assert res.status_code == 201, res.json()
        body = res.json()
        return body["session_id"], body["session_secret"]

    def command(self, session_id, secret, text, request_id=None, appliance="microwave"):
        payload = {"appliance_id": appliance, "text": text}
        if request_id is not None:
            payload["request_id"] = request_id
        return self.client.post(
            f"/dev/sessions/{session_id}/commands",
            json=payload,
            headers=self.headers(secret=secret),
        )


@pytest.fixture()
def rig(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
    monkeypatch.setenv(dev_router.DEV_TOKEN_ENV, TOKEN)
    deps.get_service.cache_clear()
    yield lambda **kw: _Rig(monkeypatch, **kw)
    deps.get_service.cache_clear()


def _code(res) -> str:
    return res.json()["detail"]["code"]


# ── 꺼짐·토큰 ─────────────────────────────────────────────────────────────


def test_every_dev_route_is_absent_when_dev_mode_is_off(monkeypatch) -> None:
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DEV_MODE", raising=False)
    client = TestClient(app)
    headers = {"X-Dev-Token": TOKEN}

    for method, path in [
        ("get", "/dev/state"),
        ("post", "/dev/sessions"),
        ("post", "/dev/stop"),
        ("get", "/dev/log"),
    ]:
        res = getattr(client, method)(path, headers=headers, **(
            {"json": {"appliance_id": "microwave", "node_id": "n"}} if method == "post" else {}
        ))
        assert res.status_code == 404, path
        assert _code(res) == "dev_mode_disabled"


def test_dev_mode_without_a_configured_token_fails_closed(rig, monkeypatch) -> None:
    r = rig()
    for configured in ("", "short-token"):
        monkeypatch.setenv(dev_router.DEV_TOKEN_ENV, configured)
        res = r.start()
        assert res.status_code == 503
        assert _code(res) == "dev_token_not_configured"
    assert r.arbiter.holder is None
    assert r.adapter.calls == []


def test_missing_or_wrong_dev_token_is_rejected_before_the_adapter(rig) -> None:
    r = rig()
    missing = r.client.post("/dev/stop")
    assert missing.status_code == 401
    assert _code(missing) == "dev_token_required"

    wrong = r.client.post("/dev/stop", headers=r.headers(token="x" * 30))
    assert wrong.status_code == 403
    assert _code(wrong) == "dev_token_invalid"
    # 정지조차 토큰 검사 뒤다 -- 토큰 없는 긴급 정지 경로는 일반 /stop이다.
    assert r.adapter.calls == []


def test_repeated_auth_failures_lock_out_even_the_right_token(rig) -> None:
    r = rig()
    for _ in range(dev_router.AUTH_FAILURE_LIMIT):
        assert r.client.get("/dev/state", headers=r.headers(token="bad")).status_code == 403

    locked = r.client.get("/dev/state", headers=r.headers())
    assert locked.status_code == 429
    assert _code(locked) == "auth_rate_limited"

    r.clock.advance(dev_router.AUTH_FAILURE_WINDOW_S + 1)
    assert r.client.get("/dev/state", headers=r.headers()).status_code == 200


def test_a_non_mock_manager_is_not_exposed(rig, monkeypatch) -> None:
    r = rig()
    monkeypatch.setattr(r.manager, "_adapter", MockMotionAdapter(is_mock=False))
    res = r.client.get("/dev/state", headers=r.headers())
    assert res.status_code == 503
    assert _code(res) == "real_adapter_not_allowed"


# ── 세션 시작·소유권 ───────────────────────────────────────────────────────


def test_start_returns_the_secret_once_and_state_never_leaks_it(rig) -> None:
    r = rig()
    res = r.start()
    assert res.status_code == 201
    body = res.json()
    secret = body["session_secret"]
    assert len(secret) >= 24
    assert body["state"]["phase"] == "active"
    assert body["state"]["mock"] is True
    assert body["state"]["session"]["appliance_id"] == "microwave"

    state = r.client.get("/dev/state", headers=r.headers())
    log = r.client.get("/dev/log", headers=r.headers())
    for other in (state, log):
        assert other.status_code == 200
        assert secret not in other.text
        assert "secret" not in other.text


def test_unknown_appliance_is_rejected_without_taking_control(rig) -> None:
    r = rig()
    res = r.start(appliance="ghost")
    assert res.status_code == 404
    assert _code(res) == "unknown_appliance"
    assert r.arbiter.holder is None


def test_second_session_and_busy_execution_are_distinguished(rig) -> None:
    r = rig()
    r.open_session()
    second = r.start()
    assert second.status_code == 409
    assert _code(second) == "session_conflict"

    r2 = rig()
    r2.arbiter.acquire(ControlArbiter.EXECUTION)
    busy = r2.start()
    assert busy.status_code == 409
    assert _code(busy) == "execution_busy"
    assert r2.client.get("/dev/state", headers=r2.headers()).json()["phase"] == "execution_busy"


def test_another_client_cannot_use_or_refresh_the_session(rig) -> None:
    r = rig()
    session_id, secret = r.open_session()

    no_secret = r.client.post(
        f"/dev/sessions/{session_id}/heartbeat", headers=r.headers()
    )
    assert no_secret.status_code == 401
    assert _code(no_secret) == "session_secret_required"

    for path, kwargs in [
        ("heartbeat", {}),
        ("commands", {"json": {"appliance_id": "microwave", "text": "home"}}),
        ("end", {}),
    ]:
        res = r.client.post(
            f"/dev/sessions/{session_id}/{path}",
            headers=r.headers(secret="someone-elses-secret-value"),
            **kwargs,
        )
        assert res.status_code == 403, path
        assert _code(res) == "not_session_owner"

    assert r.adapter.calls == []
    assert r.manager.session is not None  # 남의 시도가 세션을 흔들지 않는다
    assert r.command(session_id, secret, "home").status_code == 200


def test_a_stale_session_id_gets_session_expired_not_forbidden(rig) -> None:
    r = rig()
    old_id, old_secret = r.open_session()
    assert r.client.post(
        f"/dev/sessions/{old_id}/end", headers=r.headers(secret=old_secret)
    ).json()["confirmed"] is True
    r.open_session()

    res = r.command(old_id, old_secret, "home")
    assert res.status_code == 410
    assert _code(res) == "session_expired"
    assert r.adapter.motion_calls() == []


# ── heartbeat·만료 ─────────────────────────────────────────────────────────


def test_missing_heartbeat_expires_the_session_and_blocks_commands(rig) -> None:
    r = rig()
    session_id, secret = r.open_session()

    r.clock.advance(3)  # TTL 2초 초과, heartbeat 없음
    res = r.command(session_id, secret, "jog x + 1")

    assert res.status_code == 410
    assert _code(res) == "session_expired"
    assert r.adapter.motion_calls() == []
    assert r.adapter.stops() == ["heartbeat_timeout"]
    assert r.client.get("/dev/state", headers=r.headers()).json()["phase"] == "idle"


def test_heartbeat_keeps_the_session_alive(rig) -> None:
    r = rig()
    session_id, secret = r.open_session()
    for _ in range(4):
        r.clock.advance(1.5)
        hb = r.client.post(
            f"/dev/sessions/{session_id}/heartbeat", headers=r.headers(secret=secret)
        )
        assert hb.status_code == 200
        assert hb.json()["phase"] == "active"
    assert r.command(session_id, secret, "home").status_code == 200


# ── 명령 제한 ─────────────────────────────────────────────────────────────


def test_invalid_long_or_malformed_commands_never_reach_the_adapter(rig) -> None:
    r = rig()
    session_id, secret = r.open_session()

    invalid = r.command(session_id, secret, "status; rm -rf /")
    assert invalid.status_code == 422
    assert _code(invalid) == "invalid_command"

    too_long = r.command(session_id, secret, "jog x + 1" + " " * dev_router.MAX_COMMAND_LEN)
    assert too_long.status_code == 422

    extra = r.client.post(
        f"/dev/sessions/{session_id}/commands",
        json={"appliance_id": "microwave", "text": "home", "raw": "G1 X10"},
        headers=r.headers(secret=secret),
    )
    assert extra.status_code == 422

    wrong_target = r.command(session_id, secret, "home", appliance="induction")
    assert wrong_target.status_code == 422
    assert _code(wrong_target) == "wrong_target"

    unknown_button = r.command(session_id, secret, "press BT-99")
    assert _code(unknown_button) == "unknown_button"

    assert r.adapter.motion_calls() == []


def test_uncalibrated_press_is_rejected_with_its_own_code(rig) -> None:
    r = rig(calibrated=False)
    session_id, secret = r.open_session()
    res = r.command(session_id, secret, "press BT-01")
    assert res.status_code == 422
    assert _code(res) == "not_calibrated"
    assert r.adapter.motion_calls() == []


def test_a_resent_request_id_is_executed_only_once(rig) -> None:
    r = rig()
    session_id, secret = r.open_session()

    first = r.command(session_id, secret, "press BT-01", request_id="req-1")
    again = r.command(session_id, secret, "press BT-01", request_id="req-1")

    assert first.status_code == 200
    assert again.status_code == 409
    assert _code(again) == "duplicate_request"
    assert r.adapter.motion_calls() == [("press", "BT-01")]


def test_command_rate_limit_caps_adapter_calls_but_never_blocks_stop(rig) -> None:
    r = rig()
    session_id, secret = r.open_session()
    limit = dev_router.COMMAND_LIMIT_PER_S

    statuses = [r.command(session_id, secret, "jog x + 1").status_code for _ in range(limit + 5)]

    assert statuses[:limit] == [200] * limit
    assert set(statuses[limit:]) == {429}
    assert len(r.adapter.motion_calls()) == limit

    stop = r.command(session_id, secret, "stop")  # 한도에 걸린 상태에서도
    assert stop.status_code == 200
    assert r.adapter.stops() == ["user_stop"]


def test_session_start_rate_limit(rig) -> None:
    r = rig()
    for _ in range(dev_router.START_LIMIT):
        sid, secret = r.open_session()
        r.client.post(f"/dev/sessions/{sid}/end", headers=r.headers(secret=secret))
    res = r.start()
    assert res.status_code == 429
    assert _code(res) == "rate_limited"


# ── 생명주기: 종료·stopping·fault ─────────────────────────────────────────


def test_no_session_starts_while_the_server_is_shutting_down(rig) -> None:
    r = rig()
    r.manager.close()
    res = r.start()
    assert res.status_code == 503
    assert _code(res) == "shutting_down"
    assert r.client.get("/dev/state", headers=r.headers()).json()["shutting_down"] is True


class _GatedPress(MockMotionAdapter):
    def __init__(self) -> None:
        super().__init__()
        self.arrived = threading.Event()
        self.gate = threading.Event()

    def press(self, button_id: str) -> None:
        self.arrived.set()
        assert self.gate.wait(timeout=5)
        super().press(button_id)


def test_stopping_is_reported_and_blocks_both_sides_until_settled(rig) -> None:
    adapter = _GatedPress()
    r = rig(adapter=adapter)
    session_id, secret = r.open_session()

    worker = threading.Thread(
        target=r.command, args=(session_id, secret, "press BT-01")
    )
    worker.start()
    assert adapter.arrived.wait(timeout=5)

    stop = r.client.post("/dev/stop", headers=r.headers())
    assert stop.status_code == 200
    assert stop.json()["confirmed"] is True
    assert stop.json()["state"]["phase"] == "stopping"

    blocked_dev = r.start()
    assert blocked_dev.status_code == 409
    assert _code(blocked_dev) == "stopping"
    assert r.client.post("/execute-buttons", json={"buttons": ["시작"]}).status_code == 409

    adapter.gate.set()
    worker.join(timeout=5)
    assert r.client.get("/dev/state", headers=r.headers()).json()["phase"] == "idle"


class _BrokenStop(MockMotionAdapter):
    def __init__(self) -> None:
        super().__init__()
        self.broken = True

    def stop(self, reason: str) -> None:
        super().stop(reason)
        if self.broken:
            raise RuntimeError("link down")


def test_unconfirmed_stop_is_not_reported_as_success_and_locks(rig) -> None:
    adapter = _BrokenStop()
    r = rig(adapter=adapter)
    r.open_session()

    stop = r.client.post("/dev/stop", headers=r.headers())
    assert stop.status_code == 200
    assert stop.json()["confirmed"] is False
    assert stop.json()["state"]["phase"] == "fault"

    locked = r.start()
    assert locked.status_code == 423
    assert _code(locked) == "fault"
    assert r.client.post("/execute-buttons", json={"buttons": ["시작"]}).status_code == 409

    adapter.broken = False  # 복구 절차: 정지가 실제로 확인되면 풀린다
    recovered = r.client.post("/dev/stop", headers=r.headers())
    assert recovered.json()["confirmed"] is True
    assert recovered.json()["state"]["phase"] == "idle"
    assert r.start().status_code == 201


def test_the_plain_stop_endpoint_stops_the_session_without_a_dev_token(rig) -> None:
    r = rig()
    r.open_session()

    res = r.client.post("/stop")  # 개발자 토큰 없음

    assert res.status_code == 200
    assert r.manager.session is None
    assert "emergency_stop" in r.adapter.stops()
