"""끝-끝: 모의 조리 완료 사건 → 자동 실행 허용 규칙 → 공식 SDK → 모의 ThinQ 클라우드 공기청정기 → 상태 재조회 → 기록.

``SIMPLELAY_THINQ_MODE=fake_cloud``(저장소 안 모의 클라우드 127.0.0.1). **실제 ThinQ 클라우드·실가전·실제 CT 판정은
한 번도 쓰지 않는다** — 완료 사건은 리허설 주입(source=injected)이고, 결과의 실행 환경은 mock이다. 마지막 시험은
real 조립 경로에서 모의·주입 사건이 공기청정기를 움직이지 않는지(서버 강제)만 본다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_cook_done_card import _cards, _inject, _reset, _wait_done

pytest.importorskip("thinqconnect")

from rpi.tools.fake_thinq_cloud import FakeThinqCloud  # noqa: E402

SECRET_PAT = "pat-SECRET-auto-rule-e2e-77d1"


def _env(monkeypatch, tmp_path, cloud, mode="fake_cloud"):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_V2_SCENARIOS", "SIMPLELAY_ACT_MODE",
                 "SIMPLELAY_LOCAL_APPLIANCES", "SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE",
                 "SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_THINQ_MODE", mode)
    if mode == "fake_cloud":
        monkeypatch.setenv("SIMPLELAY_THINQ_FAKE_CLOUD_URL", cloud.base_url)
    monkeypatch.setenv("SIMPLELAY_THINQ_PAT", SECRET_PAT)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    monkeypatch.setenv("SIMPLELAY_THINQ_CONFIRM_SECONDS", "2")
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", cloud.device_id("air_purifier"))


@pytest.fixture()
def cloud():
    fake = FakeThinqCloud()
    fake.start()
    yield fake
    fake.stop()


def _allow(api):
    _inject(api, inputs=("power",))
    card = _cards(api)[0]
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow",
                   json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"]})
    assert res.status_code == 200, res.text
    status = _wait_done(api, res.json()["job_id"], timeout=10)
    return card, status


def _set_low(api):
    res = api.post("/thinq/command", json={"appliance_id": "air_purifier", "action": "set_wind_strength",
                                           "args": {"wind_strength": "LOW"}})
    assert res.status_code == 200, res.text
    assert _wait_done(api, res.json()["job_id"], timeout=10)["last_status"] == "succeeded"


def _wait_run(api, pred, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        runs = api.get("/routines/auto-rules/runs").json()
        hit = next((r for r in runs if pred(r)), None)
        if hit is not None:
            return hit
        time.sleep(0.05)
    raise AssertionError(api.get("/routines/auto-rules/runs").json())


def test_mock_cook_done_drives_the_mock_cloud_purifier_end_to_end(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        device = cloud.device_id("air_purifier")
        card, first = _allow(api)  # 장면 ②: 이번에 실행 + 다음부터 자동으로
        assert card["auto_rule_offer"]["action_text"] == "공기청정기(모의 클라우드) 바람을 세게 해요"
        assert first["last_confirmation"] == "state_confirmed"
        _set_low(api)  # 장면 ③ 준비: 약풍으로 되돌림
        assert cloud.state(device)["airFlow"]["windStrength"] == "LOW"

        _inject(api, inputs=("power",))  # 두 번째 조리 완료(모의) — 추가 승인 없음
        run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
        assert (run["status"], run["receipt"], run["confirmation"], run["execution_mode"]) == (
            "succeeded", "accepted", "state_confirmed", "mock")
        assert run["event_source"] == "injected"
        notices = " / ".join(run["notices"])
        assert "멈춘 것 같아요" in notices and "연습으로 넣은 신호예요" in notices
        assert "강풍으로 바꿨어요." in notices and "연습이라 실제 가전은 그대로예요" in notices

        controls = cloud.controls()
        assert [c["body"] for c in controls] == [{"airFlow": {"windStrength": "HIGH"}},
                                                 {"airFlow": {"windStrength": "LOW"}},
                                                 {"airFlow": {"windStrength": "HIGH"}}]
        after = [r for r in cloud.requests() if r["at"] >= controls[-1]["at"]]
        assert any(r["path"] == f"/devices/{device}/state" for r in after[1:])  # 보낸 뒤 상태 재조회
        assert cloud.state(device)["airFlow"]["windStrength"] == "HIGH"

        history = api.get("/history").json()[0]
        assert (history["route"], history["confirmation"], history["execution_mode"]) == (
            "thinq", "state_confirmed", "mock")
        assert history["purpose"].startswith("자동 실행")
        assert _cards(api) == []
        care = " / ".join(e["message"] for e in api.get("/care-events").json())
        assert "강풍으로 바꿨어요" in care and "깨끗" not in care
        assert SECRET_PAT not in str(run) and device not in str(api.get("/routines/auto-rules").json())
    finally:
        _reset()


def _frame():
    from rpi.tests.test_auto_rules import _frame as frame

    return frame()


def test_same_event_arriving_twice_at_once_sends_one_cloud_control(monkeypatch, tmp_path, cloud):
    """A3(10/14): 같은 사건이 동시에 두 번 도착(재연결·중복 알림) → 모의 클라우드 제어 요청은 1회."""
    import threading

    from rpi.api import deps

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        frame = _frame()
        gate = threading.Barrier(2)

        def deliver():
            gate.wait()
            deps.receive_appliance_done(dict(frame))

        threads = [threading.Thread(target=deliver) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(5)
        _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
        time.sleep(0.5)
        assert len(cloud.controls()) == before + 1
        outcomes = sorted(r["outcome"] for r in api.get("/routines/auto-rules/runs").json())
        assert outcomes == ["duplicate", "sent"]  # 둘째는 '실행 중이라 못 보냄'이 아니라 같은 사건으로 걸렀다
    finally:
        _reset()


def test_processed_event_is_not_rerun_after_a_server_restart(monkeypatch, tmp_path, cloud):
    """A4(10/14): 서버 재시작·재연결 뒤 이전 사건을 다시 받아도 실행하지 않는다 — 처리한 사건 키가 DB에 남는다."""
    from rpi.api import deps

    _env(monkeypatch, tmp_path, cloud)
    monkeypatch.setenv("SIMPLELAY_DB_PATH", str(tmp_path / "simplelay.db"))
    deps.get_db.cache_clear()
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        frame = _frame()
        deps.receive_appliance_done(dict(frame))
        _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
        after_first = len(cloud.controls())

        # 재시작: 메모리 상태를 모두 버리고 같은 DB 파일에서 다시 연다.
        _reset()
        deps.get_db.cache_clear()
        api = TestClient(app)
        assert api.get("/routines/auto-rules").json()[0]["enabled"] is True  # 규칙은 남아 있다
        _set_low(api)
        before = len(cloud.controls())
        deps.receive_appliance_done(dict(frame))  # RPi4 재연결 뒤 같은 사건 재수신
        _wait_run(api, lambda r: r["outcome"] == "duplicate")
        time.sleep(0.5)
        assert len(cloud.controls()) == before
        assert before == after_first + 1  # (되돌린 약풍 1건만)

        deps.receive_appliance_done(_frame())  # 새 사건은 그대로 자동 실행
        _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
        assert len(cloud.controls()) == before + 1
    finally:
        _reset()
        deps.get_db.cache_clear()


def test_real_assembly_never_moves_the_purifier_on_an_injected_event(monkeypatch, tmp_path):
    """real 조립 경로(시험 안에서만 SDK 주소를 모의 클라우드로) — 주입 사건은 실가전 대상을 움직이지 않는다."""
    from rpi.services.thinq import sdk_client

    fake = FakeThinqCloud(token=SECRET_PAT)
    fake.start()
    original = sdk_client.SdkThinqClient.__init__

    def redirected(self, **kw):
        assert kw.get("base_url") is None
        kw["base_url"] = fake.base_url
        original(self, **kw)

    monkeypatch.setattr(sdk_client.SdkThinqClient, "__init__", redirected)
    try:
        _env(monkeypatch, tmp_path, fake, mode="real")
        _reset()
        from rpi.main import app

        api = TestClient(app)
        _allow(api)  # 이번 실행은 사용자가 직접 승인한 것
        _set_low(api)
        before = len(fake.controls())
        _inject(api, inputs=("power",))
        run = _wait_run(api, lambda r: r["outcome"] == "blocked")
        assert "실제 공기청정기" in run["reason"]
        time.sleep(0.3)
        assert len(fake.controls()) == before
    finally:
        fake.stop()
        _reset()
