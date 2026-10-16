"""progress 프레임(2026-09-29): RPi4 ActExecutor가 누름마다 진행을 보내고 RPi5가 기록한다.

실제 ActClient(RPi5) ↔ 실제 ActExecutor(RPi4)를 메모리 파이프로 잇는다. 모션 어댑터 자리에는
MCU 엔코더 위치를 보고하는 가짜를 둔다. 결과는 여전히 result 프레임에서만 온다.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from rpi.controller import ButtonTarget, ClosedLoopController, ExecutionMode
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.models import PressCommand
from rpi.controller.serial_motion import InMemoryLinePipe, SerialMotionClient
from rpi.services.act_client import ActClient, ActLinkError
from rpi.services.link_tap import LinkFrameTap
from rpi.services.twin_view import build_link_twin_state
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor

BUTTONS = ["즉석밥", "시작"]
TARGETS = {"즉석밥": ButtonTarget(10.0, 20.0), "시작": ButtonTarget(30.0, 5.0)}


class _PipeWriter:
    def __init__(self, peer: asyncio.StreamReader) -> None:
        self._peer = peer

    def write(self, data: bytes) -> None:
        self._peer.feed_data(data)

    async def drain(self) -> None:
        pass


class _CountingGrbl(MockGrblClient):
    """실물이라 밝히고, 누를 때마다 MCU가 엔코더 위치를 보고한 것처럼 ``last_position``을 둔다."""

    execution_mode = ExecutionMode.REAL

    def __init__(self, with_mm: bool = True) -> None:
        super().__init__()
        self._with_mm = with_mm
        self._pos: dict | None = None

    @property
    def last_position(self):
        return self._pos

    def press(self, command: PressCommand) -> None:
        super().press(command)
        self._pos = {"a_counts": int(command.x_mm * 10 + command.y_mm * 10),
                     "b_counts": int(command.x_mm * 10 - command.y_mm * 10), "z_counts": 0,
                     "x_mm": command.x_mm if self._with_mm else None,
                     "y_mm": command.y_mm if self._with_mm else None, "source": "mcu_reply"}


def _controller(outcomes, grbl=None):
    return ClosedLoopController(
        grbl=grbl or _CountingGrbl(),
        verifier=MockVerifier(outcomes=list(outcomes) + [True] * 20),
        alerts=MockAlertSink(),
        safety=MockSafetyController(),
    )


def _roundtrip(controller, *, progress=None, tap=None, on_progress=None, job_observer=None):
    async def _t():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        executor = ActExecutor(reader=rpi4_reader, writer=_PipeWriter(rpi5_reader),
                               controller=controller, progress=progress, job_observer=job_observer)
        client = ActClient(rpi5_reader, _PipeWriter(rpi4_reader), tap=tap, on_progress=on_progress)
        await client.start()
        run = asyncio.create_task(executor.run())
        try:
            return await asyncio.wait_for(client.execute(BUTTONS, button_behaviors={b: "idempotent" for b in BUTTONS}, sequence_id="seq-p", targets=TARGETS, appliance_id="microwave"), 5)
        finally:
            rpi4_reader.feed_eof()
            await run
            await client.stop()

    return asyncio.run(_t())


#: 연결 알림 프레임(2026-10-06 평가 C1)·사건 신선도 기준점(3차 평가 M1 — clock_probe·clock_ref) — 실행 흐름 비교에서 뺀다.
_HANDSHAKE = {"hello", "act_info", "estop_state", "clock_probe", "clock_ref"}


def test_progress_frames_round_trip_before_result_with_encoder_counts():
    tap = LinkFrameTap()
    seen: list[dict] = []
    # 첫 버튼 1회 검증 실패 → 보정 재시도 1회
    result = _roundtrip(_controller([False]), tap=tap, on_progress=seen.append)
    assert (result.success, result.retry) == (True, 1)

    # 연결 알림(hello·act_info·estop_state, 2026-10-06 평가 C1)은 실행 흐름 밖이다.
    frames = [f for f in tap.frames() if f["type"] not in _HANDSHAKE]
    types = [f["type"] for f in frames]
    assert types[0] == "execute" and types[-1] == "result"
    progress = [f["message"] for f in frames if f["type"] == "progress"]
    assert types[1:-1] == ["progress"] * len(progress)  # 모든 진행 보고가 결과보다 먼저
    assert seen == progress
    assert [(p["button"], p["attempt"], p["phase"]) for p in progress] == [
        ("즉석밥", 1, "move"), ("즉석밥", 1, "press"), ("즉석밥", 1, "verify"),
        ("즉석밥", 2, "retry"), ("즉석밥", 2, "move"), ("즉석밥", 2, "press"), ("즉석밥", 2, "verify"),
        ("시작", 1, "move"), ("시작", 1, "press"), ("시작", 1, "verify"),
    ]
    assert [p["n"] for p in progress] == list(range(1, 11))
    assert {p["sequence_id"] for p in progress} == {"seq-p"}
    assert {p["execution_mode"] for p in progress} == {"real"}
    assert [p["pressed"] for p in progress if p["phase"] == "verify"] == [False, True, True]
    assert [p["step_index"] for p in progress if p["phase"] == "move"] == [0, 0, 1]
    retry = next(p for p in progress if p["phase"] == "retry")
    assert retry["correction"]["retry_number"] == 1
    assert set(retry["correction"]) == {"retry_number", "xy_adjustment_required", "increase_press_depth"}
    move = next(p for p in progress if p["phase"] == "move")
    assert move["target"] == {"x_mm": 10.0, "y_mm": 20.0}
    press = [p for p in progress if p["phase"] == "press"][-1]
    assert press["ok"] is True and press["position"]["a_counts"] == 350 and press["position"]["x_mm"] == 30.0
    assert all(isinstance(p["t_monotonic_ns"], int) for p in progress)

    # 실모드 트윈: RPi5 컨트롤러는 모름(unknown) → RPi4 보고로 REAL, 캐리지는 엔코더 보고 위치.
    state = build_link_twin_state(frames, last_execute=tap.last_execute())
    assert state["execution_mode"] == "real" and state["execution_mode_source"] == "rpi4_result"
    job = state["job"]
    assert job["result"]["success"] is True and job["result"]["execution_mode"] == "real"
    assert [s["attempts"] for s in job["steps"]] == [2, 1]
    assert job["carriage"]["kind"] == "encoder" and job["carriage"]["label"] == "엔코더 보고 위치"
    assert (job["carriage"]["x_mm"], job["carriage"]["y_mm"]) == (30.0, 5.0)
    assert job["press_log"][1]["correction"]["retry_number"] == 1
    assert state["running"] is False and job["phase_now"] is None


def test_counts_without_mm_fall_back_to_command_estimate():
    tap = LinkFrameTap()
    _roundtrip(_controller([], grbl=_CountingGrbl(with_mm=False)), tap=tap)
    job = build_link_twin_state(tap.frames(), last_execute=tap.last_execute())["job"]
    assert job["carriage"]["kind"] == "estimate" and job["carriage"]["label"] == "명령 기준 추정"
    assert (job["carriage"]["x_mm"], job["carriage"]["y_mm"]) == (30.0, 5.0)
    assert job["carriage"]["encoder_counts"]["a_counts"] == 350


def test_progress_can_be_switched_off_and_twin_still_reports_only_the_result(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_ACT_PROGRESS", "0")
    tap = LinkFrameTap()
    result = _roundtrip(_controller([]), tap=tap)
    assert result.success is True
    assert [f["type"] for f in tap.frames() if f["type"] not in _HANDSHAKE] == ["execute", "result"]
    state = build_link_twin_state(tap.frames(), last_execute=tap.last_execute())
    job = state["job"]
    assert job["press_source"] == "none" and job["presses"] == [] and job["carriage"] is None
    assert job["result"]["success"] is True  # 결과는 result 프레임에서만


def test_old_rpi5_client_without_progress_handling_is_unaffected():
    """옛 RPi5 모양: 탭·관찰자 없이 progress가 섞여 와도 결과만 대기열을 끝낸다."""
    async def _t():
        to_rpi4, to_rpi5 = asyncio.StreamReader(), asyncio.StreamReader()
        client = ActClient(to_rpi5, _PipeWriter(to_rpi4))
        await client.start()

        async def fake_rpi4(reply_type):
            line = json.loads(await to_rpi4.readuntil(b"\n"))
            seq = line["sequence_id"]
            for n in range(1, 4):
                to_rpi5.feed_data(json.dumps({"type": "progress", "sequence_id": seq, "n": n,
                                              "phase": "move", "button": "a"}).encode() + b"\n")
            # 다른 실행의 progress·알 수 없는 type도 무시된다.
            to_rpi5.feed_data(b'{"type":"progress","sequence_id":"other"}\n{"type":"mystery"}\n')
            final = ({"type": "result", "sequence_id": seq, "success": True, "retry": 0}
                     if reply_type == "result" else {"type": "error", "sequence_id": seq, "reason": "busy"})
            to_rpi5.feed_data(json.dumps(final).encode() + b"\n")

        task = asyncio.create_task(fake_rpi4("result"))
        ok = await asyncio.wait_for(client.execute(["a"], appliance_id="microwave"), 2)
        await task
        task = asyncio.create_task(fake_rpi4("error"))
        with pytest.raises(ActLinkError):
            await asyncio.wait_for(client.execute(["a"], appliance_id="microwave"), 2)
        await task
        await client.stop()
        return ok

    ok = asyncio.run(_t())
    assert ok.success is True and ok.retry == 0


def test_job_observer_sees_start_and_end_with_sequence_id():
    events: list[tuple[str, dict]] = []
    _roundtrip(_controller([]), job_observer=lambda e, f: events.append((e, f)))
    assert [e for e, _ in events] == ["job_start", "job_end"]
    assert events[0][1]["sequence_id"] == events[1][1]["sequence_id"] == "seq-p"
    assert events[0][1]["progress"] is True and events[1][1]["outcome"] == "success"


def test_serial_motion_client_keeps_mcu_reported_position():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    try:
        client = SerialMotionClient(pipe.host, REHEARSAL_CONFIG, poll_s=0.01)
        assert client.last_position is None
        client.status()
        assert client.last_position["a_counts"] == 0  # status 응답의 a·b·z
        client.home()
        client.press(PressCommand("시작", x_mm=10.0, y_mm=5.0))
        pos = client.last_position
    finally:
        mcu.close()
    assert pos["source"] == "mcu_event"  # 펌웨어의 position 이벤트(ok 직전)
    assert (pos["a_counts"], pos["b_counts"]) == (mcu.a, mcu.b) and pos["a_counts"] != 0
    assert pos["x_mm"] == pytest.approx(10.0, abs=0.05) and pos["y_mm"] == pytest.approx(5.0, abs=0.05)


def test_act_main_motion_log_and_recorder_share_sequence_id_and_clock(monkeypatch, tmp_path):
    """SIMPLELAY_MOTION_LOG_PATH: MCU 원시 줄(>> <<)과 job 표시(##)가 mono_ns 시각축으로 남고,
    원시 기록기에도 같은 sequence_id의 job_start/job_end가 찍힌다."""
    import rpi4.act_main as act_main
    from rpi.verifier.recorder import LiveRecorder

    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe, homed=True)
    log_path = tmp_path / "motion.log"
    monkeypatch.setenv("SIMPLELAY_MOTION_LOG_PATH", str(log_path))
    monkeypatch.setenv("SIMPLELAY_MOTION_MODE", "serial")
    monkeypatch.setenv("SIMPLELAY_MOTION_PORT", "/dev/test-mcu")
    monkeypatch.setenv("SIMPLELAY_MOTION_BAUD", "115200")
    monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
    from rpi.controller.serial_motion import MotionConfig

    # 리허설용 임의 기구 값(실물 아님) — act_main은 MotionConfig.from_env()로 읽는다.
    monkeypatch.setattr(MotionConfig, "from_env", classmethod(lambda cls, env=None: REHEARSAL_CONFIG))
    line_log, stream = act_main._build_motion_log()
    recorder = LiveRecorder(tmp_path / "rec.jsonl")
    try:
        grbl, _ = act_main._build_motion(line_log=line_log)
        observe = act_main._job_observer(recorder, line_log)
        observe("job_start", {"sequence_id": "seq-j", "buttons": ["시작"]})
        grbl.press(PressCommand("시작", x_mm=10.0, y_mm=5.0))
        observe("job_end", {"sequence_id": "seq-j", "outcome": "success"})
    finally:
        mcu.close()
        recorder.close()
        stream.close()
    lines = log_path.read_text(encoding="utf-8").splitlines()
    tags = [line.split(" ", 3)[2] for line in lines]
    assert tags[0] == ">>" and "##" in tags and ">>" in tags and "<<" in tags
    assert all(line.split(" ", 3)[1].startswith("mono_ns=") for line in lines)
    marks = [line for line in lines if line.split(" ", 3)[2] == "##"]
    assert marks[0].split(" ", 3)[3].startswith("job_start ") and '"seq-j"' in marks[0]
    assert '"position"' in "\n".join(lines)  # 펌웨어의 위치 이벤트가 원시 줄에 남는다
    rows = [json.loads(r) for r in (tmp_path / "rec.jsonl").read_text(encoding="utf-8").splitlines()]
    job_rows = [r for r in rows if r.get("event") in ("job_start", "job_end")]
    assert [r["event"] for r in job_rows] == ["job_start", "job_end"]
    assert all("sequence_id=seq-j" in r["note"] for r in job_rows)
    # 같은 monotonic 시각축: 기록기 job_start ≤ 줄 기록의 job_end
    end_ns = int(marks[-1].split(" ", 3)[1].removeprefix("mono_ns="))
    assert job_rows[0]["t_monotonic_ns"] <= end_ns
