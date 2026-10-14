"""재시작 직후 최초 생성(제안 서비스의 DB 읽기)이 이벤트 루프를 막아 ``/stop``이 들어오지 못하던 것(외부 재확인 3차, 2026-10-14).

- (a) 제안 서비스가 아직 없는 서버에 async 라우터(루틴 실행 기록·트리거 기록·지금 실행·시나리오·조용한 시간·자동 허용)의
      **첫 요청**이 오면, 그 라우터가 이벤트 루프에서 제안 서비스를 만들며 DB 읽기(``suggestion_cooldowns``)를 기다렸다 —
      같은 서버의 ``/stop``이 ``request_stop``에 들어가지 못했다.
- (b) lifespan을 켠 기동 직후 제안 갱신 루프가 ``asyncio.to_thread(get_suggestion_service().create_suggestions)``로
      **스레드에 넘기기 전에** 루프에서 제안 서비스를 만들었다 — 서버가 연결을 받기 시작하지 못하거나 ``/stop``이 막혔다.

계측은 실제 로컬 컨트롤러 ``request_stop`` 진입 시각이다(HTTP 요청 시작부터). 서버는 Uvicorn 하나(이벤트 루프 하나),
클라이언트는 요청마다 따로 연 httpx 클라이언트다. DB 대기는 시험이 실제 ``load_setting`` 경계에 건 문이다.
**실제 보드·전체 부팅·실가전은 쓰지 않는다.** 값은 개발 PC 기준이며 모터 정지 시간이 아니다. 이 시험이 보이는 것은 아래
조건뿐이다 — 어떤 상태에서도 정지가 늦지 않는다는 뜻이 아니다.
"""

from __future__ import annotations

import socket
import threading
import time

import pytest

from rpi.tests.test_eval_recheck2_stop import _cleanup, _db_app, _req, _wait
from rpi.tests.test_eval_recheck_stop import KEY, STOP_CALL_BOUND_S, STOP_RESPONSE_BOUND_S, _Server, _start, _timed

#: 최초 생성이 처음 읽는 DB 설정 — 제안 서비스의 쿨다운(외부 재확인 3차 부록 C와 같은 경계).
COLD_KEY = "suggestion_cooldowns"


def _stall_first_read(monkeypatch, db, key: str = COLD_KEY):
    """``db.load_setting(key)``를 ``release``까지 붙잡는다. 놓이면 실제로 읽는다."""
    entered = threading.Event()
    release = threading.Event()
    original = db.load_setting

    def stalled(k, *args, **kwargs):
        if k == key:
            entered.set()
            assert release.wait(20)
        return original(k, *args, **kwargs)

    monkeypatch.setattr(db, "load_setting", stalled)
    return entered, release


def _stop_timed_on_build(monkeypatch):
    """아직 만들지 않은 실행 서비스의 컨트롤러 ``request_stop`` 진입을 잰다(서비스를 만들 때 감싼다)."""
    from rpi.api import deps

    called = threading.Event()
    stamp: dict = {}
    original_build = deps.build_controller

    def build(*args, **kwargs):
        controller = original_build(*args, **kwargs)
        original_stop = controller.request_stop

        def timed(*a, **kw):
            stamp.setdefault("at", time.perf_counter())
            called.set()
            return original_stop(*a, **kw)

        controller.request_stop = timed
        return controller

    monkeypatch.setattr(deps, "build_controller", build)
    return called, stamp


