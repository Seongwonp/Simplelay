"""실모드 디지털 트윈(GET /twin) — 통신 프레임 탭 + progress + 결과 프레임, 그리고 기록 재생."""
from __future__ import annotations

import json
import time

import pytest
from fastapi.testclient import TestClient

from rpi.services.link_tap import LinkFrameTap
from rpi.services.twin_view import (
    build_link_twin_state,
    build_replay_state,
    load_session_log,
)


def _f(direction, **message):
    return {"kind": "frame", "direction": direction, "type": message.get("type"),
            "sequence_id": message.get("sequence_id"), "message": message}


EXEC = _f("hub_to_act", type="execute", sequence_id="s", buttons=["즉석밥", "시작"])


def _progress(n, phase, button, attempt=1, **extra):
    return _f("act_to_hub", type="progress", sequence_id="s", n=n, phase=phase, button=button,
              step_index=0 if button == "즉석밥" else 1, attempt=attempt, execution_mode="real", **extra)


def test_no_execute_frame_means_no_job_and_declared_mode():
    state = build_link_twin_state([], controller_mode="unknown", transport="uart")
    assert state["job"] is None and state["execution_mode"] == "unknown"
    assert state["source"] == "link_tap" and state["transport"] == "uart"


def test_progress_drives_presses_but_never_a_result():
    frames = [EXEC, _progress(1, "move", "즉석밥", target={"x_mm": 1.0, "y_mm": 2.0}),
              _progress(2, "press", "즉석밥", ok=True)]
    state = build_link_twin_state(frames)
    job = state["job"]
    assert state["running"] is True  # result 전 = 열린 실행(서비스 상태가 없을 때)
    assert job["presses"] == ["즉석밥"] and job["result"] is None
    assert job["phase_now"]["phase"] == "press"
    # progress의 실행 환경 보고로 REAL(컨트롤러는 unknown)
    assert state["execution_mode"] == "real" and state["execution_mode_source"] == "rpi4_progress"
    assert job["carriage"] == {"kind": "estimate", "label": "명령 기준 추정", "button": "즉석밥",
                               "x_mm": 1.0, "y_mm": 2.0, "n": 1}


def test_error_frame_is_not_a_result_and_other_sequences_are_ignored():
    frames = [EXEC, _f("act_to_hub", type="result", sequence_id="old", success=True, retry=0),
              _f("act_to_hub", type="progress", sequence_id="old", phase="move", button="라면"),
              _f("act_to_hub", type="error", sequence_id="s", reason="busy")]
    job = build_link_twin_state(frames)["job"]
    assert job["result"] is None and job["link_error"] == "busy"
    assert job["presses"] == [] and job["press_source"] == "none"


def test_mock_declared_controller_is_not_upgraded_by_a_real_report():
    frames = [EXEC, _f("act_to_hub", type="result", sequence_id="s", success=True, retry=0, execution_mode="real")]
    state = build_link_twin_state(frames, controller_mode="mock")
    assert state["execution_mode"] == "mock" and state["execution_mode_source"] == "controller"
    state = build_link_twin_state(frames, controller_mode="unknown")
    assert state["execution_mode"] == "real" and state["execution_mode_source"] == "rpi4_result"
    assert state["job"]["result"]["success"] is True


def test_encoder_position_beats_command_estimate():
    pos = {"a_counts": 30, "b_counts": -10, "z_counts": 0, "x_mm": 1.1, "y_mm": 2.1, "source": "mcu_event"}
    frames = [EXEC, _progress(1, "move", "즉석밥", target={"x_mm": 1.0, "y_mm": 2.0}),
              _progress(2, "press", "즉석밥", ok=True, position=pos)]
    c = build_link_twin_state(frames)["job"]["carriage"]
    assert c["kind"] == "encoder" and c["label"] == "엔코더 보고 위치"
    assert (c["x_mm"], c["y_mm"], c["a_counts"]) == (1.1, 2.1, 30)


def test_session_log_replay_parses_caps_gaps_and_only_shows_recorded_results(tmp_path):
    clock = {"ns": 1_000_000_000}
    tap = LinkFrameTap(tmp_path / "session.jsonl", clock_ns=lambda: clock["ns"])

    def rec(dt_s, direction, message):
        clock["ns"] += int(dt_s * 1e9)
        tap.record(direction, message)

    rec(0, "hub_to_act", EXEC["message"])
    rec(0.5, "act_to_hub", _progress(1, "move", "즉석밥")["message"])
    rec(60, "act_to_hub", _progress(2, "press", "즉석밥", ok=True)["message"])  # 긴 공백 → 3초로
    rec(0.5, "act_to_hub", {"type": "result", "sequence_id": "s", "success": False, "retry": 0,
                            "outcome": "stopped", "execution_mode": "real"})
    tap.close()
    with open(tmp_path / "session.jsonl", "a", encoding="utf-8") as fh:
        fh.write("not json\n")
    with open(tmp_path / "session.jsonl", encoding="utf-8") as fh:
        timeline = load_session_log(fh)
    assert timeline["times"] == [0.0, 0.5, 3.5, 4.0]
    assert timeline["skipped"] == 1 and timeline["sessions"] == 1
    early = build_replay_state(timeline, 1.0, "session.jsonl")
    assert early["source"] == "replay" and early["replay"]["label"] == "기록 재생"
    assert early["job"]["result"] is None and early["running"] is True and early["replay"]["done"] is False
    late = build_replay_state(timeline, 99, "session.jsonl")
    assert late["replay"]["done"] is True and late["running"] is False
    assert late["job"]["result"] == {"success": False, "retry": 0, "outcome": "stopped", "execution_mode": "real"}
    assert late["execution_mode"] == "real"


