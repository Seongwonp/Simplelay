"""자동 실행 경계(3차 평가 2026-10-14) — 실제 API·ThinQ controller·공식 SDK·저장소 안 모의 클라우드 배선.

H1: 자동 실행의 마지막 검사가 controller의 프로필·상태 조회(네트워크 대기)보다 앞서 있었다. 조회를 기다리는 동안
    규칙을 끄거나 바꾸거나 지우면, 조회가 끝난 뒤 **전송 직전**에 다시 판정해 보내지 않아야 한다(모의 클라우드 POST 0건).
    정지는 그 네트워크 대기를 기다리지 않는다.

**실제 ThinQ 클라우드·실가전·실제 CT 판정은 쓰지 않는다.** 네트워크 대기는 시험이 SDK 호출 앞에 건 문으로 흉내 낸다.
"""

from __future__ import annotations

import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient

from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, _wait_run, cloud  # noqa: F401
from rpi.tests.test_cook_done_card import _inject, _reset

pytest.importorskip("thinqconnect")


class _NetworkGate:
    """ThinQ controller가 보내기 전에 하는 SDK 조회(``method``) 하나를 문 앞에 세운다(시험이 열 때까지)."""

    def __init__(self, monkeypatch, method: str) -> None:
        from rpi.services.thinq import sdk_client

        self.entered = threading.Event()
        self.release = threading.Event()
        self.armed = False
        original = getattr(sdk_client.SdkThinqClient, method)
        gate = self

        def gated(client, *args, **kwargs):
            if gate.armed and _called_from_controller_execute():
                gate.armed = False
                gate.entered.set()
                assert gate.release.wait(10), "시험이 문을 열지 않았다"
            return original(client, *args, **kwargs)

        monkeypatch.setattr(sdk_client.SdkThinqClient, method, gated)


def _called_from_controller_execute() -> bool:
    frame = sys._getframe(1)
    while frame is not None:
        if frame.f_code.co_name == "_execute" and frame.f_code.co_filename.endswith("controller.py"):
            return True
        frame = frame.f_back
    return False


def _rule(api):
    rules = api.get("/routines/auto-rules").json()
    assert len(rules) == 1
    return rules[0]


def _change(api, change: str) -> None:
    rule = _rule(api)
    if change == "off":
        res = api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False})
    elif change == "value_reallowed":
        res = api.put(f"/routines/auto-rules/{rule['id']}", json={"value": "MID"})
        assert res.status_code == 200, res.text
        res = api.post(f"/routines/auto-rules/{rule['id']}/enable",
                       json={"enabled": True, "fingerprint": res.json()["fingerprint"]})
    elif change == "delete":
        res = api.delete(f"/routines/auto-rules/{rule['id']}")
    else:  # pragma: no cover
        raise AssertionError(change)
    assert res.status_code == 200, res.text


@pytest.mark.parametrize("method", ["get_status", "get_profile"])
@pytest.mark.parametrize("change", ["off", "value_reallowed", "delete"])
def test_rule_revoked_while_the_controller_waits_on_the_network_sends_nothing(monkeypatch, tmp_path, cloud,
                                                                             method, change):
    """H1: dispatch_guard를 지난 뒤 controller가 프로필·상태 조회를 기다리는 사이 끄기·값 변경(다시 허용 포함)·삭제 →
    조회가 끝나도 모의 클라우드 POST 0건, 기록은 '보내지 않음'."""
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        gate = _NetworkGate(monkeypatch, method)
        gate.armed = True
        _inject(api, inputs=("power",))
        assert gate.entered.wait(10), "자동 실행이 controller 조회까지 오지 않았다"
        _change(api, change)
        gate.release.set()
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        time.sleep(0.3)
        assert len(cloud.controls()) == before, cloud.controls()[before:]
        assert run["receipt"] == "not_dispatched"
        assert run["outcome"] == "blocked"
        assert "바꿨어요" not in " / ".join(run["notices"])
    finally:
        _reset()


