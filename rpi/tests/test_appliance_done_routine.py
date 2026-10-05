"""세탁 끝(전력 + 종료음 융합) → RPi5 루틴 안내, 리허설 주입(시연 v3 갭 S8·M1, 2026-10-06).

전부 모의·주입 수준이다. 실물 세탁기·CT·마이크로 확인한 것이 아니다.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.api.thinq_wiring import reset_thinq_caches
from rpi.routines import RoutineEngine, RoutineStore, build_routine
from rpi.routines.wiring import reset_routines
from rpi.services.act_client import ActClient
from rpi.services.appliance_done import parse_appliance_done
from rpi.tests.test_routines import THU_0730, FakeCare, FakeService, FakeSuggestions, FixedClock
from rpi.verifier.done_fusion import rehearsal_done_event

ANNOUNCE = "세탁이 끝났어요. 빨래를 꺼내 널어 주세요"


def _frame(state="done_confirmed", inputs=("power", "beep"), source="real", **kw):
    doc = {"type": "appliance_done", "appliance_id": "washer", "event": "wash_complete",
           "state": state, "inputs": list(inputs), "expected_inputs": ["power", "beep"],
           "source": source, "at_s": 10.0, "gap_s": 3.0, "fusion_window_s": 120.0, "evidence": {}}
    doc.update(kw)
    return doc


def _engine_with(**routine_kw):
    store = RoutineStore()
    suggestions, service, care = FakeSuggestions(), FakeService(), FakeCare()
    clock = FixedClock(THU_0730)
    engine = RoutineEngine(store, suggestions, service, clock, care_events=care)
    body = {"name": "세탁 끝 알림", "mode": "notify",
            "trigger": {"kind": "event", "event": "wash_complete"},
            "steps": [{"kind": "announce", "text": ANNOUNCE}]}
    body.update(routine_kw)
    store.save(build_routine(body, routine_id=store.new_id(), now=clock.now()))
    return engine, suggestions, care


# ── 기록 해석 ──────────────────────────────────────────────────────────────


def test_parse_accepts_a_valid_frame_and_rejects_bad_ones():
    record = parse_appliance_done(_frame())
    assert record["appliance_id"] == "washer" and record["confidence"] == "confirmed"
    assert parse_appliance_done(_frame(state="done_maybe")) is None
    assert parse_appliance_done(_frame(source="unknown")) is None
    assert parse_appliance_done(_frame(inputs=[])) is None
    assert parse_appliance_done(_frame(appliance_id="")) is None
    # 상태와 입력이 어긋나면(두 입력이라 하면서 하나만) 받지 않는다 — 확정을 지어내지 않게.
    assert parse_appliance_done(_frame(state="done_confirmed", inputs=["power"])) is None


# ── 루틴 안내 문구: 확신도에 따라 ──────────────────────────────────────────


def test_confirmed_says_it_is_done_and_reads_the_announce():
    engine, _, care = _engine_with()
    engine.on_appliance_done(parse_appliance_done(_frame()))
    kind, message, _ = care.events[-1]
    assert kind == "routine_notice"
    assert "세탁이 끝났어요" in message and "전력·종료음" in message
    assert ANNOUNCE in message
    assert "시연" not in message and "모의" not in message


@pytest.mark.parametrize("state,inputs,which", [
    ("done_power_only", ["power"], "전력"),
    ("done_beep_only", ["beep"], "종료음"),
])
def test_single_input_does_not_claim_completion(state, inputs, which):
    engine, _, care = _engine_with()
    engine.on_appliance_done(parse_appliance_done(_frame(state=state, inputs=inputs)))
    message = care.events[-1][1]
    assert "끝난 것 같아요" in message and "확인해 주세요" in message
    assert which in message
    assert "세탁이 끝났어요" not in message  # 루틴의 '끝났어요' 안내를 읽지 않는다
    log = engine.recent_log()[0]
    assert log["confidence"] == "probable" and log["inputs"] == inputs


def test_injected_and_mock_are_labelled():
    engine, _, care = _engine_with()
    engine.on_appliance_done(parse_appliance_done(_frame(source="injected")))
    assert "(시연 주입)" in care.events[-1][1]
    engine2, _, care2 = _engine_with()
    engine2.on_appliance_done(parse_appliance_done(_frame(source="mock")))
    assert "(모의 입력)" in care2.events[-1][1]


def test_after_done_trigger_on_the_washer_fires_with_confidence():
    engine, _, care = _engine_with(
        name="빨래 널기", trigger={"kind": "after_done", "appliance_id": "washer"})
    engine.on_appliance_done(parse_appliance_done(_frame(state="done_power_only", inputs=["power"])))
    log = engine.recent_log()[0]
    assert log["trigger"] == "after_done" and "끝난 것 같아요" in care.events[-1][1]


def test_other_appliance_or_event_does_not_fire():
    engine, _, care = _engine_with(trigger={"kind": "event", "event": "wash_complete",
                                            "appliance_id": "washer"})
    engine.on_appliance_done(parse_appliance_done(_frame(appliance_id="dryer")))
    engine.on_appliance_done(parse_appliance_done(_frame(event="dry_complete")))
    assert care.events == []


# ── ActClient: RPi4 자체발신 프레임 ─────────────────────────────────────────


class _NullWriter:
    def write(self, data):
        pass

    async def drain(self):
        pass


def test_act_client_forwards_appliance_done_frames():
    got = []

    async def _t():
        reader = asyncio.StreamReader()
        client = ActClient(reader, _NullWriter(), on_appliance_done=got.append)
        reader.feed_data((json.dumps(_frame(), ensure_ascii=False) + "\n").encode())
        reader.feed_data((json.dumps(_frame(state="nope")) + "\n").encode())
        reader.feed_eof()
        await client._read_loop()
        assert client.last_appliance_done["state"] == "done_confirmed"

    asyncio.run(_t())
    assert len(got) == 1 and got[0]["state"] == "done_confirmed"


# ── 리허설 주입 API(S8) ──────────────────────────────────────────────────────

_SINGLETONS = (
    deps.get_service, deps.get_suggestion_service, deps.get_suppression_store,
    deps.get_alert_store, deps.get_node_registry, deps.get_demo_failure_state,
    deps.get_job_history, deps.get_presence_store, deps.get_appliance_registry,
    deps.get_readiness_registry, deps.get_usage_log, deps.get_care_events,
    deps.get_control_arbiter, deps.get_presence_state_machine, deps.get_appliance_done_log,
)


def _reset():
    for dep in _SINGLETONS:
        dep.cache_clear()
    reset_thinq_caches()
    reset_routines()


@pytest.fixture()
def plain(monkeypatch):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_THINQ_MODE",
                 "SIMPLELAY_LOCAL_APPLIANCES", "SIMPLELAY_ACT_MODE"):
        monkeypatch.delenv(name, raising=False)
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _save_wash_done(c):
    template = next(t for t in c.get("/routines/templates").json() if t["template_id"] == "wash_done")
    body = {k: template[k] for k in ("name", "trigger", "conditions", "mode", "steps")}
    saved = c.post("/routines", json=body)
    assert saved.status_code == 201, saved.text


def _notice(c, timeout=4.0):
    deadline = time.monotonic() + timeout
    while True:
        events = [e for e in c.get("/care-events").json() if e["kind"] == "routine_notice"]
        if events:
            return events[0]["message"]
        assert time.monotonic() < deadline
        time.sleep(0.02)


def test_injection_in_mock_mode_drives_the_routine_and_is_labelled(plain):
    _save_wash_done(plain)
    res = plain.post("/demo/appliance-done", json={"appliance_id": "washer", "inputs": ["power", "beep"]})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["state"] == "done_confirmed" and body["source"] == "injected"
    assert "시연 주입" in body["detail"]
    message = _notice(plain)
    assert "세탁이 끝났어요" in message and "(시연 주입)" in message
    assert deps.get_appliance_done_log().recent()[0]["source"] == "injected"


def test_injection_with_one_input_is_probable(plain):
    _save_wash_done(plain)
    body = plain.post("/demo/appliance-done", json={"appliance_id": "washer", "inputs": ["power"]}).json()
    assert body["state"] == "done_power_only"
    message = _notice(plain)
    assert "끝난 것 같아요" in message and "(시연 주입)" in message


def test_injection_validates_inputs(plain):
    assert plain.post("/demo/appliance-done", json={"appliance_id": "washer", "inputs": []}).status_code == 422
    assert plain.post("/demo/appliance-done",
                      json={"appliance_id": "washer", "inputs": ["door"]}).status_code == 422


def test_injection_is_404_on_a_real_board(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "uart")
    from rpi.main import app

    c = TestClient(app)
    assert c.post("/demo/appliance-done", json={"appliance_id": "washer",
                                                "inputs": ["power", "beep"]}).status_code == 404


@pytest.fixture()
def sim(monkeypatch):
    for name in ("SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_THINQ_MODE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "simulator")
    _reset()
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.link_tap import LinkFrameTap
    from rpi.services.simulator_controller import SimulatorController

    controller = SimulatorController(step_seconds=0, tap=LinkFrameTap(None, transport="in_memory"),
                                     on_alert=deps.get_alert_store().record,
                                     on_appliance_done=deps.receive_appliance_done)
    service = SimpleLayService(RuleBasedIntentResolver(), controller,
                               appliance_registry=deps.get_appliance_registry(),
                               care_events=deps.get_care_events())
    app.dependency_overrides[deps.get_service] = lambda: service
    try:
        yield TestClient(app), controller
    finally:
        app.dependency_overrides.pop(deps.get_service, None)
        controller.close()
        _reset()


def test_injection_in_simulator_goes_through_the_rpi4_frame_path(sim):
    c, controller = sim
    _save_wash_done(c)
    res = c.post("/demo/appliance-done", json={"appliance_id": "washer", "inputs": ["beep"]})
    assert res.status_code == 200, res.text
    assert res.json()["state"] == "done_beep_only"
    message = _notice(c)
    assert "끝난 것 같아요" in message and "(시연 주입)" in message
    frames = [f["message"] for f in controller.snapshot()["frames"]
              if f["message"].get("type") == "appliance_done"]
    assert frames and frames[-1]["source"] == "injected"


def test_rehearsal_event_matches_api_states():
    assert rehearsal_done_event("washer", ["power", "beep"], now_s=0).state == "done_confirmed"