@pytest.mark.parametrize(("method", "path", "body"), [
    ("GET", "/routines/runs", None),
    ("GET", "/routines/log", None),
    ("POST", "/routines/no-such-routine/trigger", None),
    ("GET", "/scenarios", None),
    ("POST", "/demo/scenario/no-such-scenario", None),
    ("GET", "/quiet-hours", None),
    ("PUT", "/quiet-hours", {"enabled": False}),
    ("POST", "/suggestions/no-such-card/approve-and-allow", {}),
])
def test_first_request_that_builds_the_suggestion_service_does_not_block_stop(monkeypatch, tmp_path, method, path, body):
    """(a) 제안 서비스 캐시가 빈 채 위 라우터의 첫 요청 → 최초 생성의 DB 읽기가 멈춤 → 다른 클라이언트의 ``/stop``이
    ``STOP_CALL_BOUND_S`` 안에 ``request_stop``에 들어가고 200. 읽기를 풀면 첫 요청도 끝난다(4xx는 없는 대상이라 정상)."""
    from rpi.api import deps

    app = _db_app(monkeypatch, tmp_path)
    service = deps.get_service()  # 정지 대상(외부 재확인 부록 C처럼 실행 서비스는 먼저 만든다)
    db = deps.get_db()
    assert deps.get_suggestion_service.cache_info().currsize == 0
    entered, release = _stall_first_read(monkeypatch, db)
    called, stamp = _timed(monkeypatch, service._controller)  # noqa: SLF001 -- 시험 계측
    server = _Server(app)
    threads: list[threading.Thread] = []
    results: dict = {}
    try:
        _start(threads, lambda: _req(server.root, results, "first", method, path,
                                     headers={"X-API-Key": KEY}, body=body))
        assert entered.wait(10), "첫 요청이 제안 서비스의 최초 DB 읽기에 닿지 않았다"
        started = time.perf_counter()
        stopper = _start(threads, lambda: _req(server.root, results, "stop", "POST", "/stop",
                                               headers={"X-API-Key": KEY}))
        reached = called.wait(STOP_CALL_BOUND_S * 3)
        stopper.join(STOP_RESPONSE_BOUND_S)
        delay = stamp["at"] - started if reached else None
        print(f"\n[cold {method} {path}] 최초 DB 읽기 멈춘 채 정지 진입 "
              f"{'없음' if delay is None else f'{delay * 1000:.2f} ms'}, 응답 "
              f"{results['stop'].status_code if 'stop' in results else '없음'}")
        assert reached and delay is not None and delay < STOP_CALL_BOUND_S, f"정지 진입 지연: {delay}"
        assert results["stop"].status_code == 200
        assert "first" not in results, "최초 생성이 끝나기 전에 첫 요청이 끝났다(문이 걸리지 않음)"
    finally:
        release.set()
        for thread in threads:
            thread.join(20)
        server.close()
        _cleanup()
    assert "first_error" not in results, results.get("first_error")
    assert results["first"].status_code < 500, results["first"].text
    assert deps.get_suggestion_service.cache_info().currsize == 0  # 정리됨(다음 시험에 새지 않음)