def test_stop_does_not_wait_for_the_controller_network_read_and_nothing_is_sent(monkeypatch, tmp_path, cloud):
    """H1: 조회 대기 중 전체 정지 — /stop은 그 네트워크 대기를 기다리지 않고 돌아오고, 조회가 끝나도 보내지 않는다."""
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        _set_low(api)
        before = len(cloud.controls())
        gate = _NetworkGate(monkeypatch, "get_status")
        gate.armed = True
        _inject(api, inputs=("power",))
        assert gate.entered.wait(10)
        started = time.monotonic()
        assert api.post("/stop").status_code == 200
        assert not gate.release.is_set()  # 문이 닫힌 채로 정지가 끝났다
        assert time.monotonic() - started < 5
        assert _rule(api)["enabled"] is False
        gate.release.set()
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        time.sleep(0.3)
        assert len(cloud.controls()) == before
        assert run["receipt"] == "not_dispatched"
    finally:
        _reset()


# ── H2: 전체 정지와 '다음부터 자동으로' 허용 저장의 경쟁 ─────────────────────────────────────────


def _engine():
    from rpi.routines.wiring import get_auto_rule_engine

    return get_auto_rule_engine()


def _assert_no_auto_on_next_event(api, cloud, before):
    _inject(api, inputs=("power",))
    time.sleep(0.5)
    assert len(cloud.controls()) == before
    assert [r for r in api.get("/routines/auto-rules/runs").json() if r["outcome"] == "sent"] == []


def test_stop_completed_before_the_late_allow_save_keeps_the_rule_off(monkeypatch, tmp_path, cloud):
    """H2: approve-and-allow가 이번 실행을 제출한 뒤·규칙을 저장하기 전에 POST /stop이 끝났다 → 규칙은 켜지지 않는다.
    응답은 이번 실행(job_id)과 '자동 허용 실패'를 나눠 돌려주고, 다음 사건에 제어가 나가지 않는다."""
    from rpi.api.deps import get_suggestion_service

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _inject(api, inputs=("power",))
        card = next(s for s in api.get("/suggestions").json() if s.get("scenario_id") == "cook_done_air")
        svc = get_suggestion_service()
        original = svc.approve_submit
        stops = []

        def submit_then_stop(*args, **kwargs):
            job_id = original(*args, **kwargs)
            stops.append(api.post("/stop").status_code)  # 이번 실행 제출 뒤, 허용 저장 전에 전체 정지 완료
            return job_id

        monkeypatch.setattr(svc, "approve_submit", submit_then_stop)
        res = api.post(f"/suggestions/{card['id']}/approve-and-allow",
                       json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"]})
        assert stops == [200]
        assert res.status_code == 200, res.text
        assert all(r["enabled"] is False for r in api.get("/routines/auto-rules").json())  # 늦은 저장이 켜지 않았다
        body = res.json()
        assert body["job_id"]  # 이번 실행은 따로 — 결과는 job으로 본다
        assert body["auto_allow"]["ok"] is False
        assert "비상정지" in body["auto_allow"]["reason"] or "정지" in body["auto_allow"]["reason"]
        assert body["rule"] is None or body["rule"]["enabled"] is False
        assert all(r["enabled"] is False for r in api.get("/routines/auto-rules").json())
        _set_low(api)
        _assert_no_auto_on_next_event(api, cloud, len(cloud.controls()))
    finally:
        _reset()


def test_stop_during_reallow_of_an_existing_rule_keeps_it_off(monkeypatch, tmp_path, cloud):
    """H2: 목록에서 '다시 허용'(enable)을 처리하는 사이 전체 정지가 끝났다 → 늦은 저장이 규칙을 다시 켜지 않는다(409)."""
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)
        rule = api.get("/routines/auto-rules").json()[0]
        assert api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False}).status_code == 200
        engine = _engine()
        original = engine._rebound

        def stop_then_rebound(*args, **kwargs):
            assert api.post("/stop").status_code == 200  # 다시 허용 요청 처리 중 정지 완료
            return original(*args, **kwargs)

        monkeypatch.setattr(engine, "_rebound", stop_then_rebound)
        res = api.post(f"/routines/auto-rules/{rule['id']}/enable",
                       json={"enabled": True, "fingerprint": rule["fingerprint"]})
        assert res.status_code == 409, res.text
        assert "정지" in res.json()["detail"]
        monkeypatch.setattr(engine, "_rebound", original)
        assert api.get("/routines/auto-rules").json()[0]["enabled"] is False
        _set_low(api)
        _assert_no_auto_on_next_event(api, cloud, len(cloud.controls()))
        # 정지 뒤에 새로 시작한 다시 허용은 정상으로 켜진다.
        ok = api.post(f"/routines/auto-rules/{rule['id']}/enable",
                      json={"enabled": True, "fingerprint": rule["fingerprint"]})
        assert ok.status_code == 200 and ok.json()["enabled"] is True
    finally:
        _reset()


