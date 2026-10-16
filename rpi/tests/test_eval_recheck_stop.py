"""HIGH 재확인(2026-10-14) 수리 — 설정 저장이 DB에서 멈춘 동안에도 정지가 막히지 않는다 · 저장 실패를 성공으로 숨기지 않는다.

H-R1: 조용한 시간 저장이 ``QuietHours`` 잠금을 잡은 채 DB를 기다리면, 자동 실행의 시작 게이트(서비스 잠금 안)와
      전송권 확인(ThinQ 실행기 잠금 안)이 그 잠금을 기다리고, 정지가 서비스 잠금·실행기 잠금에서 막혔다.
H-R2: ``POST``·``DELETE /dnd``(async 라우터)가 동기 DB 저장을 이벤트 루프에서 직접 불러, 단일 Uvicorn 루프에서
      저장이 멈춘 동안 ``/stop`` 요청 자체가 처리되지 않았다.
M-R1: 잠시 쉬기 저장이 실패해도 200 성공만 돌려줬다(재시작 뒤 사라짐).

계측은 API 응답이 아니라 실제 로컬 컨트롤러 ``request_stop`` 진입(가능하면 서명된 RPi4 링크의 abort 송신)이다.
**실제 ThinQ 클라우드·실가전·보드는 쓰지 않는다.** DB 대기·실패는 시험이 ``save_setting``에 건 문·예외로 흉내 낸다.
정지 지연 값은 개발 PC 기준이며 보드·모터 정지 시간이 아니다.
"""

from __future__ import annotations

import asyncio
import inspect
import socket
import sqlite3
import threading
import time
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_cook_done_card import _env as _mock_env
from rpi.tests.test_cook_done_card import _inject, _reset

#: 정지 호출 지연 상한(초) — 설정 DB 저장 대기와 무관하게 이 안에 로컬 ``request_stop``이 불려야 한다(H-N2와 같은 값).
STOP_CALL_BOUND_S = 0.5
#: ``/stop`` HTTP 응답 상한(초) — 저장이 멈춰 있어도 이 안에 돌아와야 한다.
STOP_RESPONSE_BOUND_S = 1.5
KEY = "recheck-local-test-key"


def _now_window() -> dict:
    now = datetime.now().astimezone()
    return {"enabled": True, "start": (now - timedelta(hours=2)).strftime("%H:%M"),
            "end": (now + timedelta(hours=2)).strftime("%H:%M")}


def _start(threads: list, fn) -> threading.Thread:
    thread = threading.Thread(target=fn, daemon=True)
    thread.start()
    threads.append(thread)
    return thread


def _stuck_setting(monkeypatch, db, key: str, release: threading.Event) -> threading.Event:
    """``key`` 설정의 DB 저장을 ``release``까지 붙잡는다(실제 ``save_setting`` 경계). 놓이면 실제로 쓴다."""
    entered = threading.Event()
    original = db.save_setting

    def stuck(k, value):
        if k == key:
            entered.set()
            assert release.wait(20)
        return original(k, value)

    monkeypatch.setattr(db, "save_setting", stuck)
    return entered


def _failing_setting(monkeypatch, db, key: str) -> None:
    original = db.save_setting

    def failing(k, value):
        if k == key:
            raise sqlite3.OperationalError("synthetic disk write failure")
        return original(k, value)

    monkeypatch.setattr(db, "save_setting", failing)


def _timed(monkeypatch, target, name: str = "request_stop", *, on_return: bool = False):
    """``target.name`` 진입(또는 반환) 시각을 잰다."""
    done = threading.Event()
    stamp: dict = {}
    original = getattr(target, name)

    def timed(*args, **kwargs):
        if not on_return:
            stamp.setdefault("at", time.perf_counter())
            done.set()
        out = original(*args, **kwargs)
        if on_return:
            stamp.setdefault("at", time.perf_counter())
            done.set()
        return out

    monkeypatch.setattr(target, name, timed)
    return done, stamp


