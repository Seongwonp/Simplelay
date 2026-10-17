"""RPi4 세탁 끝 관찰(rpi4/services/appliance_done_watch.py) — 가짜 콘센트 모듈·합성 음으로만 시험.

가짜 출력은 합성 전력이라 판정은 모의(source=mock)로 표시된다. 실물 세탁기·CT·마이크 미검증.
"""

from __future__ import annotations

import asyncio
import time

import numpy as np
import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.routines import RoutineEngine, RoutineStore, build_routine
from rpi.services.act_client import ActClient
from rpi.services.appliance_done import parse_appliance_done
from rpi.tests.test_routines import THU_0730, FakeCare, FakeService, FakeSuggestions, FixedClock
from rpi.tools.fake_outlet import open_fake_outlet
from rpi.verifier import FakeAudioReader, MockVerifier
from rpi.verifier.cycle_end import CycleEndConfig
from rpi.verifier.done_fusion import DoneFusionConfig
from rpi.verifier.end_beep import EndBeepConfig
from rpi.verifier.outlet import OutletConfig, OutletLink
from rpi.verifier.power import PowerSample

from rpi4.services.act_executor import ActExecutor
from rpi4.services.appliance_done_watch import (
    ApplianceDoneWatch,
    DoneWatchSpec,
    PowerCycleFeeder,
    parse_done_watch,
)
from rpi4.services.danger_sound_monitor import DangerSoundMonitor
from rpi4.tests.test_act_executor import FakeWriter
from rpi4.tests.test_act_link_integration import _make_link

RATE, CHUNK = 16_000, 512
FRAME_S = CHUNK / RATE
CYCLE = CycleEndConfig(run_min_w=100.0, min_run_s=5.0, standby_max_w=15.0, settle_s=3.0, max_gap_s=5.0)
BEEP = EndBeepConfig(freq_low_hz=2000, freq_high_hz=3000, min_beeps=3, max_beeps=6,
                     min_period_s=0.3, max_period_s=1.2, silence_after_s=2.0)
FUSION = DoneFusionConfig(window_s=60.0, wait_s=30.0, cooldown_s=600.0)


def _beep_frames(t0=0.0, beeps=3):
    frames, t = [], t0
    tone = FakeAudioReader.tone(2500.0, CHUNK, RATE)
    silence = np.zeros(CHUNK, dtype=np.float32)
    for i in range(beeps):
        start = t0 + i * 0.6
        while t < start:
            frames.append((silence, t))
            t += FRAME_S
        while t < start + 0.2:
            frames.append((tone, t))
            t += FRAME_S
    while t < t0 + beeps * 0.6 + 3.0:
        frames.append((silence, t))
        t += FRAME_S
    return frames


def _power(segments, t0=0.0):
    out, t = [], t0
    for duration, watts in segments:
        end = t + duration
        while t < end - 1e-9:
            out.append(PowerSample(t, watts))
            t += 0.5
    return out


# ── 설정 해석 ──────────────────────────────────────────────────────────────


def test_parse_done_watch():
    assert parse_done_watch("") is None
    assert parse_done_watch("washer:outlet,mic") == DoneWatchSpec("washer", ("power", "beep"))
    assert parse_done_watch("washer:outlet") == DoneWatchSpec("washer", ("power",))
    assert parse_done_watch(" washer : mic , outlet ") == DoneWatchSpec("washer", ("power", "beep"))
    for bad in ("washer", "washer:", ":outlet", "washer:door", "washer:outlet;dryer:outlet", "세탁기:outlet"):
        with pytest.raises(RuntimeError):
            parse_done_watch(bad)


# ── 관찰 단위(시계 주입) ─────────────────────────────────────────────────────


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def _watch(inputs=("power", "beep"), clock=None):
    sent = []
    watch = ApplianceDoneWatch(DoneWatchSpec("washer", inputs), sent.append, cycle_config=CYCLE,
                               beep_config=BEEP, fusion_config=FUSION, power_source="real",
                               beep_source="real", clock=clock or Clock())
    return watch, sent


def test_power_end_and_beep_confirm_one_frame():
    clock = Clock()
    watch, sent = _watch(clock=clock)
    for pcm, t in _beep_frames(t0=20.0):
        clock.t = t
        watch.feed_audio(pcm, t)
    assert sent == []  # 종료음만 — 짝을 기다린다
    for s in _power([(2, 3), (15, 400), (5, 3)], t0=8.0):
        clock.t = max(clock.t, s.t_s)
        watch.feed_power(s)
    assert len(sent) == 1
    frame = sent[0]
    assert frame["type"] == "appliance_done" and frame["state"] == "done_confirmed"
    assert frame["source"] == "real" and set(frame["inputs"]) == {"power", "beep"}
    assert frame["evidence"]["power"]["peak_w"] == pytest.approx(400.0)
    assert frame["evidence"]["beep"]["beeps"] == 3
    assert "t_monotonic_ns" in frame


def test_power_only_waits_then_reports_probable():
    clock = Clock()
    watch, sent = _watch(clock=clock)
    for s in _power([(2, 3), (15, 400), (5, 3)]):
        clock.t = s.t_s
        watch.feed_power(s)
    assert sent == []
    clock.t += FUSION.wait_s + 1
    watch.poll()
    assert [f["state"] for f in sent] == ["done_power_only"]


def test_power_only_spec_reports_immediately_and_ignores_audio():
    watch, sent = _watch(inputs=("power",))
    for pcm, t in _beep_frames():
        watch.feed_audio(pcm, t)
    assert sent == []
    for s in _power([(2, 3), (15, 400), (5, 3)]):
        watch.feed_power(s)
    assert [f["state"] for f in sent] == ["done_power_only"]