@pytest.fixture
def sim_app(tmp_path, monkeypatch):
    from rpi.api.deps import get_service
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.main import app
    from rpi.services.simulator_controller import SimulatorController

    tap = LinkFrameTap(tmp_path / "logs" / "session.jsonl", transport="in_memory")
    controller = SimulatorController(step_seconds=0, tap=tap)
    service = SimpleLayService(RuleBasedIntentResolver(), controller)
    app.dependency_overrides[get_service] = lambda: service
    monkeypatch.setenv("SIMPLELAY_TWIN_REPLAY_DIR", str(tmp_path / "logs"))
    try:
        yield TestClient(app), controller, tap
    finally:
        app.dependency_overrides.pop(get_service, None)
        controller.close()
        tap.close()


def _wait_done(c, job_id):
    deadline = time.monotonic() + 3
    while True:
        status = c.get("/status").json()
        if status["last_job_id"] == job_id and not status["running"]:
            return status
        assert time.monotonic() < deadline
        time.sleep(0.005)


def test_twin_routes_follow_a_real_execution_and_write_the_session_log(sim_app, tmp_path):
    c, controller, tap = sim_app
    page = c.get("/twin")
    assert page.status_code == 200 and 'id="twinCanvas"' in page.text and 'src="twin-motion.js"' in page.text
    script = c.get("/twin-motion.js")
    assert script.status_code == 200 and "carriageView" in script.text
    controller.inject_failure(0, 2)
    job_id = c.post("/execute-buttons", json={"buttons": ["즉석밥", "시작"], "appliance_id": "microwave"}).json()["job_id"]
    _wait_done(c, job_id)
    twin = c.get("/twin/state").json()
    assert twin["source"] == "link_tap" and twin["transport"] == "in_memory"
    assert twin["execution_mode"] == "mock"  # 시뮬레이터가 스스로 밝힌 모의
    job = twin["job"]
    assert job["buttons"] == ["즉석밥", "시작"] and job["press_source"] == "progress"
    assert job["presses"] == ["즉석밥", "즉석밥", "즉석밥", "시작"]
    assert [s["attempts"] for s in job["steps"]] == [3, 1]
    assert (job["result"]["success"], job["result"]["retry"]) == (True, 2)
    assert job["carriage"]["label"] == "명령 기준 추정"  # 모의 어댑터는 위치를 보고하지 않는다
    assert twin["session_log"]["enabled"] is True
    # /simulator/twin은 그대로(시뮬레이터 내부 관측)
    sim = c.get("/simulator/twin/state").json()
    assert [s["attempts"] for s in sim["job"]["steps"]] == [3, 1]
    assert c.get("/simulator/twin").status_code == 200
    # 세션 기록 파일: 머리 줄 + execute·progress·result
    rows = [json.loads(line) for line in (tmp_path / "logs" / "session.jsonl").read_text(encoding="utf-8").splitlines()]
    assert rows[0]["kind"] == "session_start"
    types = [r["type"] for r in rows[1:]]
    assert "execute" in types and "progress" in types and types[-1] == "result"
    # 같은 파일을 재생한다
    listing = c.get("/twin/replays").json()
    assert [f["name"] for f in listing["files"]] == ["session.jsonl"]
    replay = c.get("/twin/state", params={"replay": "session.jsonl", "t": 9999}).json()
    assert replay["source"] == "replay" and replay["replay"]["done"] is True
    assert replay["job"]["result"]["retry"] == 2
    assert c.get("/twin/state", params={"replay": "../secret.jsonl"}).status_code == 422
    assert c.get("/twin/state", params={"replay": "nope.jsonl"}).status_code == 404


def test_twin_data_routes_need_the_api_key_but_the_page_does_not(sim_app, monkeypatch):
    c, _, _ = sim_app
    monkeypatch.delenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", raising=False)
    monkeypatch.setenv("SIMPLELAY_API_KEY", "k-123456")
    assert c.get("/twin").status_code == 200
    assert c.get("/twin-motion.js").status_code == 200
    for path in ("/twin/state", "/twin/replays", "/twin/hardware"):
        assert c.get(path).status_code == 401, path
        assert c.get(path, headers={"X-API-Key": "k-123456"}).status_code == 200, path