def _watch_read(monkeypatch, quiet, frame_name: str) -> threading.Event:
    """``quiet.settings``가 ``frame_name`` 호출 스택 안에서 불리면 표시한다(그 읽기가 막히기 전에)."""
    read = threading.Event()
    original = quiet.settings

    def watched():
        if any(f.function == frame_name for f in inspect.stack(0)):
            read.set()
        return original()

    monkeypatch.setattr(quiet, "settings", watched)
    return read


# ── 공식 SDK·모의 클라우드 배선(①·②) ──────────────────────────────────────────────

pytest.importorskip("thinqconnect")

from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, cloud  # noqa: E402,F401


def _frame():
    from rpi.tests.test_auto_rules import _frame as frame

    return frame()


def _setup_cloud(monkeypatch, tmp_path, cloud_):
    from rpi.api import deps

    _env(monkeypatch, tmp_path, cloud_)
    monkeypatch.setenv("SIMPLELAY_API_KEY", KEY)
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "recheck.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    return app, TestClient(app, headers={"X-API-Key": KEY})


class _SignedLink:
    """진짜 ActClient ⇄ 진짜 ActExecutor(서명 키 같음)를 메모리 선으로 — 별도 이벤트 루프 스레드."""

    def __init__(self) -> None:
        from rpi4.tests.test_link_auth import KEY as LINK_KEY
        from rpi4.tests.test_link_auth import _Link, _ready

        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()

        async def _open():
            link = await _Link(LINK_KEY, LINK_KEY).start()
            await _ready(link)
            return link

        self.link = asyncio.run_coroutine_threadsafe(_open(), self.loop).result(5)
        self.abort_sent = threading.Event()
        self.stamp: dict = {}
        pipe = self.link.to_act
        original_write = pipe.write

        def write(data: bytes) -> None:
            if b'"abort"' in data:
                self.stamp.setdefault("abort", time.perf_counter())
                self.abort_sent.set()
            original_write(data)

        pipe.write = write

    def aborts(self) -> list[dict]:
        return [d for d in self.link.to_act.docs() if d.get("type") == "abort"]

    def close(self) -> None:
        try:
            asyncio.run_coroutine_threadsafe(self.link.close(), self.loop).result(5)
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
            self.thread.join(3)
            self.loop.close()


