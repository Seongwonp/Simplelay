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
