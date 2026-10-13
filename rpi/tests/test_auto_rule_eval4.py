"""4차 외부 평가(2026-10-14, 84점) 수리 — 실제 API·서비스·ThinQ controller·공식 SDK·저장소 안 모의 클라우드 배선.

H-N2: 자동 실행의 시작 게이트(서비스 잠금 안)가 규칙 저장소 잠금을 기다리고, 그 잠금을 다른 스레드의 규칙 저장이
      DB 쓰기 동안 잡고 있으면 ``/stop``이 서비스 잠금을 못 얻어 물리 정지(``request_stop``)가 DB 대기만큼 늦었다.

**실제 ThinQ 클라우드·실가전·실제 CT 판정·보드는 쓰지 않는다.** DB 대기는 시험이 저장 함수에 건 문으로 흉내 낸다.
"""

from __future__ import annotations

import threading
import time

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, cloud  # noqa: F401
from rpi.tests.test_cook_done_card import _reset

pytest.importorskip("thinqconnect")

#: 정지 호출 지연 상한(초) — DB 쓰기 대기와 무관하게 이 안에 로컬 컨트롤러 ``request_stop``이 불려야 한다.
STOP_CALL_BOUND_S = 0.5


def _engine():
    from rpi.routines.wiring import get_auto_rule_engine

    return get_auto_rule_engine()


def _frame():
    from rpi.tests.test_auto_rules import _frame as frame

    return frame()


def test_stop_reaches_request_stop_while_a_rule_save_waits_on_the_db_and_a_guard_waits_on_the_store(
        monkeypatch, tmp_path, cloud):
    """H-N2: ① 자동 실행이 판단을 마치고 제출 직전 ② 다른 요청(다시 허용)의 규칙 저장이 DB 쓰기에서 멈춤 ③ 자동 실행의
    시작 게이트가 서비스 잠금 안에서 규칙을 읽음 ④ 전체 정지 — 로컬 ``request_stop``이 DB 대기와 무관하게
    ``STOP_CALL_BOUND_S`` 안에 불린다(그동안 DB 쓰기는 계속 멈춰 있다)."""
    from rpi.api import deps

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    go, release = threading.Event(), threading.Event()
    threads: list[threading.Thread] = []
    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        engine = _engine()
        service = deps.get_service()
        rule = api.get("/routines/auto-rules").json()[0]

        # ① 자동 실행을 판단 뒤·제출 직전에 세운다.
        at_submit = threading.Event()
        original_submit = service.submit_approved

        def held_submit(*args, **kwargs):
            if str(kwargs.get("scenario_id") or "").startswith("auto:"):
                at_submit.set()
                assert go.wait(10)
            return original_submit(*args, **kwargs)

        monkeypatch.setattr(service, "submit_approved", held_submit)
        threads.append(threading.Thread(target=lambda: deps.receive_appliance_done(_frame())))
        threads[-1].start()
        assert at_submit.wait(10), "자동 실행이 제출까지 오지 않았다"

        # ② 다시 허용의 규칙 저장이 DB 쓰기에서 멈춘다.
        entered = threading.Event()

        def stuck_db_write(_value):
            entered.set()
            assert release.wait(15)

        engine.store._save_fn = stuck_db_write
        results: dict = {}
        threads.append(threading.Thread(target=lambda: results.setdefault("reallow", api.post(
            f"/routines/auto-rules/{rule['id']}/enable",
            json={"enabled": True, "fingerprint": rule["fingerprint"]}))))
        threads[-1].start()
        assert entered.wait(10), "규칙 저장이 DB 쓰기까지 오지 않았다"

        # ③ 자동 실행을 놓아 시작 게이트(서비스 잠금 안)가 규칙을 읽게 한다.
        read_in_gate = threading.Event()
        original_get = engine.store.get

        def watched_get(rule_id):
            read_in_gate.set()
            return original_get(rule_id)

        monkeypatch.setattr(engine.store, "get", watched_get)
        go.set()
        assert read_in_gate.wait(5)
        time.sleep(0.1)

        # ④ 전체 정지 — 로컬 컨트롤러의 request_stop 호출 시각을 잰다.
        local = service._controller
        called = threading.Event()
        stamp: dict = {}
        original_request_stop = local.request_stop

        def timed_request_stop(*args, **kwargs):
            stamp.setdefault("at", time.perf_counter())
            called.set()
            return original_request_stop(*args, **kwargs)

        monkeypatch.setattr(local, "request_stop", timed_request_stop)
        started = time.perf_counter()
        threads.append(threading.Thread(target=lambda: results.setdefault("stop", api.post("/stop"))))
        threads[-1].start()
        reached = called.wait(3)
        delay = stamp["at"] - started if reached else None
        print(f"\n[H-N2] request_stop 호출 지연 {"없음" if delay is None else f"{delay * 1000:.2f}"} ms "
              "(DB 쓰기는 멈춘 채)")
        assert reached and delay < STOP_CALL_BOUND_S, f"정지 호출이 DB 대기를 기다렸다: {delay}"
        assert not release.is_set()  # DB 쓰기는 아직 멈춰 있다
    finally:
        go.set()
        release.set()
        for t in threads:
            t.join(15)
        _reset()
    assert results["stop"].status_code == 200