@pytest.mark.parametrize("target", ["local", "signed_link"])
def test_stop_reaches_request_stop_while_a_quiet_hours_save_waits_and_the_start_guard_reads_quiet(
        monkeypatch, tmp_path, cloud, target):
    """H-R1 ①: 자동 실행을 판단 뒤·제출 직전에 세움 → ``PUT /quiet-hours``의 DB 저장이 멈춤 → 자동 실행을 놓아
    시작 게이트(서비스 잠금 안)가 조용한 시간을 읽음 → 인증된 ``/stop`` — 로컬 ``request_stop``이(서명 링크면 abort
    송신까지) DB 대기와 무관하게 ``STOP_CALL_BOUND_S`` 안에. 그동안 DB 저장은 계속 멈춰 있다."""
    from rpi.api import deps
    from rpi.services.act_client_controller import ActClientController
    from rpi.services.quiet_hours import SETTING_KEY

    app, api = _setup_cloud(monkeypatch, tmp_path, cloud)
    go, release = threading.Event(), threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    link = None
    try:
        _allow(api)
        _set_low(api)
        service = deps.get_service()
        quiet = deps.get_quiet_hours()
        if target == "signed_link":
            link = _SignedLink()
            monkeypatch.setattr(service, "_controller", ActClientController(link.loop, link.link.client))

        at_submit = threading.Event()
        original_submit = service.submit_approved

        def held_submit(*args, **kwargs):
            if str(kwargs.get("scenario_id") or "").startswith("auto:"):
                at_submit.set()
                assert go.wait(20)
            return original_submit(*args, **kwargs)

        monkeypatch.setattr(service, "submit_approved", held_submit)
        _start(threads, lambda: deps.receive_appliance_done(_frame()))
        assert at_submit.wait(10), "자동 실행이 제출까지 오지 않았다"

        entered = _stuck_setting(monkeypatch, deps.get_db(), SETTING_KEY, release)
        _start(threads, lambda: results.setdefault("quiet", api.put("/quiet-hours", json=_now_window())))
        assert entered.wait(10), "조용한 시간 저장이 DB 쓰기까지 오지 않았다"

        read = _watch_read(monkeypatch, quiet, "_begin_run")
        go.set()
        assert read.wait(5), "시작 게이트가 조용한 시간을 읽지 않았다"
        time.sleep(0.1)

        called, stamp = _timed(monkeypatch, service._controller)
        started = time.perf_counter()
        _start(threads, lambda: results.setdefault("stop", api.post("/stop")))
        reached = called.wait(3)
        delay = stamp["at"] - started if reached else None
        print(f"\n[H-R1 ① {target}] request_stop 진입 {'없음' if delay is None else f'{delay * 1000:.2f} ms'}"
              " (조용한 시간 DB 저장은 멈춘 채)")
        assert reached and delay < STOP_CALL_BOUND_S, f"정지가 조용한 시간 저장을 기다렸다: {delay}"
        if link is not None:
            assert link.abort_sent.wait(STOP_CALL_BOUND_S), "서명 링크로 abort가 나가지 않았다"
            abort_delay = link.stamp["abort"] - started
            print(f"[H-R1 ① {target}] 서명 abort 송신 {abort_delay * 1000:.2f} ms")
            assert abort_delay < STOP_CALL_BOUND_S
            assert all("mac" in f and "seq" in f for f in link.aborts())
        assert not release.is_set()
    finally:
        go.set()
        release.set()
        for t in threads:
            t.join(15)
        if link is not None:
            link.close()
        _reset()
        deps.get_db.cache_clear()
    assert results["stop"].status_code == 200
    assert results["quiet"].status_code == 200 and results["quiet"].json()["persisted"] is True


