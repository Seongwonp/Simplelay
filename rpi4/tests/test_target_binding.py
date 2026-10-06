"""실행 대상 ↔ CT 채널 결속(2026-10-07, 인계 노트북-3 §B, 평가 HIGH H3).

execute에 대상 가전(``appliance_id``)이 필수이고, RPi4는 그 대상의 CT 채널로 L3·정지 확인을 고른다.
완료 기준: **전자레인지 채널 변화로 세탁기·인터폰 실행이나 정지가 확인되는 경우 0.**

가짜 콘센트 모듈(합성 전력)로만 시험한다 — 실물 CT·세탁기·인터폰 미검증, 기준값 전부 측정 필요.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from rpi4 import act_main
from rpi4.models.act_messages import ExecuteMsg, HoldPlan, parse_act_message

_ENV = ("SIMPLELAY_OUTLET_CHANNELS", "SIMPLELAY_DONE_WATCH", "SIMPLELAY_L3_MODE", "SIMPLELAY_MOTION_MODE",
        "SIMPLELAY_OUTLET_RELAY_ON_START", "SIMPLELAY_RECORDER_PATH", "SIMPLELAY_FAKE_OUTLET_RELAY_CH",
        "SIMPLELAY_FAKE_OUTLET_CHANNELS", "SIMPLELAY_SENSORS_ENABLED", "SIMPLELAY_L3_NONE_TARGETS",
        "SIMPLELAY_DEMO_PACING")


class _Writer:
    def __init__(self) -> None:
        self.buf = b""

    def write(self, data: bytes) -> None:
        self.buf += data

    async def drain(self) -> None:
        pass

    def docs(self) -> list[dict]:
        return [json.loads(line) for line in self.buf.split(b"\n") if line.strip()]


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


@pytest.fixture
def outlet_env(monkeypatch):
    """가짜 모듈 CT 2채널(전자레인지 0 = 릴레이 채널, 세탁기 1), L3 real, 릴레이 켬."""
    for name in _ENV:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "fake")
    monkeypatch.setenv("SIMPLELAY_OUTLET_HEARTBEAT_MS", "off")
    monkeypatch.setenv("SIMPLELAY_OUTLET_STATUS_POLL_MS", "off")
    monkeypatch.setenv("SIMPLELAY_OUTLET_CHANNELS", "microwave:0,washer:1")
    monkeypatch.setenv("SIMPLELAY_OUTLET_RELAY_ON_START", "1")
    monkeypatch.setenv("SIMPLELAY_L3_MODE", "real")
    import rpi.tools.fake_outlet as fake_outlet_module

    real_open = fake_outlet_module.open_fake_outlet
    monkeypatch.setattr(fake_outlet_module, "open_fake_outlet", lambda **kw: real_open(speed=50.0, **kw))
    yield monkeypatch
    if act_main._fake_outlet is not None:  # noqa: SLF001
        act_main._fake_outlet.close()  # noqa: SLF001
        act_main._fake_outlet = None  # noqa: SLF001


def _microwave_rises_at_sequence_end(monkeypatch) -> list:
    """가짜 모듈의 자동 가동(리허설용 ``start_run``)을 바꿔 **늘 전자레인지 채널(0)만** 돌게 한다.

    대상 가전 채널은 그대로 대기 전력이다. 이때 대상이 세탁기·인터폰이면 확인되면 안 된다.
    """
    from rpi.tools.fake_outlet import FakeOutlet

    calls: list = []
    real_start = FakeOutlet.start_run

    def start_run(self, *args, ch=None, **kwargs):
        calls.append(ch)
        return real_start(self, run_s=5.0, ch=0)

    monkeypatch.setattr(FakeOutlet, "start_run", start_run)
    return calls


def _run_frames(frames: list[dict], *, grbl=None, timeout: float = 15.0) -> tuple[list[dict], object]:
    """act_main 실제 배선(_build_outlet → _build_executor)으로 실행기를 돌려 프레임을 처리한다."""
    pressed: list = []

    async def _t():
        link = act_main._build_outlet()
        reader, writer = asyncio.StreamReader(), _Writer()
        try:
            executor = act_main._build_executor(reader, writer, outlet=link)
            raw = executor._controller._grbl  # noqa: SLF001
            pressed.append(raw)
            task = asyncio.create_task(executor.run())
            for frame in frames:
                _feed(reader, frame)
                deadline = time.monotonic() + timeout
                while not any(d.get("sequence_id") == frame["sequence_id"]
                              and d.get("type") in ("result", "error") for d in writer.docs()):
                    assert time.monotonic() < deadline, writer.docs()
                    await asyncio.sleep(0.02)
            reader.feed_eof()
            await asyncio.wait_for(task, 5.0)
            await executor.shutdown()
        finally:
            link.close()
        return writer.docs()

    docs = asyncio.run(_t())
    return docs, pressed[0]


def _final(docs: list[dict], seq: str) -> dict:
    return next(d for d in docs if d.get("sequence_id") == seq and d.get("type") in ("result", "error"))


# ── 프레임: 대상 필수 ──────────────────────────────────────────────────────────


def test_execute_without_target_is_not_a_runnable_execute():
    msg = parse_act_message(json.dumps({"type": "execute", "sequence_id": "s1", "buttons": ["시작"]}))
    assert not isinstance(msg, ExecuteMsg)
    assert getattr(msg, "reason", None) == "target_required"
    assert msg.sequence_id == "s1"


def test_execute_with_target_carries_it_and_hold_must_match():
    msg = parse_act_message(json.dumps({"type": "execute", "sequence_id": "s1", "buttons": ["시작"],
                                        "appliance_id": "washer"}))
    assert isinstance(msg, ExecuteMsg) and msg.appliance_id == "washer"
    hold = {"stop_button": "정지", "stop_x_mm": 10, "stop_y_mm": 10, "stop_presses": 1,
            "park_x_mm": 0, "park_y_mm": 0}
    # 대기 계획의 대상이 실행 대상과 다르면 실행하지 않는다(다른 가전 정지 버튼을 누르지 않게) — 거절로 답한다
    assert not isinstance(parse_act_message(json.dumps({"type": "execute", "sequence_id": "s1", "buttons": ["시작"],
                                                        "appliance_id": "washer",
                                                        "hold": {**hold, "appliance_id": "microwave"}})),
                          ExecuteMsg)
    ok = parse_act_message(json.dumps({"type": "execute", "sequence_id": "s1", "buttons": ["시작"],
                                       "appliance_id": "washer", "hold": hold}))
    assert ok.hold.appliance_id == "washer"  # 계획에 대상이 없으면 실행 대상으로 채운다


def test_executor_refuses_a_frame_without_target(outlet_env):
    docs, grbl = _run_frames([{"type": "execute", "sequence_id": "legacy", "buttons": ["시작"]}])
    final = _final(docs, "legacy")
    assert final["type"] == "error" and final["reason"] == "target_required"
    assert grbl.commands == []  # 누르지 않았다


# ── L3: 대상 채널로만 판정 ─────────────────────────────────────────────────────


def test_microwave_channel_rise_confirms_the_microwave(outlet_env):
    """대조군 — 이 배선에서 전자레인지 채널 상승은 실제로 확인으로 읽힌다."""
    _microwave_rises_at_sequence_end(outlet_env)
    docs, _ = _run_frames([{"type": "execute", "sequence_id": "mw", "buttons": ["즉석밥", "시작"],
                            "appliance_id": "microwave"}])
    final = _final(docs, "mw")
    assert final["type"] == "result" and final["operation_confirmed"] is True, final


def test_microwave_channel_rise_never_confirms_a_washer_execution(outlet_env):
    _microwave_rises_at_sequence_end(outlet_env)
    docs, _ = _run_frames([{"type": "execute", "sequence_id": "wash", "buttons": ["시작"],
                            "appliance_id": "washer"}])
    final = _final(docs, "wash")
    assert final.get("operation_confirmed") is not True, final
    assert final["type"] == "result" and final["success"] is False  # L3 미확인 → 안전 정지


def test_unmapped_target_with_real_l3_is_refused_before_pressing(outlet_env):
    _microwave_rises_at_sequence_end(outlet_env)
    docs, grbl = _run_frames([{"type": "execute", "sequence_id": "door", "buttons": ["열림"],
                               "appliance_id": "intercom"}])
    final = _final(docs, "door")
    assert final["type"] == "error" and final["reason"] == "target_unbound", final
    assert "intercom" in final["detail"]
    assert grbl.commands == []


def test_unmapped_target_is_allowed_when_declared_without_power_l3(outlet_env):
    """전력으로 볼 수 없는 가전(인터폰)은 명시하면 L3 없이(operation_confirmed=null) 실행한다."""
    outlet_env.setenv("SIMPLELAY_L3_NONE_TARGETS", "intercom")
    _microwave_rises_at_sequence_end(outlet_env)
    docs, grbl = _run_frames([{"type": "execute", "sequence_id": "door", "buttons": ["열림"],
                               "appliance_id": "intercom"}])
    final = _final(docs, "door")
    assert final["type"] == "result" and final["success"] is True
    assert final["operation_confirmed"] is None  # 전자레인지 상승을 증거로 쓰지 않는다
    assert [c.button for c in grbl.commands] == ["열림"]


def test_empty_channel_map_binds_only_the_press_appliance(outlet_env):
    """대응이 비면(CT 하나 시절) 채널 0은 전자레인지 것이다 — 세탁기를 채널 0으로 판정하지 않는다."""
    outlet_env.delenv("SIMPLELAY_OUTLET_CHANNELS")
    _microwave_rises_at_sequence_end(outlet_env)
    docs, grbl = _run_frames([{"type": "execute", "sequence_id": "wash", "buttons": ["시작"],
                               "appliance_id": "washer"}])
    final = _final(docs, "wash")
    assert final["type"] == "error" and final["reason"] == "target_unbound", final
    assert grbl.commands == []


# ── 정지 확인: 대기 계획 대상의 채널 ──────────────────────────────────────────


class _RealishGrbl:
    """mock이 아닌 모션 어댑터 자리(정지 대기가 전력 확인을 쓰는 경로). 실제로 움직이지 않는다."""

    def __init__(self) -> None:
        self.commands: list = []

    def press(self, command) -> None:
        self.commands.append(command)

    def move_to(self, x_mm: float, y_mm: float) -> None:
        pass


def _plan(appliance_id: str) -> HoldPlan:
    return HoldPlan("정지", 10.0, 10.0, 1, 0.0, 0.0, None, appliance_id)


def test_stop_probe_reads_the_hold_target_channel_not_the_microwave(outlet_env):
    from rpi.controller.mock import MockSafetyController

    outlet_env.setattr(act_main, "_build_motion", lambda **_kw: (_RealishGrbl(), MockSafetyController()))

    async def _t():
        link = act_main._build_outlet()
        try:
            executor = act_main._build_executor(asyncio.StreamReader(), _Writer(), outlet=link)
            fake = act_main._fake_outlet  # noqa: SLF001
            # 세탁기(채널 1)는 돌고 있고 전자레인지(채널 0)는 꺼져 있다.
            fake.start_run(run_s=60.0, run_w=500.0, ch=1)
            await asyncio.sleep(0.4)
            hw = executor._hold_hw  # noqa: SLF001
            washer = hw.probe_factory(_plan("washer"))
            intercom = hw.probe_factory(_plan("intercom"))
            deadline = time.monotonic() + 3.0
            while washer.running() is None and time.monotonic() < deadline:
                await asyncio.sleep(0.02)
            return washer.running(), intercom.source, getattr(intercom, "running")()
        finally:
            link.close()

    washer_running, intercom_source, intercom_running = asyncio.run(_t())
    # 전자레인지 채널이 꺼져 있어도 세탁기 정지가 확인되지 않는다(세탁기 채널은 켜짐).
    assert washer_running is True
    # 대응 없는 대상은 전력 근거가 없다 — '모름'(정지는 미확인으로만 끝난다).
    assert intercom_source == "none" and intercom_running is None


# ── 교차 리뷰(92876bd) 수리: 결속 실패가 실행기 루프를 죽이지 않는다 ─────────────


def test_bad_tail_env_refuses_at_startup_not_on_first_execute(outlet_env):
    """잘못된 잔여 전류 설정은 시작 때 거절한다 — 첫 실행에서 터져 루프가 죽지 않게."""
    outlet_env.setenv("SIMPLELAY_TAIL_OFF_MAX_W", "abc")

    async def _t():
        link = act_main._build_outlet()
        try:
            with pytest.raises(RuntimeError, match="SIMPLELAY_TAIL_OFF_MAX_W"):
                act_main._build_executor(asyncio.StreamReader(), _Writer(), outlet=link)
        finally:
            link.close()

    asyncio.run(_t())


def test_unexpected_bind_failure_answers_error_and_keeps_the_loop(outlet_env):
    """결속 중 예상 밖 예외 → ``target_bind_failed`` 오류로 답하고, 다음 실행은 그대로 받는다."""

    async def _t():
        link = act_main._build_outlet()
        reader, writer = asyncio.StreamReader(), _Writer()
        try:
            executor = act_main._build_executor(reader, writer, outlet=link)
            binder = executor._target_binder  # noqa: SLF001
            real_bind = binder.bind
            calls = {"n": 0}

            def flaky_bind(appliance_id):
                calls["n"] += 1
                if calls["n"] == 1:
                    raise RuntimeError("boom")
                return real_bind(appliance_id)

            binder.bind = flaky_bind
            task = asyncio.create_task(executor.run())
            for seq in ("bad", "good"):
                _feed(reader, {"type": "execute", "sequence_id": seq, "buttons": ["즉석밥", "시작"],
                               "appliance_id": "microwave"})
                deadline = time.monotonic() + 15.0
                while not any(d.get("sequence_id") == seq and d.get("type") in ("result", "error")
                              for d in writer.docs()):
                    assert not task.done(), writer.docs()
                    assert time.monotonic() < deadline, writer.docs()
                    await asyncio.sleep(0.02)
            reader.feed_eof()
            await asyncio.wait_for(task, 5.0)
            await executor.shutdown()
        finally:
            link.close()
        return writer.docs()

    docs = asyncio.run(_t())
    bad = _final(docs, "bad")
    assert bad["type"] == "error" and bad["reason"] == "target_bind_failed", bad
    assert _final(docs, "good")["type"] == "result"


def test_hold_for_another_target_is_answered_not_dropped():
    hold = {"stop_button": "정지", "stop_x_mm": 10, "stop_y_mm": 10, "stop_presses": 1,
            "park_x_mm": 0, "park_y_mm": 0, "appliance_id": "microwave"}
    msg = parse_act_message(json.dumps({"type": "execute", "sequence_id": "s1", "buttons": ["시작"],
                                        "appliance_id": "washer", "hold": hold}))
    assert msg is not None and not isinstance(msg, ExecuteMsg)
    assert msg.reason == "hold_target_mismatch" and msg.sequence_id == "s1"
    assert "microwave" in msg.detail and "washer" in msg.detail