def test_stop_landing_inside_the_allow_save_never_leaves_a_usable_rule(monkeypatch, tmp_path, cloud):
    """H2: 정지가 허용 저장(DB 쓰기 대기) 한가운데 들어왔다 — 물리 정지(서비스 정지 보고)는 그 DB 대기를 기다리지 않고,
    저장이 끝나도 규칙은 꺼진 채이고 다음 사건에 제어가 나가지 않는다."""
    from rpi.api import deps

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _inject(api, inputs=("power",))
        card = next(s for s in api.get("/suggestions").json() if s.get("scenario_id") == "cook_done_air")
        engine = _engine()
        entered, release = threading.Event(), threading.Event()

        def slow_db_write(_value):
            entered.set()
            assert release.wait(10)

        engine.store._save_fn = slow_db_write  # 규칙 저장의 DB 쓰기를 붙잡는다
        service = deps.get_service()
        physical_done = threading.Event()
        original_stop = service.emergency_stop_report

        def stop_report(*args, **kwargs):
            try:
                return original_stop(*args, **kwargs)
            finally:
                physical_done.set()

        monkeypatch.setattr(service, "emergency_stop_report", stop_report)
        result = {}

        def allow():
            result["res"] = api.post(f"/suggestions/{card['id']}/approve-and-allow",
                                     json={"offer_fingerprint": card["auto_rule_offer"]["fingerprint"]})

        allow_thread = threading.Thread(target=allow)
        allow_thread.start()
        assert entered.wait(10), "허용 저장이 DB 쓰기까지 오지 않았다"
        stop_thread = threading.Thread(target=lambda: result.setdefault("stop", api.post("/stop")))
        stop_thread.start()
        assert physical_done.wait(5), "물리 정지가 허용 저장의 DB 대기를 기다렸다"
        assert not release.is_set()
        release.set()
        allow_thread.join(10)
        stop_thread.join(10)
        engine.store._save_fn = None
        assert result["stop"].status_code == 200
        assert all(r["enabled"] is False for r in api.get("/routines/auto-rules").json())
        body = result["res"].json()
        assert result["res"].status_code == 200 and body["auto_allow"]["ok"] is False
        assert all(r["enabled"] is False for r in api.get("/routines/auto-rules").json())
        _set_low(api)
        _assert_no_auto_on_next_event(api, cloud, len(cloud.controls()))
    finally:
        _reset()


# ── M1: 전송 뒤 늦게 온 사건의 나이 — 이 허브 시계로 옮긴 끝 시각 기준 ─────────────────────────────

RPI4_CLOCK = "rpi4clock0000001"


class _HubClock:
    """이 허브(RPi5)의 가짜 단조 시계. RPi4 시계(초)와 일부러 다른 값에서 시작한다(서로 다른 장치)."""

    def __init__(self) -> None:
        self.now = 10_000.0


@pytest.fixture()
def hub_clock():
    from rpi.services.event_clock import reset_event_clock

    clock = _HubClock()
    events = reset_event_clock(lambda: clock.now)
    # 링크 세션 기준점: 허브 10,000초에 탐침을 보냈고 RPi4는 자기 시계 500초로 답했다(clock_ref).
    probe = events.new_probe()
    assert events.on_clock_ref({"probe": probe, "clock_id": RPI4_CLOCK, "t_monotonic_ns": 500 * 10**9})
    yield clock
    reset_event_clock()


def _rpi4_frame(at_rpi4_s: float, clock_id: str = RPI4_CLOCK) -> dict:
    """RPi4가 끝을 본 즉시 낸 프레임(RPi4 시계). 낸 시각 = 끝 시각 — 예전 판정의 '나이'는 0초다."""
    from rpi.verifier.done_fusion import rehearsal_done_event

    frame = rehearsal_done_event("microwave", ["power"], now_s=at_rpi4_s).to_frame(int(at_rpi4_s * 1e9))
    frame["clock_id"] = clock_id
    frame["source"] = "injected"
    return frame