def test_stop_is_not_held_by_a_commit_that_reads_quiet_while_its_save_waits(monkeypatch, tmp_path, cloud):
    """H-R1 ②: 최종 재판정을 지난 자동 실행을 세움 → ``PUT /quiet-hours`` DB 저장이 멈춤 → 실행을 놓아 전송권 확인
    (``commit``, ThinQ 실행기 잠금 안)이 조용한 시간을 읽음 → ``/stop``. 로컬 ``request_stop`` 진입, ThinQ 정지
    (보내기 전 취소 판정) 반환, ``/stop`` 응답 모두 DB 대기와 무관하다. 메모리 적용이 먼저라 그 실행은 보내지 않는다."""
    from rpi.api import deps
    from rpi.services.quiet_hours import SETTING_KEY
    from rpi.services.thinq.controller import ThinqController

    app, api = _setup_cloud(monkeypatch, tmp_path, cloud)
    go, release = threading.Event(), threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    try:
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        service = deps.get_service()
        quiet = deps.get_quiet_hours()
        at_guard = threading.Event()
        original_execute = ThinqController.execute_command

        def execute(controller, command, *, dispatch_guard=None):
            if dispatch_guard is None:
                return original_execute(controller, command)

            def held_guard(binding=None):
                out = dispatch_guard(binding)
                if binding is not None and not at_guard.is_set():
                    at_guard.set()
                    assert go.wait(20)
                return out

            return original_execute(controller, command, dispatch_guard=held_guard)

        monkeypatch.setattr(ThinqController, "execute_command", execute)
        _inject(api, inputs=("power",))
        assert at_guard.wait(10), "자동 실행이 최종 재판정까지 오지 않았다"

        entered = _stuck_setting(monkeypatch, deps.get_db(), SETTING_KEY, release)
        _start(threads, lambda: results.setdefault("quiet", api.put("/quiet-hours", json=_now_window())))
        assert entered.wait(10)

        read = _watch_read(monkeypatch, quiet, "commit")
        go.set()
        assert read.wait(5), "전송권 확인이 조용한 시간을 읽지 않았다"
        time.sleep(0.1)

        called, stamp = _timed(monkeypatch, service._controller)
        thinq_done, thinq_stamp = _timed(monkeypatch, service._thinq, on_return=True)
        started = time.perf_counter()
        stopper = _start(threads, lambda: results.setdefault("stop", api.post("/stop")))
        reached = called.wait(3)
        thinq_returned = thinq_done.wait(3)
        stopper.join(STOP_RESPONSE_BOUND_S)
        responded = time.perf_counter() - started
        delay = stamp["at"] - started if reached else None
        thinq_delay = thinq_stamp["at"] - started if thinq_returned else None
        print(f"\n[H-R1 ②] request_stop 진입 {delay and f'{delay * 1000:.2f} ms'}, ThinQ 정지 반환 "
              f"{thinq_delay and f'{thinq_delay * 1000:.2f} ms'}, /stop 응답 {'stop' in results}"
              f" {responded * 1000:.0f} ms (DB 저장은 멈춘 채)")
        assert reached and delay < STOP_CALL_BOUND_S
        assert thinq_returned and thinq_delay < STOP_CALL_BOUND_S, "ThinQ 정지가 전송권 확인의 DB 대기에 묶였다"
        assert "stop" in results and results["stop"].status_code == 200, "/stop 응답이 DB 대기에 묶였다"
        assert not release.is_set()
    finally:
        go.set()
        release.set()
        for t in threads:
            t.join(15)
        _reset()
        deps.get_db.cache_clear()
    assert len(cloud.controls()) == before  # 조용한 시간이 메모리에 먼저 들어가 그 실행은 보내지 않았다


# ── H-R2: 단일 Uvicorn 서버 + 별도 HTTP 클라이언트 두 개 ─────────────────────────────────


class _Server:
    def __init__(self, app) -> None:
        import uvicorn

        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.root = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        self.server = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="off", access_log=False))
        self.thread = threading.Thread(target=lambda: self.server.run(sockets=[self.sock]), daemon=True)
        self.thread.start()
        deadline = time.monotonic() + 10
        while not self.server.started and time.monotonic() < deadline:
            time.sleep(0.01)
        assert self.server.started

    def close(self) -> None:
        self.server.should_exit = True
        self.thread.join(10)
        self.sock.close()


def _client():
    import httpx

    return httpx.Client(timeout=15, trust_env=False)  # 클라이언트마다 따로(연결 공유 없음)


def _send(root: str, results: dict, name: str, method: str, path: str, body=None, client=None) -> None:
    """``client``를 주면 그것으로 보낸다 — 정지 시험은 시간을 재기 **전에** 만들어 둔다(2026-10-16). Windows에서는
    ``httpx.Client()`` 하나에 약 230 ms(인증서 묶음 로딩)가 걸려, 측정 뒤에 만들면 서버 정지 경로가 아니라 시험
    클라이언트 준비 시간을 재게 된다."""
    try:
        with client if client is not None else _client() as c:
            results[name] = c.request(method, root + path, json=body, headers={"X-API-Key": KEY})
    except Exception as exc:  # noqa: BLE001
        results[name + "_error"] = repr(exc)


