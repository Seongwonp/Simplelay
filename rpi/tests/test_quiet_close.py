"""조용한 시간·잠시 쉬기 마감 확인(2026-10-14, 4·5번 마감 — 시험 보강).

A1 조용한 시간 직전에 만든 제안이 시간이 시작된 뒤 뒤늦게 나오지 않는다(시계가 넘어가는 경우). 사용자가 직접 찾아
   실행하는 경로(루틴 '지금 실행')는 그 시간에도 카드가 나온다 — 둘을 나눠 본다.
A2 자동 실행 전송권 경계: 최종 재판정(``dispatch_guard``)이 통과로 돌아온 뒤, POST 전에 조용한 시간이 시작되거나 잠시
   쉬기를 켜면 아직 보내지 않은 명령은 보내지 않는다(모의 클라우드 POST 0건).
A3 조용한 시간에 건너뛴 사건을 서버 재시작 뒤 다시 받으면, 시간이 끝났어도 재실행하지 않는다(처리 키 DB 영속).
A5 잠시 쉬기는 서버 메모리에만 있다 — 업데이트(재시작) 전에 켜 둔 잠시 쉬기는 재시작 뒤 남지 않으므로, '자동 실행도
   쉰다'는 새 의미는 업데이트 뒤 새로 켠 잠시 쉬기에만 적용된다.

**실제 ThinQ 클라우드·실가전·실제 CT 판정은 쓰지 않는다**(모의 ThinQ·저장소 안 모의 클라우드·리허설 주입 사건).
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.services.quiet_hours import SKIP_REASON
from rpi.tests.test_cook_done_card import _env as _mock_env
from rpi.tests.test_cook_done_card import _reset

KST = timezone(timedelta(hours=9))


class _Clock:
    def __init__(self, now: datetime) -> None:
        self.value = now

    def now(self) -> datetime:
        return self.value


def _clear():
    _reset()
    deps.get_quiet_hours.cache_clear()


# ── A1 직전에 만든 제안 — 시각이 넘어간 뒤 목록·승인·끝난 뒤 모두 없음 / 직접 실행 경로는 허용 ─────────


@pytest.fixture()
def clocked(monkeypatch):
    _mock_env(monkeypatch, "mock")
    clock = _Clock(datetime(2026, 10, 14, 21, 59, 0, tzinfo=KST))
    monkeypatch.setattr(deps, "_clock", clock)
    _clear()
    from rpi.main import app

    yield TestClient(app), clock
    _clear()


def test_card_made_just_before_quiet_starts_does_not_surface_after_the_start(clocked):
    api, clock = clocked
    assert api.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"}).status_code == 200
    assert api.get("/quiet-hours").json()["active"] is False
    card = api.post("/demo/suggest", json={}).json()  # 21:59 — 아직 조용한 시간 전
    assert [s["id"] for s in api.get("/suggestions").json()] == [card["id"]]

    clock.value = datetime(2026, 10, 14, 22, 0, 5, tzinfo=KST)  # 시간대 시작 직후
    assert api.get("/health").json()["quiet"]["active"] is True
    assert api.get("/suggestions").json() == []  # 폰(5초 폴링)·키오스크(2초 폴링)가 받을 카드가 없다
    assert api.post(f"/suggestions/{card['id']}/approve").status_code in (404, 409)

    clock.value = datetime(2026, 10, 15, 7, 0, 30, tzinfo=KST)  # 끝난 뒤에도 쌓아 두었다 내보내지 않는다
    assert api.get("/quiet-hours").json()["active"] is False
    assert api.get("/suggestions").json() == []


def test_user_found_routine_run_now_still_makes_its_card_after_the_start(clocked):
    """대조: 사용자가 루틴 탭·키오스크 내 가전에서 직접 찾아 '지금 실행'을 누른 카드는 조용한 시간에도 나온다."""
    api, clock = clocked
    made = api.post("/routines", json={
        "name": "공기 강", "trigger": {"kind": "manual"},
        "steps": [{"kind": "thinq_command", "appliance_id": "air_purifier", "action": "set_wind_strength",
                   "args": {"wind_strength": "HIGH"}}]})
    assert made.status_code == 201, made.text
    assert api.put("/quiet-hours", json={"enabled": True, "start": "22:00", "end": "07:00"}).status_code == 200
    clock.value = datetime(2026, 10, 14, 22, 0, 5, tzinfo=KST)
    res = api.post(f"/routines/{made.json()['id']}/trigger")
    assert res.status_code == 200, res.text
    card_id = res.json()["suggestion"]["id"]
    assert [s["id"] for s in api.get("/suggestions").json()] == [card_id]


# ── A2·A3 — 모의 클라우드(공식 SDK 경로) ─────────────────────────────────────────────


pytest.importorskip("thinqconnect")

from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, _wait_run, cloud  # noqa: E402,F401


def _frame():
    from rpi.tests.test_auto_rules import _frame as frame

    return frame()


def _quiet_on(api, how: str) -> None:
    if how == "schedule":
        now = datetime.now().astimezone()
        body = {"enabled": True, "start": (now - timedelta(hours=2)).strftime("%H:%M"),
                "end": (now + timedelta(hours=2)).strftime("%H:%M")}
        assert api.put("/quiet-hours", json=body).status_code == 200
    else:
        assert api.post("/dnd", json={"duration_minutes": 60}).status_code == 200


@pytest.mark.parametrize("how", ["schedule", "pause"])
def test_quiet_or_pause_after_the_final_guard_but_before_the_post_sends_nothing(monkeypatch, tmp_path, cloud, how):
    """A2: 최종 재판정이 통과로 돌아온 직후 조용한 시간 시작(또는 잠시 쉬기 켜기) → 전송권 확인(commit)에서 걸려 POST 0건."""
    from rpi.services.thinq.controller import ThinqController
    from rpi.tests.test_cook_done_card import _inject

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        original_execute = ThinqController.execute_command
        switched = []

        def execute(controller, command, *, dispatch_guard=None):
            if dispatch_guard is None:
                return original_execute(controller, command)

            def guard_then_quiet(binding=None):
                out = dispatch_guard(binding)
                if binding is not None and not switched:
                    _quiet_on(api, how)  # 최종 재판정 반환 뒤, POST 전
                    switched.append(how)
                return out

            return original_execute(controller, command, dispatch_guard=guard_then_quiet)

        monkeypatch.setattr(ThinqController, "execute_command", execute)
        _inject(api, inputs=("power",))
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        time.sleep(0.3)
        assert switched == [how]
        assert len(cloud.controls()) == before, cloud.controls()[before:]
        assert run["receipt"] == "not_dispatched" and run["outcome"] == "blocked", run
        assert SKIP_REASON in " / ".join([run.get("reason") or "", *run.get("notices", [])]), run
    finally:
        _reset()


def test_event_skipped_in_quiet_is_not_rerun_after_a_restart_even_when_quiet_has_ended(monkeypatch, tmp_path, cloud):
    """A3: 조용한 시간에 건너뜀 → 서버 재시작(같은 DB) → 조용한 시간 끝 → 같은 사건 재수신 = duplicate, POST 0건."""
    _env(monkeypatch, tmp_path, cloud)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        _quiet_on(api, "schedule")
        frame = _frame()
        deps.receive_appliance_done(dict(frame))
        run = _wait_run(api, lambda r: r["outcome"] == "blocked")
        assert run["reason"] == SKIP_REASON
        skipped_at = len(cloud.controls())

        _reset()  # 재시작: 메모리를 모두 버리고 같은 DB 파일에서 다시 연다
        deps.get_db.cache_clear()
        api = TestClient(app)
        assert api.get("/quiet-hours").json()["active"] is True  # 설정도 남는다
        assert api.put("/quiet-hours", json={"enabled": False}).status_code == 200  # 조용한 시간 끝
        assert api.get("/routines/auto-rules").json()[0]["enabled"] is True
        deps.receive_appliance_done(dict(frame))  # RPi4 재연결 뒤 같은 사건 재수신
        _wait_run(api, lambda r: r["outcome"] == "duplicate")
        time.sleep(0.5)
        assert len(cloud.controls()) == skipped_at
        assert [r for r in api.get("/routines/auto-rules/runs").json() if r["outcome"] == "sent"] == []
    finally:
        _reset()
        deps.get_db.cache_clear()


# ── A5 잠시 쉬기 적용 방식 — 업데이트(재시작) 전에 켠 잠시 쉬기는 남지 않는다 ───────────────────


def test_pause_set_before_an_update_does_not_survive_the_restart(monkeypatch, tmp_path):
    """잠시 쉬기는 서버 메모리에만 있다(DB 없음). 업데이트 배포는 서버를 다시 띄우므로 옛 의미('제안만 쉼')로 켠 잠시 쉬기가
    새 의미('자동 실행도 쉼')로 조용히 이어지지 않는다 — 새 의미는 업데이트 뒤 새로 켤 때, 그 화면 문구와 함께 적용된다.
    매일 조용한 시간 설정은 DB에 남는다(대조)."""
    _mock_env(monkeypatch, "mock")
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    deps.get_db.cache_clear()
    _clear()
    from rpi.main import app

    try:
        api = TestClient(app)
        assert api.post("/dnd", json={"duration_minutes": 120}).status_code == 200
        assert api.put("/quiet-hours", json={"enabled": True, "start": "01:00", "end": "01:30"}).status_code == 200
        quiet = api.get("/health").json()["quiet"]
        assert quiet["reason"] == "pause" and quiet["pause_until"]

        _clear()  # 업데이트 배포 = 서버 재시작(같은 DB)
        deps.get_db.cache_clear()
        api = TestClient(app)
        health = api.get("/health").json()
        assert health["dnd_until"] is None
        assert health["quiet"]["pause_until"] is None and health["quiet"]["reason"] != "pause"
        body = api.get("/quiet-hours").json()
        assert (body["enabled"], body["start"], body["end"]) == (True, "01:00", "01:30")
    finally:
        _clear()
        deps.get_db.cache_clear()
