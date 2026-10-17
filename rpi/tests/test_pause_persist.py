"""잠시 쉬기 끝 시각·적용 범위 영속(2026-10-14 보안 수리 뒤 마감 2번).

세 칸으로 나눠 본다.

- **기존 설정 이전:** 업데이트 전 서버(배포본 ``568f995``)는 잠시 쉬기를 메모리에만 두고 공개 ``/health``의
  ``dnd_until``으로만 알린다. 배포 스크립트가 그 값을 읽어 ``SIMPLELAY_PAUSE_CARRYOVER_UNTIL``로 넘기면, 새 서버는
  **확인 가능한 값일 때만**(오프셋 붙은 시각·아직 안 지남·최대 쉬기 길이 안) 남은 시간 동안 **옛 범위(새 제안만 쉼)**로
  이어받는다 — 자동 실행은 막지 않는다. 같은 값은 한 번만 쓴다(컨테이너 재시작에 env가 남아도 다시 켜지 않는다).
- **새 설정 저장:** 업데이트 뒤 켠 잠시 쉬기는 끝 시각과 새 범위(새 제안 + 아직 시작하지 않은 자동 실행)를 DB에 함께 남긴다.
- **재시작 후 복원:** 재시작 뒤에도 표시한 끝 시각까지 같은 범위로 유지되고, 끝 시각이 지나면 풀린다.

실가전·실제 CT 판정은 쓰지 않는다(모의 ThinQ·저장소 안 모의 클라우드·리허설 주입 사건).
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.services.quiet_hours import SKIP_REASON
from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, cloud  # noqa: F401
from rpi.tests.test_cook_done_card import _inject, _reset

KST = timezone(timedelta(hours=9))
CARRY = "SIMPLELAY_PAUSE_CARRYOVER_UNTIL"


class _Clock:
    def __init__(self, now: datetime) -> None:
        self.value = now

    def now(self) -> datetime:
        return self.value


def _clear():
    _reset()
    deps.get_quiet_hours.cache_clear()


def _restart():
    """업데이트 배포·전원 재시작 = 메모리를 모두 버리고 같은 DB 파일에서 다시 연다."""
    _clear()
    deps.get_db.cache_clear()
    from rpi.main import app

    return TestClient(app)


@pytest.fixture()
def db_env(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud)
    monkeypatch.delenv(CARRY, raising=False)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    api = _restart()
    yield api
    _clear()
    deps.get_db.cache_clear()


def _pause(api):
    health = api.get("/health/detail").json()
    return health["dnd_until"], health.get("dnd_scope"), health["quiet"]


def _runs(api):
    return api.get("/routines/auto-rules/runs").json()


def _event_then_run(api, cloud):
    """허용 규칙이 있는 상태에서 가열 종료 사건 하나 → (새 자동 실행 기록, 모의 클라우드 POST 수 변화)."""
    n, before = len(_runs(api)), len(cloud.controls())
    _inject(api, inputs=("power",))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        runs = _runs(api)
        if len(runs) > n and runs[0]["outcome"] in ("sent", "blocked"):
            time.sleep(0.3)
            return runs[0], len(cloud.controls()) - before
        time.sleep(0.05)
    raise AssertionError(_runs(api))


# ── 기존 설정 이전 ────────────────────────────────────────────────────────────


def test_carried_over_old_pause_keeps_the_old_scope_and_does_not_block_auto_run(db_env, monkeypatch, cloud):
    api = db_env
    _allow(api)
    _set_low(api)
    until = (datetime.now().astimezone() + timedelta(minutes=50)).replace(microsecond=0)
    monkeypatch.setenv(CARRY, until.isoformat())  # 배포 스크립트가 옛 서버 /health에서 읽어 넘긴 값
    api = _restart()

    dnd_until, scope, quiet = _pause(api)
    assert datetime.fromisoformat(dnd_until) == until
    assert scope == "suggestions_only"
    assert quiet["reason"] == "pause" and quiet["pause_scope"] == "suggestions_only"
    assert "자동으로 할 일은 그대로" in quiet["scope"]
    assert api.get("/suggestions").json() == []  # 새 제안은 쉰다(옛 범위)

    run, posted = _event_then_run(api, cloud)
    assert run["outcome"] == "sent" and posted >= 1, run  # 옛 범위는 자동 실행을 막지 않는다
    assert api.get("/suggestions").json() == []


def test_carried_over_pause_is_used_once_and_survives_a_restart(db_env, monkeypatch):
    until = (datetime.now().astimezone() + timedelta(minutes=50)).replace(microsecond=0)
    monkeypatch.setenv(CARRY, until.isoformat())
    api = _restart()
    assert _pause(api)[1] == "suggestions_only"
    api = _restart()  # 컨테이너 재시작(env 그대로) — 옛 범위 그대로 이어진다
    dnd_until, scope, _ = _pause(api)
    assert datetime.fromisoformat(dnd_until) == until and scope == "suggestions_only"
    assert api.delete("/dnd").status_code == 200  # 사용자가 끔
    api = _restart()  # env에 같은 값이 남아 있어도 다시 켜지 않는다
    assert _pause(api)[0] is None


@pytest.mark.parametrize("raw", [
    "", "garbage", "2026-10-14T23:30:00",  # 오프셋 없는 시각은 어느 시각인지 확인할 수 없다
    "PAST", "TOO_FAR",
])
def test_unverifiable_carryover_values_are_not_used(db_env, monkeypatch, raw):
    now = datetime.now().astimezone()
    value = {"PAST": (now - timedelta(minutes=1)).isoformat(),
             "TOO_FAR": (now + timedelta(days=2)).isoformat()}.get(raw, raw)
    monkeypatch.setenv(CARRY, value)
    api = _restart()
    assert _pause(api)[0] is None


def test_carryover_does_not_replace_a_pause_set_after_the_update(db_env, monkeypatch):
    api = db_env
    assert api.post("/dnd", json={"duration_minutes": 120}).status_code == 200
    mine, scope, _ = _pause(api)
    assert scope == "suggestions_and_auto"
    monkeypatch.setenv(CARRY, (datetime.now().astimezone() + timedelta(minutes=30)).isoformat())
    api = _restart()
    assert _pause(api)[:2] == (mine, "suggestions_and_auto")


# ── 새 설정 저장 ──────────────────────────────────────────────────────────────


def test_new_pause_is_saved_with_its_end_time_and_new_scope(db_env, cloud):
    api = db_env
    _allow(api)
    _set_low(api)
    assert api.post("/dnd", json={"duration_minutes": 60}).status_code == 200
    dnd_until, scope, quiet = _pause(api)
    stored = json.loads(deps.get_db().load_setting("suggestion_pause"))
    assert stored["until"] == dnd_until and stored["scope"] == "suggestions_and_auto" == scope
    assert quiet["pause_scope"] == "suggestions_and_auto"

    run, posted = _event_then_run(api, cloud)
    assert run["outcome"] == "blocked" and run["reason"] == SKIP_REASON, run
    assert posted == 0

    assert api.delete("/dnd").status_code == 200
    stored = json.loads(deps.get_db().load_setting("suggestion_pause"))
    assert stored["until"] is None


# ── 재시작 후 복원 ────────────────────────────────────────────────────────────


def test_new_pause_is_restored_after_a_restart_and_still_blocks_auto_run(db_env, cloud):
    api = db_env
    _allow(api)
    _set_low(api)
    assert api.post("/dnd", json={"duration_minutes": 120}).status_code == 200
    before_restart = _pause(api)[:2]
    api = _restart()
    assert _pause(api)[:2] == before_restart
    assert api.get("/routines/auto-rules").json()[0]["enabled"] is True
    run, posted = _event_then_run(api, cloud)
    assert run["outcome"] == "blocked" and run["reason"] == SKIP_REASON, run
    assert posted == 0


def test_restored_pause_is_released_at_its_end_time(db_env, monkeypatch):
    clock = _Clock(datetime(2026, 10, 14, 22, 0, tzinfo=KST))
    monkeypatch.setattr(deps, "_clock", clock)
    api = _restart()
    assert api.post("/dnd", json={"duration_minutes": 90}).status_code == 200  # 23:30까지
    clock.value = datetime(2026, 10, 14, 23, 0, tzinfo=KST)
    api = _restart()
    dnd_until, scope, quiet = _pause(api)
    assert datetime.fromisoformat(dnd_until) == datetime(2026, 10, 14, 23, 30, tzinfo=KST)
    assert scope == "suggestions_and_auto" and quiet["active"] is True
    assert deps.get_suggestion_service().is_auto_run_quiet() is True
    clock.value = datetime(2026, 10, 14, 23, 30, tzinfo=KST)
    dnd_until, scope, quiet = _pause(api)
    assert dnd_until is None and scope is None and quiet["active"] is False
    assert deps.get_suggestion_service().is_auto_run_quiet() is False
    api = _restart()  # 끝난 뒤 재시작해도 다시 켜지지 않는다
    assert _pause(api)[0] is None


def test_old_server_utc_z_value_is_carried_over(db_env, monkeypatch):
    """보드의 업데이트 전 서버(568f995)가 실제로 내는 꼴 — UTC 'Z'·마이크로초(2026-10-14 RPi5에서 읽음)."""
    until = (datetime.now(timezone.utc) + timedelta(minutes=50)).replace(microsecond=620005)
    raw = until.isoformat().replace("+00:00", "Z")
    assert raw.endswith("Z")
    monkeypatch.setenv(CARRY, raw)
    api = _restart()
    dnd_until, scope, _ = _pause(api)
    assert datetime.fromisoformat(dnd_until) == until and scope == "suggestions_only"