@pytest.mark.parametrize("method", ["POST", "DELETE"])
def test_stop_reaches_request_stop_on_one_uvicorn_loop_while_a_pause_save_waits(monkeypatch, tmp_path, method):
    """H-R2: 한 Uvicorn 서버(이벤트 루프 하나)에 클라이언트 A가 ``POST``(또는 ``DELETE``) ``/dnd`` — 잠시 쉬기 DB 저장이
    멈춤 — 그동안 클라이언트 B의 ``/stop``이 로컬 ``request_stop``에 ``STOP_CALL_BOUND_S`` 안에 닿고 200으로 돌아온다."""
    from rpi.api import deps

    _mock_env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_API_KEY", KEY)
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "recheck.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    release = threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    server = None
    try:
        suggestions = deps.get_suggestion_service()
        service = deps.get_service()
        if method == "DELETE":
            suggestions.set_dnd_for(60)  # 지울 잠시 쉬기(정상 저장)
        entered = _stuck_setting(monkeypatch, deps.get_db(), deps.PAUSE_SETTING, release)
        called, stamp = _timed(monkeypatch, service._controller)
        server = _Server(app)
        body = {"duration_minutes": 60} if method == "POST" else None
        _start(threads, lambda: _send(server.root, results, "dnd", method, "/dnd", body))
        assert entered.wait(10), "잠시 쉬기 저장이 DB 쓰기까지 오지 않았다"

        stop_client = _client()  # 측정 전에 준비(시험 클라이언트 생성 시간을 정지 지연에 넣지 않는다)
        started = time.perf_counter()
        stopper = _start(threads, lambda: _send(server.root, results, "stop", "POST", "/stop", client=stop_client))
        reached = called.wait(3)
        stopper.join(STOP_RESPONSE_BOUND_S)
        delay = stamp["at"] - started if reached else None
        print(f"\n[H-R2 {method}] request_stop 진입 {'없음' if delay is None else f'{delay * 1000:.2f} ms'}, "
              f"/stop 응답 {'받음' if 'stop' in results else '없음'} (잠시 쉬기 DB 저장은 멈춘 채, 단일 Uvicorn 루프)")
        assert reached and delay < STOP_CALL_BOUND_S, f"/stop이 이벤트 루프의 DB 저장 대기에 묶였다: {delay}"
        assert "stop" in results and results["stop"].status_code == 200, results
        assert "dnd" not in results and not release.is_set()  # 잠시 쉬기 응답은 저장을 기다리는 중
        # 메모리 적용은 저장 전에 끝났다 — 판정은 이미 새 값.
        assert suggestions.is_dnd() is (method == "POST")
    finally:
        release.set()
        for t in threads:
            t.join(15)
        if server is not None:
            server.close()
        _reset()
        deps.get_db.cache_clear()
    assert results["dnd"].status_code == 200, results
    assert results["dnd"].json()["persisted"] is True and results["dnd"].json()["session_only"] is False


#: 이벤트 루프에서 동기 DB·네트워크 입출력을 하던 라우터 — ``def``(스레드풀)로 옮겼다(H-R2 전수 점검, devlog 표).
_OFF_LOOP_ROUTES = {
    "router": ["demo_care_event", "list_care_events", "list_appliances", "set_wellness_pause", "clear_wellness_pause",
               "report_readiness", "register_appliance", "calibrate_appliance", "delete_appliance",
               "reject_suggestion", "snooze_suggestion", "list_suppressions", "unmute_suppression", "demo_suggest",
               "history", "history_export", "demo_inject_failure", "demo_clear_failure", "register_node",
               "unregister_node"],
    "routines_router": ["list_routines", "create_routine", "next_routines", "get_routine", "update_routine",
                        "delete_routine", "enable_routine"],
}


def test_routes_doing_blocking_io_do_not_run_on_the_event_loop():
    import importlib

    on_loop = [f"{mod}.{name}" for mod, names in _OFF_LOOP_ROUTES.items()
               for name in names
               if inspect.iscoroutinefunction(getattr(importlib.import_module(f"rpi.api.{mod}"), name))]
    assert on_loop == [], f"동기 입출력을 이벤트 루프에서 하는 라우터: {on_loop}"