def test_stream_gap_restarts_the_standby_count():
    watch, sent = _watch(inputs=("power",))
    for s in _power([(2, 3), (15, 400), (2, 3)]):
        watch.feed_power(s)
    watch.note_power_gap()
    for s in _power([(2, 3)], t0=19.0):
        watch.feed_power(s)
    assert sent == []


# ── 끝까지: 가짜 콘센트 모듈 + 합성 음 → RPi4 프레임 → RPi5 루틴 안내 ────────────


def _controller():
    return ClosedLoopController(grbl=MockGrblClient(), verifier=MockVerifier(outcomes=[True] * 5),
                                alerts=MockAlertSink(), safety=MockSafetyController())


def test_end_to_end_fake_outlet_and_mock_audio_reach_the_routine_notice():
    store = RoutineStore()
    care = FakeCare()
    engine = RoutineEngine(store, FakeSuggestions(), FakeService(), FixedClock(THU_0730), care_events=care)
    store.save(build_routine({"name": "세탁 끝 알림", "mode": "notify",
                              "trigger": {"kind": "event", "event": "wash_complete"},
                              "steps": [{"kind": "announce", "text": "빨래를 꺼내 널어 주세요"}]},
                             routine_id=store.new_id(), now=THU_0730))
    received: list[dict] = []

    def on_done(doc):
        received.append(doc)
        engine.on_appliance_done(parse_appliance_done(doc))

    pipe, fake = open_fake_outlet(speed=50.0, relay_on=True)
    link = OutletLink(pipe.host, OutletConfig(heartbeat_s=None, status_poll_s=None), mock=True).start()

    async def _t():
        rpi4_reader, rpi4_writer, rpi5_reader, rpi5_writer = _make_link()
        executor = ActExecutor(rpi4_reader, rpi4_writer, _controller())
        client = ActClient(rpi5_reader, rpi5_writer, on_appliance_done=on_done)
        await client.start()
        loop = asyncio.get_running_loop()
        watch = ApplianceDoneWatch(
            DoneWatchSpec("washer", ("power", "beep")), executor.thread_safe_done_emitter(loop),
            cycle_config=CYCLE, beep_config=BEEP, fusion_config=FUSION,
            power_source="mock", beep_source="mock")
        feeder = PowerCycleFeeder(link, watch).start()
        try:
            base = time.monotonic()
            frames = _beep_frames(t0=base)
            times = iter([t for _, t in frames])
            monitor = DangerSoundMonitor(FakeAudioReader([pcm for pcm, _ in frames]), executor,
                                         clock=lambda: next(times), frame_listeners=[watch.feed_audio],
                                         danger=False)
            for _ in frames:
                await monitor.tick()
            fake.start_run(run_s=8.0, run_w=400.0, tail_s=0.1, tail_w=3.0)
            deadline = time.monotonic() + 5.0
            while not received and time.monotonic() < deadline:
                await asyncio.sleep(0.02)
        finally:
            feeder.stop()
            feeder.join(2.0)
            await client.stop()

    try:
        asyncio.run(_t())
    finally:
        link.close()
        fake.close()
    assert len(received) == 1, received
    frame = received[0]
    assert frame["state"] == "done_confirmed" and frame["source"] == "mock"
    message = care.events[-1][1]
    assert "세탁이 끝났어요" in message and "연습 신호예요." in message
    # 세탁기는 CT 계측만 — 관찰이 콘센트 릴레이 명령을 하나도 보내지 않는다.
    assert not [d for d in fake.received if str(d.get("cmd", "")).startswith("relay")]


def test_danger_monitor_shares_frames_and_can_skip_danger_detection():
    async def _t():
        writer = FakeWriter()
        executor = ActExecutor(asyncio.StreamReader(), writer, _controller())
        seen = []
        tone = FakeAudioReader.tone(3500.0, CHUNK, RATE)
        times = iter([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5])
        silence = np.zeros(CHUNK, dtype=np.float32)
        frames = [tone, silence] * 4
        monitor = DangerSoundMonitor(FakeAudioReader(frames), executor, clock=lambda: next(times),
                                     frame_listeners=[lambda pcm, t: seen.append(t)], danger=False)
        for _ in frames:
            await monitor.tick()
        assert seen == [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5]
        assert writer.messages() == []  # 위험 소리 판정은 껐다

    asyncio.run(_t())


# ── act_main 배선 ────────────────────────────────────────────────────────────


def test_act_main_done_watch_wiring(monkeypatch):
    from rpi4 import act_main

    async def _t():
        executor = ActExecutor(asyncio.StreamReader(), FakeWriter(), _controller())
        monkeypatch.delenv("SIMPLELAY_DONE_WATCH", raising=False)
        assert act_main._build_done_watch(None, executor) is None
        monkeypatch.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet,mic")
        with pytest.raises(RuntimeError):
            act_main._build_done_watch(None, executor)  # CT가 없으면 기동 거절
        pipe, fake = open_fake_outlet(speed=50.0, relay_on=True)
        link = OutletLink(pipe.host, OutletConfig(heartbeat_s=None, status_poll_s=None), mock=True).start()
        try:
            monkeypatch.setenv("SIMPLELAY_CYCLE_SETTLE_S", "400")
            [(watch, feeder)] = act_main._build_done_watch(link, executor)
            assert watch.spec.inputs == ("power", "beep")
            assert watch.power_source == "mock"  # 가짜 콘센트 모듈 → 모의로 표시
            assert watch.fusion.config.wait_s >= 400 + watch.fusion.config.window_s
            feeder.stop()
            feeder.join(2.0)
        finally:
            link.close()
            fake.close()

    asyncio.run(_t())
