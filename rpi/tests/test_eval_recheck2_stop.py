"""HIGH 재확인 2차(2026-10-14) 수리 — 공유 스레드 풀 고갈·이벤트 루프의 잠금 대기가 정지를 막지 않는다 ·
동시 변경이 지운 루틴을 되살리지 않는다 · 설정 응답의 값과 저장 결과가 같은 판을 가리킨다.

H-RR1: 정지(인증 의존성·서비스 의존성·정지 작업)가 일반 DB 요청과 AnyIO 기본 토큰·asyncio 기본 실행기를 같이 써서,
       DB가 멈춘 동안 ``GET /history``(토큰 수만큼)나 ``POST /dnd``(실행기 크기만큼)가 풀을 채우면 ``/stop``이
       ``request_stop``에 들어가지 못했다. 키오스크(루프백)·개발자 정지(``/dev/stop``)도 같다.
H-RR2: 가전 등록의 DB 쓰기가 가전 목록 잠금을 쥔 채 멈춘 동안 async 라우터(ThinQ 상태·기기 목록)가 이벤트 루프에서
       그 잠금을 기다려 같은 서버의 ``/stop``이 처리되지 않았다. 같은 모양: 보호자 알림 기록(키오스크 ``/ambient``)·루틴 목록.
M-RR1: 루틴 켜기·전체 교체가 읽은 뒤 저장하는 사이에 끝난 삭제·편집을 옛 객체로 덮었다(되살림·되돌림).
M-RR2: ``PUT /quiet-hours`` 응답이 지금(더 새) 설정 값에 옛 요청의 저장 성공을 붙였다.

계측은 API 응답이 아니라 실제 로컬 컨트롤러 ``request_stop`` 진입(개발자 정지는 매니저 ``emergency_stop`` 진입)이다.
서버는 Uvicorn 하나(이벤트 루프 하나), 클라이언트는 요청마다 따로 연 httpx 클라이언트다. 풀 크기는 기본값 그대로다.
**실제 보드·실가전·ThinQ 클라우드는 쓰지 않는다.** DB 대기는 시험이 실제 DB 잠금을 잡거나 저장 함수에 건 문이다.
값은 개발 PC 기준이며 보드·모터 정지 시간이 아니다. 이 시험이 보이는 것은 아래 조건뿐이다 — 어떤 부하에서도 정지를 보장한다는 뜻이 아니다.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import sqlite3
import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_cook_done_card import _env as _mock_env
from rpi.tests.test_cook_done_card import _reset
from rpi.tests.test_eval_recheck_stop import KEY, STOP_CALL_BOUND_S, STOP_RESPONSE_BOUND_S, _Server, _start, _timed

pytest.importorskip("thinqconnect")

from rpi.tests.test_auto_rule_e2e import cloud  # noqa: E402,F401

DEV_TOKEN = "recheck2-dev-token-0123456789"
#: Uvicorn은 루프백 피어의 X-Forwarded-For를 믿는다(기본 forwarded_allow_ips) — 요청자가 LAN 주소로 보여 API 키 검사를 탄다.
LAN = {"X-Forwarded-For": "192.168.0.50"}


def _client():
    import httpx

    return httpx.Client(timeout=20, trust_env=False)  # 요청마다 따로(연결 공유 없음)


def _req(root: str, results: dict, name: str, method: str, path: str, *, headers=None, body=None,
         client=None) -> None:
    """``client``를 주면 그것으로 보낸다 — 정지 시험은 시간을 재기 **전에** 만들어 둔다(2026-10-16, Windows에서
    ``httpx.Client()`` 하나에 약 230 ms가 걸려 측정 뒤에 만들면 서버 정지 경로가 아니라 시험 준비 시간을 잰다)."""
    try:
        with client if client is not None else _client() as c:
            results[name] = c.request(method, root + path, json=body, headers=headers or {})
    except Exception as exc:  # noqa: BLE001
        results[name + "_error"] = repr(exc)


_stop_client = _client


class _Observed:
    """요청을 처리하는 이벤트 루프를 잡아 둔다(기본 풀 크기 조회용)."""

    def __init__(self, app) -> None:
        self.app = app
        self.loop: asyncio.AbstractEventLoop | None = None

    async def __call__(self, scope, receive, send):
        if self.loop is None and scope["type"] == "http":
            self.loop = asyncio.get_running_loop()
        await self.app(scope, receive, send)


def _pool_sizes(loop) -> tuple[int, int]:
    """이 서버 루프의 AnyIO 기본 토큰 수와 asyncio 기본 실행기 크기 — 바꾸지 않고 읽기만."""

    async def probe():
        import anyio.to_thread

        await asyncio.to_thread(lambda: None)
        return (int(anyio.to_thread.current_default_thread_limiter().total_tokens),
                loop._default_executor._max_workers)  # noqa: SLF001 -- 시험 계측

    return asyncio.run_coroutine_threadsafe(probe(), loop).result(5)


def _db_app(monkeypatch, tmp_path, *, dev: bool = False):
    from rpi.api import deps
    from rpi.api import dev_router

    _mock_env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_API_KEY", KEY)
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "recheck2.db"))
    monkeypatch.delenv("SIMPLELAY_DEV_REAL_MOTION", raising=False)
    if dev:
        monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
        monkeypatch.setenv(dev_router.DEV_TOKEN_ENV, DEV_TOKEN)
    else:
        monkeypatch.delenv("SIMPLELAY_DEV_MODE", raising=False)
    deps.get_db.cache_clear()
    deps.get_developer_session_manager.cache_clear()
    dev_router.get_dev_api_state.cache_clear()
    _reset()
    from rpi.main import app

    return app


def _cleanup() -> None:
    from rpi.api import deps
    from rpi.api import dev_router

    _reset()
    deps.get_db.cache_clear()
    deps.get_developer_session_manager.cache_clear()
    dev_router.get_dev_api_state.cache_clear()


def _counted(monkeypatch, owner, name: str):
    """``owner.name``에 들어온 횟수(그 스레드가 일을 시작한 순간)를 센다."""
    count = [0]
    lock = threading.Lock()
    original = getattr(owner, name)

    def counted(*args, **kwargs):
        with lock:
            count[0] += 1
        return original(*args, **kwargs)

    monkeypatch.setattr(owner, name, counted)
    return count


def _wait(pred, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return pred()


# ── H-RR1: 공유 스레드 풀 고갈 ───────────────────────────────────────────────────────


@pytest.mark.parametrize(("pool", "caller"), [
    ("anyio", "phone"), ("anyio", "kiosk"), ("anyio", "developer"),
    ("asyncio", "phone"), ("asyncio", "kiosk"),
])
def test_stop_reaches_request_stop_while_the_shared_thread_pools_are_exhausted(monkeypatch, tmp_path, pool, caller):
    """실제 DB 잠금을 잡은 채 (anyio) ``GET /history``를 AnyIO 기본 토큰 수만큼, (asyncio) ``POST /dnd``를 asyncio 기본
    실행기 크기만큼 보내 두 풀을 채운 뒤 정지 — 폰(LAN 주소 + API 키)·키오스크(루프백)·개발자(``/dev/stop`` + 개발자
    토큰). 정지 진입이 ``STOP_CALL_BOUND_S`` 안, 응답 200. 그동안 DB 잠금은 그대로, 키 없는 LAN 정지는 여전히 401."""
    from rpi.api import deps

    app = _db_app(monkeypatch, tmp_path, dev=caller == "developer")
    db = deps.get_db()
    service = deps.get_service()
    suggestions = deps.get_suggestion_service()
    deps.get_job_history()
    observed = _Observed(app)
    server = _Server(observed)
    threads: list[threading.Thread] = []
    fillers: dict = {}
    results: dict = {}
    held = False
    try:
        probe: dict = {}
        _req(server.root, probe, "health", "GET", "/health")
        assert probe["health"].status_code == 200 and observed.loop is not None
        tokens, workers = _pool_sizes(observed.loop)
        n = tokens if pool == "anyio" else workers
        if pool == "anyio":
            count = _counted(monkeypatch, db, "recent_job_history")
            filler = ("GET", "/history", None)
        else:
            count = _counted(monkeypatch, suggestions, "persist_pause")
            filler = ("POST", "/dnd", {"duration_minutes": 60})
        if caller == "developer":
            manager = deps.get_developer_session_manager()
            called, stamp = _timed(monkeypatch, manager, "emergency_stop")
        else:
            called, stamp = _timed(monkeypatch, service._controller)

        db._lock.acquire()  # noqa: SLF001 -- 실제 DB 잠금(느린 커밋 흉내)
        held = True
        for i in range(n):
            method, path, body = filler
            _start(threads, lambda i=i, m=method, p=path, b=body: _req(server.root, fillers, f"f{i}", m, p, body=b))
        assert _wait(lambda: count[0] >= n, 20), f"{pool} 풀이 차지 않았다: {count[0]}/{n}"
        time.sleep(0.1)

        if caller == "phone":
            stop = ("POST", "/stop", {"X-API-Key": KEY, **LAN})
        elif caller == "kiosk":
            stop = ("POST", "/stop", {})
        else:
            stop = ("POST", "/dev/stop", {"X-Dev-Token": DEV_TOKEN})
        stop_client = _stop_client()  # 측정 전에 준비(시험 클라이언트 생성 시간을 정지 지연에 넣지 않는다)
        started = time.perf_counter()
        stopper = _start(threads, lambda: _req(server.root, results, "stop", stop[0], stop[1], headers=stop[2], client=stop_client))
        reached = called.wait(3)
        stopper.join(STOP_RESPONSE_BOUND_S)
        delay = stamp["at"] - started if reached else None
        print(f"\n[H-RR1 {pool}·{caller}] 기본 풀 토큰 {tokens}·실행기 {workers}, 채운 요청 {n} — 정지 진입 "
              f"{'없음' if delay is None else f'{delay * 1000:.2f} ms'}, 응답 "
              f"{results['stop'].status_code if 'stop' in results else '없음'} (DB 잠금은 잡힌 채)")
        assert reached and delay < STOP_CALL_BOUND_S, f"정지가 공유 풀 고갈에 묶였다: {delay}"
        assert "stop" in results and results["stop"].status_code == 200, results
        if caller == "phone":
            _req(server.root, results, "nokey", "POST", "/stop", headers=dict(LAN))
            assert results["nokey"].status_code == 401  # 풀이 차 있어도 인증은 그대로
        assert count[0] == n and held and not fillers  # 채운 요청은 아직 DB를 기다린다
    finally:
        if held:
            db._lock.release()  # noqa: SLF001
        for t in threads:
            t.join(20)
        server.close()
        _cleanup()
    assert len(fillers) == n and all(r.status_code == 200 for r in fillers.values()), fillers


# ── H-RR2: 이벤트 루프에서 DB 대기 잠금을 읽던 async 라우터 ─────────────────────────────────


def _hold(monkeypatch, owner, name: str, release: threading.Event) -> threading.Event:
    entered = threading.Event()
    original = getattr(owner, name)

    def held(*args, **kwargs):
        entered.set()
        assert release.wait(20)
        return original(*args, **kwargs)

    monkeypatch.setattr(owner, name, held)
    return entered


def _watch(monkeypatch, owner, name: str, frame: str) -> threading.Event:
    """``owner.name``이 ``frame`` 호출 스택 안에서 불리면(그 읽기가 막히기 전에) 표시한다."""
    seen = threading.Event()
    original = getattr(owner, name)

    def watched(*args, **kwargs):
        if any(f.function == frame for f in inspect.stack(0)):
            seen.set()
        return original(*args, **kwargs)

    monkeypatch.setattr(owner, name, watched)
    return seen


def _stop_while_a_read_waits(server, threads, results, called, stamp, label: str) -> float | None:
    stop_client = _stop_client()  # 측정 전에 준비(시험 클라이언트 생성 시간을 정지 지연에 넣지 않는다)
    started = time.perf_counter()
    stopper = _start(threads, lambda: _req(server.root, results, "stop", "POST", "/stop",
                                           headers={"X-API-Key": KEY, **LAN}, client=stop_client))
    reached = called.wait(3)
    stopper.join(STOP_RESPONSE_BOUND_S)
    delay = stamp["at"] - started if reached else None
    print(f"\n[{label}] 정지 진입 {'없음' if delay is None else f'{delay * 1000:.2f} ms'}, 응답 "
          f"{results['stop'].status_code if 'stop' in results else '없음'} (DB 쓰기는 멈춘 채)")
    return delay


@pytest.mark.parametrize(("path", "frame", "read"), [
    ("/thinq/status/air_purifier", "thinq_status", "get"),
    ("/thinq/devices", "thinq_devices", "system_appliances"),
])
def test_stop_is_not_blocked_by_a_thinq_read_while_an_appliance_save_waits(monkeypatch, tmp_path, path, frame, read):
    """``PUT /appliances/audit_custom``의 ``save_appliance``가 멈춤 → ThinQ 상태·기기 목록(async)이 가전 목록을 읽음 →
    인증된 ``/stop``. 정지 진입 ``STOP_CALL_BOUND_S`` 안. 목록 읽기는 기다리지 않고 **저장 전 값**(DB 먼저 규칙)을 본다."""
    from rpi.api import deps

    app = _db_app(monkeypatch, tmp_path)
    db = deps.get_db()
    service = deps.get_service()
    registry = deps.get_appliance_registry()
    release = threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    server = None
    try:
        entered = _hold(monkeypatch, db, "save_appliance", release)
        seen = _watch(monkeypatch, registry, read, frame)
        called, stamp = _timed(monkeypatch, service._controller)
        server = _Server(app)
        body = {"name": "Audit appliance", "rows": 1, "cols": 1,
                "buttons": [{"id": "power", "label": "Power", "x": 0, "y": 0}]}
        _start(threads, lambda: _req(server.root, results, "write", "PUT", "/appliances/audit_custom", body=body))
        assert entered.wait(10), results
        _start(threads, lambda: _req(server.root, results, "read", "GET", path))
        assert seen.wait(5), "ThinQ 라우터가 가전 목록을 읽지 않았다"
        time.sleep(0.1)
        delay = _stop_while_a_read_waits(server, threads, results, called, stamp, f"H-RR2 {frame}")
        assert delay is not None and delay < STOP_CALL_BOUND_S, f"정지가 가전 목록 잠금 대기에 묶였다: {delay}"
        assert results["stop"].status_code == 200
        assert "read" in results and results["read"].status_code == 200, results  # 읽기는 저장을 기다리지 않았다
        assert registry.get("audit_custom") is None  # DB 먼저 — 저장이 끝나기 전에는 메모리도 그대로
        assert "write" not in results and not release.is_set()
    finally:
        release.set()
        for t in threads:
            t.join(20)
        if server is not None:
            server.close()
        _cleanup()
    assert results["write"].status_code in (200, 201), results
    assert registry.get("audit_custom") is not None


def test_stop_is_not_blocked_by_the_kiosk_ambient_poll_while_a_care_event_write_waits(monkeypatch, tmp_path):
    """같은 모양(전수 점검): 보호자 알림 기록의 DB 쓰기가 기록 잠금을 쥔 채 멈춤(``POST /demo/care-event``) → 키오스크가
    주기적으로 부르는 ``GET /ambient``(async)가 최근 알림을 읽음 → ``/stop``이 바로 진입하고, ``/ambient``는 기다리지 않는다."""
    from rpi.api import deps

    app = _db_app(monkeypatch, tmp_path)
    db = deps.get_db()
    service = deps.get_service()
    care = deps.get_care_events()
    release = threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    server = None
    try:
        entered = _hold(monkeypatch, db, "append_care_event", release)
        seen = _watch(monkeypatch, care, "recent", "ambient")
        called, stamp = _timed(monkeypatch, service._controller)
        server = _Server(app)
        _start(threads, lambda: _req(server.root, results, "write", "POST", "/demo/care-event", body={}))
        assert entered.wait(10), results
        _start(threads, lambda: _req(server.root, results, "read", "GET", "/ambient"))
        assert seen.wait(5), "/ambient가 최근 알림을 읽지 않았다"
        time.sleep(0.1)
        delay = _stop_while_a_read_waits(server, threads, results, called, stamp, "H-RR2 ambient")
        assert delay is not None and delay < STOP_CALL_BOUND_S, f"정지가 알림 기록 잠금 대기에 묶였다: {delay}"
        assert results["stop"].status_code == 200
        assert "read" in results and results["read"].status_code == 200, results
        assert "write" not in results and not release.is_set()
    finally:
        release.set()
        for t in threads:
            t.join(20)
        if server is not None:
            server.close()
        _cleanup()
    assert results["write"].status_code in (200, 201), results


def test_store_reads_do_not_wait_for_a_stuck_write():
    """가전 목록·보호자 알림·루틴 저장소: 쓰기가 DB에서 멈춘 동안 읽기는 50 ms 안에, 저장 전 값으로 답한다(DB 먼저 규칙)."""
    from datetime import datetime, timezone

    from rpi.routines.store import RoutineStore
    from rpi.services import ApplianceButtonDef, ApplianceDef
    from rpi.services.appliance_registry import ApplianceRegistry
    from rpi.services.care_events import CareEventStore

    release = threading.Event()

    class _Db:
        def __init__(self) -> None:
            self.entered = threading.Event()

        def _stuck(self, *_args, **_kwargs):
            self.entered.set()
            assert release.wait(10)

        def appliances(self):
            return []

        def routine_documents(self):
            return []

        def care_events(self, limit=200):
            return []

        def save_appliance(self, appliance):
            self._stuck()

        def save_routine(self, *args):
            self._stuck()

        def append_care_event(self, *args):
            self._stuck()
            return 1

    class _Clock:
        def now(self):
            return datetime(2026, 10, 14, 21, 0, tzinfo=timezone.utc)

    def check(write, read, expect) -> None:
        db = _Db()
        target = write(db)
        writer = threading.Thread(target=target)
        writer.start()
        try:
            assert db.entered.wait(5)
            started = time.perf_counter()
            assert read() == expect
            assert time.perf_counter() - started < 0.05
        finally:
            release.set()
            writer.join(5)
            release.clear()

    appliance = ApplianceDef(appliance_id="audit_custom", name="Audit", rows=1, cols=1,
                             buttons=(ApplianceButtonDef(id="power", label="Power", x=0, y=0),))
    holder: dict = {}

    def registry_write(db):
        holder["registry"] = ApplianceRegistry(store=db)
        return lambda: holder["registry"].register(appliance)

    check(registry_write, lambda: holder["registry"].get("audit_custom"), None)

    def care_write(db):
        holder["care"] = CareEventStore(_Clock(), db=db)
        return lambda: holder["care"].append("quiet_routine", "test")

    check(care_write, lambda: holder["care"].recent(), ())

    def routine_write(db):
        from rpi.routines import build_routine

        holder["routines"] = RoutineStore(db)
        routine = build_routine({"name": "r", "trigger": {"kind": "manual"}, "steps": [
            {"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
             "args": {"wind_strength": "HIGH"}}]}, routine_id="rt-1", now=_Clock().now())
        return lambda: holder["routines"].save(routine)

    check(routine_write, lambda: holder["routines"].list(), ())


# ── M-RR1: 루틴 켜기·전체 교체와 삭제·편집의 경합 ─────────────────────────────────────────

_ROUTINE = {"name": "Original name", "trigger": {"kind": "manual"}, "enabled": False,
            "steps": [{"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
                       "args": {"wind_strength": "HIGH"}}]}
_EDITED = {**_ROUTINE, "name": "New name",
           "steps": [{"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
                      "args": {"wind_strength": "LOW"}}]}


def _hold_in(monkeypatch, module, name: str, frame: str, release: threading.Event) -> threading.Event:
    """``module.name``을 ``frame`` 라우터가 직접 부를 때만 ``release``까지 세운다(그 라우터의 읽기 뒤·쓰기 앞)."""
    entered = threading.Event()
    original = getattr(module, name)

    def held(*args, **kwargs):
        if sys._getframe(1).f_code.co_name == frame:  # noqa: SLF001
            entered.set()
            assert release.wait(20)
        return original(*args, **kwargs)

    monkeypatch.setattr(module, name, held)
    return entered


@pytest.mark.parametrize(("held", "change"), [
    ("enable", "delete"), ("enable", "edit"), ("put", "delete"), ("put", "enable"),
])
def test_a_routine_change_does_not_overwrite_a_delete_or_edit_that_finished_meanwhile(monkeypatch, tmp_path, held, change):
    """클라이언트 A의 켜기(또는 전체 교체)를 루틴을 읽은 뒤·저장 앞에서 세움 → 클라이언트 B의 삭제·편집·켜기가 끝남(200)
    → A를 놓음. 삭제는 유지(A는 404), 편집은 유지(켜기는 최신 객체의 enabled만 바꿈), 교체가 낡았으면 409."""
    import rpi.api.routines_router as rr

    app = _db_app(monkeypatch, tmp_path)
    api = TestClient(app, headers={"X-API-Key": KEY})
    made = api.post("/routines", json=_ROUTINE)
    assert made.status_code == 201, made.text
    rid = made.json()["id"]
    release = threading.Event()
    threads: list[threading.Thread] = []
    results: dict = {}
    server = None
    try:
        if held == "enable":
            entered = _hold_in(monkeypatch, rr, "get_clock", "enable_routine", release)
            first = ("POST", f"/routines/{rid}/enable", {"enabled": True})
        else:
            entered = _hold_in(monkeypatch, rr, "_build", "update_routine", release)
            first = ("PUT", f"/routines/{rid}", {**_ROUTINE, "name": "Replaced name"})
        server = _Server(app)
        _start(threads, lambda: _req(server.root, results, "first", first[0], first[1], body=first[2]))
        assert entered.wait(10), results
        if change == "delete":
            _req(server.root, results, "change", "DELETE", f"/routines/{rid}")
        elif change == "edit":
            _req(server.root, results, "change", "PUT", f"/routines/{rid}", body=_EDITED)
        else:
            _req(server.root, results, "change", "POST", f"/routines/{rid}/enable", body={"enabled": True})
        assert results["change"].status_code == 200, results["change"].text
        release.set()
        threads[0].join(20)
        _req(server.root, results, "final", "GET", f"/routines/{rid}")
    finally:
        release.set()
        for t in threads:
            t.join(20)
        if server is not None:
            server.close()
        _cleanup()
    first_res, final = results["first"], results["final"]
    print(f"\n[M-RR1 {held}×{change}] A {first_res.status_code}, 최종 {final.status_code} "
          f"{final.json().get('name') if final.status_code == 200 else ''}")
    if change == "delete":
        assert first_res.status_code == 404, first_res.text  # 지운 루틴을 되살리지 않는다
        assert final.status_code == 404
    elif change == "edit":
        assert first_res.status_code == 200 and first_res.json()["name"] == "New name"
        body = final.json()
        assert (body["name"], body["enabled"]) == ("New name", True)
        assert body["steps"][0]["args"] == {"wind_strength": "LOW"}
    else:
        assert first_res.status_code == 409, first_res.text  # 읽은 뒤 바뀐 루틴을 옛 판으로 덮지 않는다
        body = final.json()
        assert (body["name"], body["enabled"]) == ("Original name", True)


@pytest.mark.parametrize("change", ["delete", "value"])
def test_re_allowing_an_auto_rule_does_not_resurrect_or_revert_a_change_that_finished_meanwhile(
        monkeypatch, tmp_path, cloud, change):
    """같은 읽기→저장 모양(전수 점검): 자동 실행 규칙 다시 허용이 규칙을 읽은 뒤 저장하기 전에 다른 요청의 삭제·값 바꾸기가
    끝나면 — 삭제는 유지(404), 값 바꾸기는 유지(409, 꺼진 채). 옛 객체로 되살리거나 되돌리지 않는다."""
    from rpi.routines.wiring import get_auto_rule_engine
    from rpi.tests.test_auto_rule_e2e import _allow
    from rpi.tests.test_eval_recheck_stop import _setup_cloud

    app, api = _setup_cloud(monkeypatch, tmp_path, cloud)
    try:
        _allow(api)
        rule = api.get("/routines/auto-rules").json()[0]
        rid = rule["id"]
        assert api.post(f"/routines/auto-rules/{rid}/enable", json={"enabled": False}).status_code == 200
        rule = next(r for r in api.get("/routines/auto-rules").json() if r["id"] == rid)
        other = next(v["value"] for v in rule["allowed_values"] if v["value"] != rule["value"])
        engine = get_auto_rule_engine()
        original = engine._rebound
        fired: list[bool] = []

        def racing(r):
            out = original(r)
            if not fired and any(f.function == "set_enabled" for f in inspect.stack(0)):
                fired.append(True)  # 다시 허용이 규칙을 읽은 뒤 — 다른 요청의 변경이 끝난다
                if change == "delete":
                    engine.delete(rid)
                else:
                    engine.update(rid, {"value": other})
            return out

        monkeypatch.setattr(engine, "_rebound", racing)
        res = api.post(f"/routines/auto-rules/{rid}/enable", json={"enabled": True, "fingerprint": rule["fingerprint"]})
        assert fired
        stored = engine.store.get(rid)
        if change == "delete":
            assert res.status_code == 404, res.text
            assert stored is None
        else:
            assert res.status_code == 409, res.text
            assert stored.value == other and not engine.usable(stored)
    finally:
        _reset()
        from rpi.api import deps

        deps.get_db.cache_clear()


# ── M-RR2: 조용한 시간 응답 = 그 저장이 쓴 값 + 그 저장의 결과 ────────────────────────────────


def test_quiet_hours_responses_bind_the_value_to_the_save_that_wrote_it(monkeypatch, tmp_path):
    """A가 enabled=true 저장 중 멈춤 → B가 enabled=false를 메모리에 적용하고 저장을 기다림 → A 저장 완료 → B 저장 실패.
    A 응답: enabled=true·persisted=true(DB도 true). B 응답: enabled=false·persisted=false·session_only=true.
    재시작하면 마지막으로 저장된 값(true)."""
    from rpi.api import deps
    from rpi.services.quiet_hours import SETTING_KEY

    app = _db_app(monkeypatch, tmp_path)
    db = deps.get_db()
    quiet = deps.get_quiet_hours()
    original = db.save_setting
    release_a, release_b = threading.Event(), threading.Event()
    entered_a, entered_b = threading.Event(), threading.Event()
    calls = [0]

    def save(key, value):
        if key == SETTING_KEY:
            calls[0] += 1
            if calls[0] == 1:
                entered_a.set()
                assert release_a.wait(20)
            elif calls[0] == 2:
                entered_b.set()
                assert release_b.wait(20)
                raise sqlite3.OperationalError("synthetic second save failure")
        return original(key, value)

    monkeypatch.setattr(db, "save_setting", save)
    threads: list[threading.Thread] = []
    results: dict = {}
    server = _Server(app)
    try:
        a = _start(threads, lambda: _req(server.root, results, "a", "PUT", "/quiet-hours",
                                         body={"enabled": True, "start": "22:00", "end": "07:00"}))
        assert entered_a.wait(10)
        b = _start(threads, lambda: _req(server.root, results, "b", "PUT", "/quiet-hours", body={"enabled": False}))
        assert _wait(lambda: quiet.settings()["enabled"] is False, 5)  # B는 메모리에 먼저 적용됐다
        release_a.set()
        assert entered_b.wait(10)
        a.join(10)
        stored_after_a = json.loads(db.load_setting(SETTING_KEY))["enabled"]
        release_b.set()
        b.join(10)
    finally:
        release_a.set()
        release_b.set()
        for t in threads:
            t.join(20)
        server.close()
    ra, rb = results["a"].json(), results["b"].json()
    print(f"\n[M-RR2] A enabled={ra['enabled']} persisted={ra['persisted']} · B enabled={rb['enabled']} "
          f"persisted={rb['persisted']} · DB enabled={stored_after_a}")
    assert (ra["enabled"], ra["persisted"], ra["session_only"]) == (True, True, False)
    assert stored_after_a is True
    assert (rb["enabled"], rb["persisted"], rb["session_only"]) == (False, False, True)
    try:
        api = TestClient(app, headers={"X-API-Key": KEY})
        assert api.get("/quiet-hours").json()["enabled"] is False  # 이번 세션은 B
        _reset()
        deps.get_db.cache_clear()
        assert api.get("/quiet-hours").json()["enabled"] is True  # 재시작 뒤는 마지막 저장값(A)
    finally:
        _cleanup()


def test_pause_responses_keep_the_same_contract_when_two_changes_cross(monkeypatch, tmp_path):
    """잠시 쉬기(``POST``·``DELETE /dnd``)도 같은 계약 — 응답에 값이 없으므로 ``persisted``는 '이 요청의 변경이 저장된 판에
    들어갔는가'만 말한다. A(켜기) 저장 완료 → true, B(끄기) 저장 실패 → false·session_only. 재시작 뒤는 A."""
    from rpi.api import deps

    app = _db_app(monkeypatch, tmp_path)
    db = deps.get_db()
    suggestions = deps.get_suggestion_service()
    original = db.save_setting
    release_a, release_b = threading.Event(), threading.Event()
    entered_a, entered_b = threading.Event(), threading.Event()
    calls = [0]

    def save(key, value):
        if key == deps.PAUSE_SETTING:
            calls[0] += 1
            if calls[0] == 1:
                entered_a.set()
                assert release_a.wait(20)
            elif calls[0] == 2:
                entered_b.set()
                assert release_b.wait(20)
                raise sqlite3.OperationalError("synthetic second save failure")
        return original(key, value)

    monkeypatch.setattr(db, "save_setting", save)
    threads: list[threading.Thread] = []
    results: dict = {}
    server = _Server(app)
    try:
        a = _start(threads, lambda: _req(server.root, results, "a", "POST", "/dnd", body={"duration_minutes": 60}))
        assert entered_a.wait(10)
        b = _start(threads, lambda: _req(server.root, results, "b", "DELETE", "/dnd"))
        assert _wait(lambda: not suggestions.is_dnd(), 5)
        release_a.set()
        assert entered_b.wait(10)
        a.join(10)
        release_b.set()
        b.join(10)
    finally:
        release_a.set()
        release_b.set()
        for t in threads:
            t.join(20)
        server.close()
    assert results["a"].json() == {"ok": True, "persisted": True, "session_only": False}
    assert results["b"].json() == {"ok": True, "persisted": False, "session_only": True}
    try:
        api = TestClient(app, headers={"X-API-Key": KEY})
        assert api.get("/health/detail").json()["dnd_until"] is None  # 이번 세션은 B(꺼짐)
        _reset()
        deps.get_db.cache_clear()
        assert api.get("/health/detail").json()["dnd_until"] is not None  # 재시작 뒤는 A
    finally:
        _cleanup()