@pytest.mark.parametrize("what", ["node", "routine"])
def test_stop_reaches_request_stop_on_one_uvicorn_loop_while_a_node_or_routine_save_waits(monkeypatch, tmp_path, what):
    """H-R2 전수 점검에서 같이 고친 것: 노드 등록(노드 레지스트리 잠금 — 정지 경로가 서비스 잠금 안에서 읽는다)·루틴
    저장의 DB 쓰기가 멈춘 동안에도 같은 Uvicorn 루프의 ``/stop``이 ``request_stop``에 바로 닿는다."""
    from rpi.api import deps

    _mock_env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_API_KEY", KEY)
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "recheck.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    release = threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    server = None
    try:
        deps.get_suggestion_service()
        deps.get_node_registry()
        service = deps.get_service()
        db = deps.get_db()
        entered = threading.Event()
        name = "save_node" if what == "node" else "save_routine"
        original = getattr(db, name)

        def stuck(*args, **kwargs):
            entered.set()
            assert release.wait(20)
            return original(*args, **kwargs)

        monkeypatch.setattr(db, name, stuck)
        called, stamp = _timed(monkeypatch, service._controller)
        server = _Server(app)
        if what == "node":
            request = ("POST", "/nodes/fan", {"base_url": "http://127.0.0.1:9"})
        else:
            request = ("POST", "/routines", {
                "name": "공기 강", "trigger": {"kind": "manual"},
                "steps": [{"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
                           "args": {"wind_strength": "HIGH"}}]})
        _start(threads, lambda: _send(server.root, results, "write", *request))
        assert entered.wait(10), results
        stop_client = _client()  # 측정 전에 준비(시험 클라이언트 생성 시간을 정지 지연에 넣지 않는다)
        started = time.perf_counter()
        _start(threads, lambda: _send(server.root, results, "stop", "POST", "/stop", client=stop_client))
        reached = called.wait(3)
        delay = stamp["at"] - started if reached else None
        print(f"\n[H-R2 {what}] request_stop 진입 {'없음' if delay is None else f'{delay * 1000:.2f} ms'} (DB 쓰기는 멈춘 채)")
        assert reached and delay < STOP_CALL_BOUND_S
        assert not release.is_set()
    finally:
        release.set()
        for t in threads:
            t.join(15)
        if server is not None:
            server.close()
        _reset()
        deps.get_db.cache_clear()
    assert results["stop"].status_code == 200, results
    assert results["write"].status_code in (200, 201), results


def test_completed_actions_read_does_not_wait_for_a_stuck_save():
    """제안 승인 게이트(서비스 잠금 안)가 읽는 완료 기록 — 다른 실행의 완료 기록 DB 저장이 멈춰도 읽기는 바로."""
    from datetime import timezone

    from rpi.intent.completed_actions import CompletedActions

    release, entered = threading.Event(), threading.Event()

    def save(_value: str) -> None:
        entered.set()
        assert release.wait(10)

    done = CompletedActions(save=save)
    now = datetime(2026, 10, 14, 20, 0, tzinfo=timezone.utc)
    writer = threading.Thread(target=lambda: done.remember("microwave", "즉석밥 데워줘", ("시작",), now))
    writer.start()
    try:
        assert entered.wait(5)
        started = time.perf_counter()
        assert done.contains("microwave", "즉석밥 데워줘", (), now - timedelta(hours=1), now) is True
        assert time.perf_counter() - started < 0.05
    finally:
        release.set()
        writer.join(5)


# ── M-R1: 저장 실패 계약 — 이번 세션만 적용(재시작 뒤 유지 안 됨)과 저장 성공을 나눈다 ───────────────


@pytest.fixture()
def db_api(monkeypatch, tmp_path):
    from rpi.api import deps

    _mock_env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "recheck.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    yield app, TestClient(app)
    _reset()
    deps.get_db.cache_clear()


def _restart(app):
    from rpi.api import deps

    _reset()
    deps.get_db.cache_clear()
    return TestClient(app)