# ── M-N3: /stop 응답은 규칙 끄기의 DB 쓰기를 기다리지 않는다 · 재시작 뒤 철회 보장 ─────────────────────────

#: /stop HTTP 응답 상한(초) — 규칙 DB 쓰기가 멈춰 있어도 이 안에 돌아와야 한다(폰 제한 8초보다 훨씬 짧게).
STOP_RESPONSE_BOUND_S = 1.5


def _stuck_rule_writes(engine, release: threading.Event, written: list) -> threading.Event:
    """규칙 저장의 DB 쓰기를 시험이 놓을 때까지 붙잡는다. 놓이면 쓴 값을 ``written``에 남긴다(DB에는 쓰지 않음)."""
    entered = threading.Event()

    def stuck(value):
        entered.set()
        assert release.wait(20)
        written.append(value)

    engine.store._save_fn = stuck
    return entered


def _post_stop_in_thread(api, results: dict) -> threading.Thread:
    thread = threading.Thread(target=lambda: results.setdefault("stop", api.post("/stop")))
    thread.start()
    return thread


def test_stop_response_does_not_wait_for_the_rule_off_db_write(monkeypatch, tmp_path, cloud):
    """M-N3: 규칙 끄기의 DB 쓰기가 멈춰 있어도 /stop은 상한 안에 200 — 규칙은 메모리에서 바로 꺼지고(목록·판정),
    DB 쓰기는 놓인 뒤 뒤에서 '꺼짐'으로 끝난다."""
    import json

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    release, written, results = threading.Event(), [], {}
    stop_thread = None
    try:
        api = TestClient(app)
        _allow(api)
        engine = _engine()
        _stuck_rule_writes(engine, release, written)
        started = time.perf_counter()
        stop_thread = _post_stop_in_thread(api, results)
        stop_thread.join(STOP_RESPONSE_BOUND_S + 3)
        elapsed = time.perf_counter() - started
        print(f"\n[M-N3] /stop 응답 {elapsed * 1000:.1f} ms (규칙 DB 쓰기는 멈춘 채)")
        assert "stop" in results and elapsed < STOP_RESPONSE_BOUND_S, f"/stop이 규칙 DB 쓰기를 기다렸다: {elapsed}"
        assert results["stop"].status_code == 200
        assert not release.is_set()
        rule = api.get("/routines/auto-rules").json()[0]
        assert rule["enabled"] is False  # 메모리에서 바로 꺼짐
        release.set()
        deadline = time.monotonic() + 5
        while not written and time.monotonic() < deadline:
            time.sleep(0.02)
        assert written and all(r["enabled"] is False for r in json.loads(written[-1]))
    finally:
        release.set()
        if stop_thread is not None:
            stop_thread.join(10)
        _reset()