def _backdate_allowance(seconds: float) -> None:
    """허용 시각을 과거로(지문에 들어가지 않는 칸) — 나이 경계만 보려고 '허용 전 사건' 판정을 비켜 둔다."""
    from dataclasses import replace
    from datetime import timedelta

    from rpi.api import deps

    engine = _engine()
    rule = engine.store.list()[0]
    past = (deps.get_clock().now() - timedelta(seconds=seconds)).isoformat()
    engine.store.save(replace(rule, allowed_at=past))


def _deliver(frame: dict) -> None:
    from rpi.api import deps

    deps.receive_appliance_done(dict(frame))


def _setup_allowed(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    api = TestClient(app)
    _allow(api)
    _set_low(api)
    return api


def test_frame_delayed_after_sending_is_judged_by_its_age_on_arrival(monkeypatch, tmp_path, cloud, hub_clock):
    """M1: RPi4가 끝을 본 즉시 낸 프레임이 링크에서 301초 늦게 처음 도착했다 — 나이 301초로 막는다(예전: 0초로 보냄)."""
    try:
        api = _setup_allowed(monkeypatch, tmp_path, cloud)
        _backdate_allowance(3600)
        before = len(cloud.controls())
        frame = _rpi4_frame(500 + 20)  # RPi4 520초 = 허브 10,020초
        hub_clock.now = 10_020 + 301
        _deliver(frame)
        run = _wait_run(api, lambda r: r["outcome"] == "blocked")
        assert "오래된" in run["reason"]
        time.sleep(0.3)
        assert len(cloud.controls()) == before
    finally:
        _reset()


def test_event_from_before_the_allowance_delivered_late_is_not_run(monkeypatch, tmp_path, cloud, hub_clock):
    """M1: 허용하기 60초 전에 끝난 가열의 프레임이 허용 뒤에 처음 도착 — 120초 안이어도 '허용 전 사건'으로 막는다."""
    try:
        api = _setup_allowed(monkeypatch, tmp_path, cloud)  # 방금 허용
        before = len(cloud.controls())
        frame = _rpi4_frame(500 + 100)  # 허브 10,100초에 끝
        hub_clock.now = 10_100 + 60  # 60초 뒤에 도착 — 허용(방금)보다 앞선 가열
        _deliver(frame)
        run = _wait_run(api, lambda r: r["outcome"] == "blocked")
        assert "허용하기 전" in run["reason"]
        time.sleep(0.3)
        assert len(cloud.controls()) == before
    finally:
        _reset()


@pytest.mark.parametrize(("age", "sent"), [(119.0, True), (121.0, False)])
def test_120_second_boundary_uses_the_age_on_this_hub(monkeypatch, tmp_path, cloud, hub_clock, age, sent):
    """M1: 상한 120초 경계 — 이 허브 시계로 잰 나이 119초는 보내고 121초는 막는다."""
    try:
        api = _setup_allowed(monkeypatch, tmp_path, cloud)
        _backdate_allowance(3600)
        before = len(cloud.controls())
        hub_clock.now = 10_200 + age
        _deliver(_rpi4_frame(500 + 200))
        if sent:
            run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
            assert run["status"] == "succeeded"
            assert len(cloud.controls()) == before + 1
        else:
            run = _wait_run(api, lambda r: r["outcome"] == "blocked")
            assert "오래된" in run["reason"]
            time.sleep(0.3)
            assert len(cloud.controls()) == before
    finally:
        _reset()


def test_event_expiring_while_waiting_to_send_is_not_sent(monkeypatch, tmp_path, cloud, hub_clock):
    """M1: 판단 때 나이 100초(통과) → controller 상태 조회 대기 30초 → 전송 직전 130초 → 보내지 않는다."""
    try:
        api = _setup_allowed(monkeypatch, tmp_path, cloud)
        _backdate_allowance(3600)
        before = len(cloud.controls())
        gate = _NetworkGate(monkeypatch, "get_status")
        gate.armed = True
        hub_clock.now = 10_300 + 100
        _deliver(_rpi4_frame(500 + 300))
        assert gate.entered.wait(10)
        hub_clock.now += 30
        gate.release.set()
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        time.sleep(0.3)
        assert len(cloud.controls()) == before
        assert run["outcome"] == "blocked" and run["receipt"] == "not_dispatched"
        assert "지나" in run["reason"]
    finally:
        _reset()


@pytest.mark.parametrize("case", ["other_session", "link_down"])
def test_without_a_clock_reference_for_the_frame_auto_run_is_held(monkeypatch, tmp_path, cloud, hub_clock, case):
    """M1: 근거가 없으면 보류 — 프레임의 시계가 지금 링크 세션 것이 아니거나(RPi4 재시작) 링크가 끊겨 기준점을 버렸다."""
    from rpi.services.event_clock import get_event_clock

    try:
        api = _setup_allowed(monkeypatch, tmp_path, cloud)
        _backdate_allowance(3600)
        before = len(cloud.controls())
        hub_clock.now = 10_400 + 1
        if case == "other_session":
            frame = _rpi4_frame(500 + 400, clock_id="rpi4clock0000002")
        else:
            frame = _rpi4_frame(500 + 400)
            get_event_clock().link_down()
        _deliver(frame)
        run = _wait_run(api, lambda r: r["outcome"] == "blocked")
        assert "근거가 없어" in run["reason"]
        time.sleep(0.3)
        assert len(cloud.controls()) == before
    finally:
        _reset()


# ── M2: 결과에는 job을 만들 때의 대상·동작·설정값 사본 ─────────────────────────────────────────


@pytest.mark.parametrize("change", ["value_low", "delete", "rename_target"])
def test_result_keeps_the_target_and_value_of_the_job_not_the_current_rule(monkeypatch, tmp_path, cloud, change):
    """M2: 모의 클라우드에 강(HIGH)을 보낸 직후·결과 확인 전에 규칙을 약으로 바꾸거나 지우거나 대상 이름을 바꿨다 —
    결과 기록·알림·/status last_auto_run(키오스크 문구 재료)은 보낸 그대로 '공기청정기(모의 클라우드) 풍량 강'이다."""
    from rpi.api import deps
    from rpi.api.thinq_wiring import appliance_for
    from rpi.services.thinq import sdk_client

    try:
        api = _setup_allowed(monkeypatch, tmp_path, cloud)
        before = len(cloud.controls())
        rule = _rule(api)
        original_post = sdk_client.SdkThinqClient.post_control
        changed = threading.Event()

        def post_then_change(client, device_id, payload):
            response = original_post(client, device_id, payload)
            if not changed.is_set():
                changed.set()
                if change == "value_low":
                    assert api.put(f"/routines/auto-rules/{rule['id']}", json={"value": "LOW"}).status_code == 200
                elif change == "delete":
                    assert api.delete(f"/routines/auto-rules/{rule['id']}").status_code == 200
                else:
                    registry = deps.get_appliance_registry()
                    registry.unregister_system("air_purifier")
                    registry.register_system(appliance_for("air_purifier", device_id, "안방 공기청정기"))
            return response

        monkeypatch.setattr(sdk_client.SdkThinqClient, "post_control", post_then_change)
        _inject(api, inputs=("power",))
        run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
        assert changed.is_set()
        assert cloud.controls()[before]["body"] == {"airFlow": {"windStrength": "HIGH"}}
        assert run["status"] == "succeeded"
        assert (run["target_name"], run["setting_label"], run["value_label"]) == (
            "공기청정기(모의 클라우드)", "풍량", "강")
        assert run["action_text"] == "공기청정기(모의 클라우드) 풍량을 강으로 변경"
        notices = " / ".join(run["notices"])
        assert "공기청정기(모의 클라우드) 풍량을 바꿨어요" in notices and "안방" not in notices
        auto = api.get("/status").json()["last_auto_run"]
        assert auto["job_id"] == run["job_id"]
        assert (auto["target_name"], auto["setting_label"], auto["value_label"]) == (
            "공기청정기(모의 클라우드)", "풍량", "강")  # 키오스크: '… 풍량을 강으로 바꿨어요'
    finally:
        _reset()