def test_pause_save_failure_says_this_session_only_and_the_pause_is_gone_after_restart(db_api, monkeypatch):
    from rpi.api import deps

    app, api = db_api
    _failing_setting(monkeypatch, deps.get_db(), deps.PAUSE_SETTING)
    res = api.post("/dnd", json={"duration_minutes": 60})
    assert res.status_code == 200
    assert res.json() == {"ok": True, "persisted": False, "session_only": True}
    assert api.get("/health/detail").json()["dnd_until"] is not None  # 이번 세션에는 적용
    api = _restart(app)  # 재시작(같은 DB 파일, 새 연결 — 실패 주입은 옛 연결에만)
    assert api.get("/health/detail").json()["dnd_until"] is None  # 계약: 재시작 뒤는 마지막으로 저장된 값(없음)


def test_pause_clear_save_failure_brings_the_last_saved_pause_back_after_restart(db_api, monkeypatch):
    from rpi.api import deps

    app, api = db_api
    first = api.post("/dnd", json={"duration_minutes": 60})
    assert first.json() == {"ok": True, "persisted": True, "session_only": False}
    saved_until = api.get("/health/detail").json()["dnd_until"]
    _failing_setting(monkeypatch, deps.get_db(), deps.PAUSE_SETTING)
    res = api.delete("/dnd")
    assert res.status_code == 200
    assert res.json() == {"ok": True, "persisted": False, "session_only": True}
    assert api.get("/health/detail").json()["dnd_until"] is None  # 이번 세션은 꺼짐
    api = _restart(app)
    assert api.get("/health/detail").json()["dnd_until"] == saved_until  # 재시작 뒤는 마지막 저장값


def test_quiet_hours_save_failure_keeps_the_session_value_and_restart_uses_the_last_saved_one(db_api, monkeypatch):
    from rpi.api import deps
    from rpi.services.quiet_hours import SETTING_KEY

    app, api = db_api
    ok = api.put("/quiet-hours", json={"enabled": True, "start": "01:00", "end": "02:00"})
    assert ok.status_code == 200 and ok.json()["persisted"] is True and ok.json()["session_only"] is False
    _failing_setting(monkeypatch, deps.get_db(), SETTING_KEY)
    res = api.put("/quiet-hours", json={"enabled": False})
    assert res.status_code == 200
    assert res.json()["persisted"] is False and res.json()["session_only"] is True
    assert res.json()["enabled"] is False and api.get("/quiet-hours").json()["enabled"] is False
    assert "persisted" not in api.get("/quiet-hours").json()  # 저장 결과는 바꾸는 응답에만
    api = _restart(app)
    body = api.get("/quiet-hours").json()
    assert (body["enabled"], body["start"], body["end"]) == (True, "01:00", "02:00")


def test_memory_only_server_says_no_store_rather_than_saved(monkeypatch):
    """DB가 없는 구성(개발 PC): 저장소가 없음을 ``persisted: null``로 — 저장 실패(false)와 구분, 세션만 적용은 true."""
    from rpi.api import deps

    _mock_env(monkeypatch, "mock")
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        assert api.post("/dnd", json={"duration_minutes": 30}).json() == {
            "ok": True, "persisted": None, "session_only": True}
        assert api.delete("/dnd").json() == {"ok": True, "persisted": None, "session_only": True}
        body = api.put("/quiet-hours", json={"enabled": True}).json()
        assert body["persisted"] is None and body["session_only"] is True
    finally:
        _reset()


# ── 판정용 사본과 영속 쓰기 분리 — 단위 ────────────────────────────────────────────────