def _db_env(monkeypatch, tmp_path, cloud):
    from rpi.api import deps

    _env(monkeypatch, tmp_path, cloud)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    deps.get_db.cache_clear()
    _reset()


def _restart_as_a_new_process(monkeypatch):
    """프로세스 재시작 흉내 — 메모리 상태를 버리고 같은 DB 파일을 다시 열며, 프로세스 세션 표시를 새로 한다."""
    from uuid import uuid4

    from rpi.api import deps
    from rpi.routines import auto_rules

    _reset()
    deps.get_db.cache_clear()
    monkeypatch.setattr(auto_rules, "PROCESS_SESSION", uuid4().hex)


def test_restart_after_a_stop_whose_rule_write_never_finished_starts_with_the_rule_off(monkeypatch, tmp_path, cloud):
    """M-N3 내구성: 정지의 규칙 끄기가 DB에 닿기 전에 프로세스가 죽었다(쓰기 멈춤 → 강제 종료). DB에는 '켜짐'이 남았지만
    다시 뜬 서버는 그 규칙을 끈 채 시작하고(이유: 정상 종료 아님) 다음 가열 종료에 제어를 보내지 않는다."""
    from rpi.tests.test_cook_done_card import _inject

    _db_env(monkeypatch, tmp_path, cloud)
    from rpi.main import app

    release, written, results = threading.Event(), [], {}
    stop_thread = None
    try:
        api = TestClient(app)
        _allow(api)
        engine = _engine()
        entered = _stuck_rule_writes(engine, release, written)
        stop_thread = _post_stop_in_thread(api, results)
        assert entered.wait(5), "정지의 규칙 끄기가 DB 쓰기까지 오지 않았다"
        _restart_as_a_new_process(monkeypatch)  # 쓰기가 끝나기 전에 '죽었다'
        api = TestClient(app)
        rule = api.get("/routines/auto-rules").json()[0]
        assert rule["enabled"] is False
        assert "정상 종료되지 않아" in (rule["disabled_reason"] or "")
        _set_low(api)
        before = len(cloud.controls())
        _inject(api, inputs=("power",))
        time.sleep(0.5)
        assert len(cloud.controls()) == before
        assert [r for r in api.get("/routines/auto-rules/runs").json() if r["outcome"] == "sent"] == []
    finally:
        release.set()
        if stop_thread is not None:
            stop_thread.join(10)
        _reset()
        from rpi.api import deps

        deps.get_db.cache_clear()


def test_clean_shutdown_keeps_an_allowed_rule_and_a_stuck_final_write_does_not(monkeypatch, tmp_path, cloud):
    """M-N3 내구성: 깨끗한 종료(남은 쓰기를 마치고 세션 표시를 닫음)면 허용한 규칙이 재시작 뒤에도 켜져 있다.
    종료 때 규칙 쓰기가 멈춰 있으면 표시를 닫지 않아 다음 기동이 켜진 규칙을 끈다."""
    from rpi.routines.wiring import close_auto_rules_if_any

    _db_env(monkeypatch, tmp_path, cloud)
    from rpi.main import app

    release, written = threading.Event(), []
    try:
        api = TestClient(app)
        _allow(api)
        assert close_auto_rules_if_any() is True
        _restart_as_a_new_process(monkeypatch)
        api = TestClient(app)
        rule = api.get("/routines/auto-rules").json()[0]
        assert rule["enabled"] is True  # 깨끗한 종료 뒤에는 그대로

        engine = _engine()
        engine.store.put(engine.store.get(rule["id"]))  # 쓰지 않은 변경 하나
        _stuck_rule_writes(engine, release, written)
        assert close_auto_rules_if_any(0.3) is False  # 쓰기가 멈춰 표시를 닫지 못함
        _restart_as_a_new_process(monkeypatch)
        api = TestClient(app)
        rule = api.get("/routines/auto-rules").json()[0]
        assert rule["enabled"] is False and "정상 종료되지 않아" in rule["disabled_reason"]
    finally:
        release.set()
        _reset()
        from rpi.api import deps

        deps.get_db.cache_clear()
