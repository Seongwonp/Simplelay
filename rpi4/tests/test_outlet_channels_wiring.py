"""RPi4 배선 — CT 두 채널(2026-10-06): 전자레인지 L3는 전자레인지 채널, 세탁 끝 관찰은 세탁기 채널을 읽는다.

가짜 콘센트 모듈(합성 전력)로만 시험한다. 실물 CT·세탁기·전자레인지 미검증, 기준값 전부 측정 필요.
"""

from __future__ import annotations

import asyncio
import time

import pytest

from rpi.controller.power_operation import OutletOperationVerifier
from rpi4 import act_main
from rpi4.services.act_executor import ActExecutor
from rpi4.services.appliance_done_watch import DoneWatchSpec, parse_done_watches
from rpi4.tests.test_act_executor import FakeWriter
from rpi4.tests.test_appliance_done_watch import _controller


@pytest.fixture
def fake_env(monkeypatch):
    for name in ("SIMPLELAY_OUTLET_CHANNELS", "SIMPLELAY_DONE_WATCH", "SIMPLELAY_L3_MODE",
                 "SIMPLELAY_MOTION_MODE", "SIMPLELAY_OUTLET_RELAY_ON_START", "SIMPLELAY_RECORDER_PATH",
                 "SIMPLELAY_FAKE_OUTLET_RELAY_CH", "SIMPLELAY_FAKE_OUTLET_CHANNELS"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_OUTLET_PORT", "fake")
    monkeypatch.setenv("SIMPLELAY_OUTLET_HEARTBEAT_MS", "off")
    monkeypatch.setenv("SIMPLELAY_OUTLET_STATUS_POLL_MS", "off")
    yield monkeypatch
    if act_main._fake_outlet is not None:  # noqa: SLF001
        act_main._fake_outlet.close()  # noqa: SLF001
        act_main._fake_outlet = None  # noqa: SLF001


def test_parse_done_watches_allows_one_entry_per_appliance_and_one_mic():
    assert parse_done_watches("") == ()
    assert parse_done_watches("washer:outlet,mic;microwave:outlet") == (
        DoneWatchSpec("washer", ("power", "beep")), DoneWatchSpec("microwave", ("power",)))
    for bad in ("washer:outlet;washer:mic",       # 같은 가전 두 번
                "washer:mic;microwave:mic",       # 마이크는 하나
                "washer:outlet;;", "washer:door"):
        with pytest.raises(RuntimeError):
            parse_done_watches(bad)


def test_fake_module_gets_the_mapped_channel_count_and_l3_reads_the_microwave_channel(fake_env):
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "washer:0,microwave:1")
    fake_env.setenv("SIMPLELAY_FAKE_OUTLET_RELAY_CH", "1")  # 가짜 모듈 릴레이는 대응에서 베끼지 않는다(평가 A2)
    fake_env.setenv("SIMPLELAY_L3_MODE", "real")
    link = act_main._build_outlet()
    try:
        assert act_main._fake_outlet.channels == 2  # noqa: SLF001
        assert act_main._fake_outlet.relay_channel == 1  # 릴레이는 전자레인지 채널  # noqa: SLF001
        executor = act_main._build_executor(object(), object(), outlet=link)  # type: ignore[arg-type]
        operation = executor._controller._operation  # noqa: SLF001
        assert isinstance(operation, OutletOperationVerifier)
        assert operation.link.channel == 1
        assert executor._after_result._link.channel == 1  # noqa: SLF001 - 꼬리 관찰도 같은 채널
    finally:
        link.close()


def test_mapping_without_the_watched_appliance_refuses_to_start(fake_env):
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "microwave:0")
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet")
    # 2026-10-06 평가 A1: 포트를 열기 전(_build_outlet)에 거절한다.
    with pytest.raises(RuntimeError, match="washer"):
        act_main._build_outlet()


def test_washer_done_comes_from_its_own_channel_while_the_microwave_relay_is_off(fake_env):
    """세탁기 채널은 릴레이를 거치지 않는다 — 릴레이(전자레인지)가 꺼져 있어도 세탁 끝을 본다."""
    fake_env.setenv("SIMPLELAY_OUTLET_CHANNELS", "microwave:0,washer:1")
    fake_env.setenv("SIMPLELAY_DONE_WATCH", "washer:outlet;microwave:outlet")
    for name, value in (("RUN_MIN_W", "100"), ("MIN_RUN_S", "2"), ("STANDBY_MAX_W", "15"),
                        ("SETTLE_S", "1"), ("MAX_GAP_S", "5")):
        fake_env.setenv(f"SIMPLELAY_CYCLE_{name}", value)
    import rpi.tools.fake_outlet as fake_outlet_module

    real_open = fake_outlet_module.open_fake_outlet
    fake_env.setattr(fake_outlet_module, "open_fake_outlet", lambda **kw: real_open(speed=20.0, **kw))
    link = act_main._build_outlet()
    fake = act_main._fake_outlet  # noqa: SLF001
    sent: list[dict] = []

    async def _t():
        executor = ActExecutor(asyncio.StreamReader(), FakeWriter(), _controller())
        executor.thread_safe_done_emitter = lambda loop: sent.append  # type: ignore[method-assign]
        watches = act_main._build_done_watch(link, executor)
        try:
            by_id = {w.spec.appliance_id: (w, f) for w, f in watches}
            assert by_id["washer"][1].channel == 1 and by_id["microwave"][1].channel == 0
            assert by_id["washer"][0].event == "wash_complete"
            assert by_id["microwave"][0].event == "heat_complete"  # 세탁 끝 루틴을 깨우지 않는다
            assert fake.relay_on is False
            fake.start_run(run_s=4.0, run_w=500.0, tail_s=0.1, tail_w=3.0, ch=1)
            deadline = time.monotonic() + 5.0
            while not sent and time.monotonic() < deadline:
                await asyncio.sleep(0.02)
        finally:
            for _, feeder in watches:
                if feeder is not None:
                    feeder.stop()
                    feeder.join(2.0)

    try:
        asyncio.run(_t())
    finally:
        link.close()
    assert [(f["appliance_id"], f["event"], f["state"]) for f in sent] == [
        ("washer", "wash_complete", "done_power_only")]
    assert not [d for d in fake.received if str(d.get("cmd", "")).startswith("relay")]


def test_cycle_config_per_appliance_precedence():
    from rpi.verifier.cycle_end import CycleEndConfig

    env = {"SIMPLELAY_CYCLE_SETTLE_S": "180", "SIMPLELAY_CYCLE_MICROWAVE_SETTLE_S": "8"}
    assert CycleEndConfig.for_appliance("microwave", env).settle_s == 8.0  # 가전 이름이 붙은 값이 이긴다
    assert CycleEndConfig.for_appliance("washer", env).settle_s == 180.0
    assert CycleEndConfig.for_appliance("microwave", {}).min_run_s == 10.0  # 전자레인지 설계 초기값(측정 필요)
    assert CycleEndConfig.for_appliance("washer", {}) == CycleEndConfig()
    with pytest.raises(RuntimeError):
        CycleEndConfig.for_appliance("microwave", {"SIMPLELAY_CYCLE_MICROWAVE_RUN_MIN_W": "x"})