def test_quiet_settings_read_does_not_wait_for_a_stuck_save_and_the_newest_value_wins():
    """조용한 시간 저장이 DB에서 멈춘 동안: 판정 읽기는 기다리지 않고 이미 새 값이며, 뒤이은 변경은 메모리에 바로
    들어간다. 저장은 순서대로 늘 그때의 가장 새 값을 쓴다 — 늦게 끝난 옛 쓰기가 새 값을 덮지 않는다."""
    import json

    from rpi.services.quiet_hours import QuietHours

    release, entered = threading.Event(), threading.Event()
    written: list[dict] = []

    def save(value: str) -> None:
        if not written and not entered.is_set():
            entered.set()
            assert release.wait(10)
        written.append(json.loads(value))

    quiet = QuietHours(save=save)
    first = threading.Thread(target=lambda: quiet.update({"enabled": True, "start": "01:00", "end": "02:00"}))
    first.start()
    try:
        assert entered.wait(5)
        started = time.perf_counter()
        assert quiet.settings()["enabled"] is True  # 저장 전에 메모리에 들어갔다
        assert time.perf_counter() - started < 0.05
        settings, version = quiet.apply({"start": "03:00"})
        assert settings == {"enabled": True, "start": "03:00", "end": "02:00"}
        second: list = []
        later = threading.Thread(target=lambda: second.append(quiet.persist(version)))
        later.start()
        time.sleep(0.05)
        assert quiet.settings()["start"] == "03:00"
    finally:
        release.set()
        first.join(5)
    later.join(5)
    assert second == [True]
    assert written[-1] == {"enabled": True, "start": "03:00", "end": "02:00"}


def test_a_failed_save_is_retried_with_the_newest_value_by_the_next_change():
    from rpi.services.quiet_hours import QuietHours

    calls: list[str] = []

    def save(value: str) -> None:
        calls.append(value)
        if len(calls) == 1:
            raise sqlite3.OperationalError("synthetic")

    quiet = QuietHours(save=save)
    _, v1 = quiet.apply({"enabled": True})
    assert quiet.persist(v1) is False and quiet.settings()["enabled"] is True
    _, v2 = quiet.apply({"start": "21:00"})
    assert quiet.persist(v2) is True
    assert '"enabled": true' in calls[-1] and '"21:00"' in calls[-1]
    assert quiet.persist(v1) is True  # 더 새 값이 이미 저장됐다


def test_motion_stop_does_not_wait_for_building_a_registered_nodes_controller(monkeypatch, tmp_path):
    """노드를 등록만 하고 아직 쓰지 않았으면 레지스트리가 정지 때 처음으로 노드 컨트롤러를 만든다(HTTP 클라이언트 생성 —
    Windows 데스크톱에서 약 230 ms, 2026-10-16 측정). 그 생성이 서비스 잠금 안에서 모터 ``request_stop``보다 **먼저** 돌아
    정지가 그만큼 늦었다. 모터 정지는 노드 목록을 모으기 전에 부른다 — 노드에도 정지는 그대로 간다."""
    from rpi.api import deps

    _mock_env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "node-build.db"))
    deps.get_db.cache_clear()
    _reset()
    try:
        registry = deps.get_node_registry()
        service = deps.get_service()
        original_factory = registry._controller_factory
        built: list[float] = []

        def slow_factory(base_url):
            time.sleep(0.4)  # 느린 클라이언트 생성을 흉내 낸다
            built.append(time.perf_counter())
            return original_factory(base_url)

        monkeypatch.setattr(registry, "_controller_factory", slow_factory)
        registry.register("fan", "http://127.0.0.1:9")
        called, stamp = _timed(monkeypatch, service._controller)
        started = time.perf_counter()
        report = service.emergency_stop_report()
        assert called.is_set()
        delay = stamp["at"] - started
        print(f"\n[node build] request_stop 진입 {delay * 1000:.2f} ms (노드 컨트롤러 생성 0.4 s)")
        assert delay < 0.1, f"모터 정지가 노드 컨트롤러 생성을 기다렸다: {delay:.3f} s"
        assert built and stamp["at"] < built[0]  # 모터 정지가 노드 생성보다 먼저
        assert "fan" in list(report.nodes_acknowledged) + list(report.nodes_unconfirmed)  # 노드에도 정지는 갔다
    finally:
        _reset()
        deps.get_db.cache_clear()