class _LifespanServer:
    """lifespan을 켠 Uvicorn — 기동 절차(제안 갱신·루틴 주기 루프 시작)를 그대로 탄다. 미리 잡은 소켓에 붙는다."""

    def __init__(self, app) -> None:
        import uvicorn

        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.root = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        self.server = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="on", access_log=False))
        self.thread = threading.Thread(target=lambda: self.server.run(sockets=[self.sock]), daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.server.should_exit = True
        self.thread.join(20)
        self.sock.close()


@pytest.mark.parametrize("service_built", [True, False], ids=["service_built", "service_cold"])
def test_stop_right_after_a_lifespan_start_while_the_suggestion_service_is_still_building(monkeypatch, tmp_path,
                                                                                        service_built):
    """(b) lifespan을 켜고 기동 — 제안 갱신 루프가 제안 서비스를 처음 만들며 DB 읽기에서 멈춘 채 — 기동 직후 ``/stop``이
    ``STOP_CALL_BOUND_S`` 안에 ``request_stop``에 들어가고 200. 실행 서비스를 먼저 만든 경우와 아직 없는 경우(정지가
    정지 전용 줄에서 만든다) 둘 다. 읽기를 풀면 제안 서비스가 하나만 만들어진다."""
    from rpi.api import deps

    app = _db_app(monkeypatch, tmp_path)
    db = deps.get_db()
    assert deps.get_suggestion_service.cache_info().currsize == 0
    if service_built:
        called, stamp = _timed(monkeypatch, deps.get_service()._controller)  # noqa: SLF001 -- 시험 계측
    else:
        assert deps.get_service.cache_info().currsize == 0
        called, stamp = _stop_timed_on_build(monkeypatch)
    entered, release = _stall_first_read(monkeypatch, db)
    server = _LifespanServer(app)
    threads: list[threading.Thread] = []
    results: dict = {}
    try:
        assert entered.wait(10), "기동 절차가 제안 서비스의 최초 DB 읽기에 닿지 않았다"
        started_listening = _wait(lambda: server.server.started, 3)
        started = time.perf_counter()
        stopper = _start(threads, lambda: _req(server.root, results, "stop", "POST", "/stop",
                                               headers={"X-API-Key": KEY}))
        reached = called.wait(STOP_CALL_BOUND_S * 3)
        stopper.join(STOP_RESPONSE_BOUND_S)
        delay = stamp["at"] - started if reached else None
        print(f"\n[lifespan {'service built' if service_built else 'service cold'}] 연결 받기 "
              f"{'시작' if started_listening else '못 함'}, 최초 DB 읽기 멈춘 채 정지 진입 "
              f"{'없음' if delay is None else f'{delay * 1000:.2f} ms'}, 응답 "
              f"{results['stop'].status_code if 'stop' in results else results.get('stop_error', '없음')}")
        assert started_listening, "기동 절차가 이벤트 루프를 막아 연결을 받기 시작하지 못했다"
        assert reached and delay is not None and delay < STOP_CALL_BOUND_S, f"정지 진입 지연: {delay}"
        assert results["stop"].status_code == 200
        assert not deps.get_suggestion_service.cache_info().currsize  # 아직 만드는 중(문이 걸린 채)
        release.set()
        assert _wait(lambda: deps.get_suggestion_service.cache_info().currsize == 1, 10)
        built = deps.get_suggestion_service()
        time.sleep(0.2)
        assert deps.get_suggestion_service() is built  # 갱신 루프·루틴 주기가 겹쳐도 하나
    finally:
        release.set()
        for thread in threads:
            thread.join(20)
        server.close()
        _cleanup()


def test_overlapping_first_builds_make_one_suggestion_service(monkeypatch, tmp_path):
    """최초 생성이 루프 밖 여러 스레드(제안 갱신 루프·루틴 주기·첫 요청)에서 겹쳐도 제안 서비스는 **하나** — 나중 호출은
    먼저 시작한 생성을 기다린다(시나리오·루틴 배선이 둘로 갈라지지 않는다). 최초 DB 읽기도 한 번."""
    from rpi.api import deps

    _db_app(monkeypatch, tmp_path)
    db = deps.get_db()
    reads = [0]
    entered, release = _stall_first_read(monkeypatch, db)
    stalled = db.load_setting

    def counted(k, *args, **kwargs):
        if k == COLD_KEY:
            reads[0] += 1
        return stalled(k, *args, **kwargs)

    monkeypatch.setattr(db, "load_setting", counted)
    got: dict = {}
    threads: list[threading.Thread] = []
    try:
        _start(threads, lambda: got.__setitem__("a", deps.get_suggestion_service()))
        assert entered.wait(10)
        _start(threads, lambda: got.__setitem__("b", deps.get_suggestion_service()))
        _start(threads, lambda: got.__setitem__("engine", deps.get_service()))  # 다른 싱글턴은 기다리지 않는다
        assert _wait(lambda: "engine" in got, 5), "실행 서비스 생성이 제안 서비스 생성을 기다렸다"
        time.sleep(0.2)
        assert "b" not in got  # 먼저 시작한 생성을 기다리는 중
        release.set()
        for thread in threads:
            thread.join(10)
        assert got["a"] is got["b"] is deps.get_suggestion_service()
        assert reads[0] == 1
    finally:
        release.set()
        for thread in threads:
            thread.join(10)
        _cleanup()
