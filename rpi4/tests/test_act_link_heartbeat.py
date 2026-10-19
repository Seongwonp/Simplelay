"""G5(안전 계약 적용 보고 2026-10-15 §2) — 실행 중 RPi5→RPi4 생존 신호가 끊기면 RPi4가 스스로 멈춘다(RPi4 쪽).

수리 전: Wi-Fi가 조용히 끊기면 RPi4는 RPi5의 정지를 받을 길이 없는데도 남은 버튼을 계속 눌렀다(링크 끊김을 알아채기까지
TCP keepalive 약 11 s 추정 — 그 사이 실행은 그대로).

규약(링크 생존 신호 규약 1, 하위 호환): RPi4는 ``act_info.heartbeat_protocol: 1``을 알린다. 그것을 본 RPi5는 ``execute``에
``heartbeat_s``(보내는 주기)를 싣고, 결과를 받을 때까지 ``heartbeat``를 그 주기로 보낸다. RPi4는 ``heartbeat_s``가 실린
실행에서만 인증된 줄이 제한 시간(기본 3 s, 적어도 주기의 3배) 넘게 오지 않으면 **받은 정지와 같은 길**(컨트롤러
``request_stop`` → 모션 어댑터 정지, 재홈·재누름 없음)로 멈추고, 결과를 ``safety_stop``·``abort_reason: motion_link_lost``로
적으며, 다음 ``act_info``에 ``last_link_stop``을 한 번 싣는다. ``heartbeat_s`` 없는 실행(옛 RPi5)과 쉬는 중에는 요구하지 않는다.

시계는 가짜(``clock``) — 감시 판정은 ``check_link_watchdog()``를 직접 불러 잠 없이 본다. 배경 감시 작업 자체는 짧은 실제
시간 한 건으로만 확인한다. 실행 대상은 가짜 모션 — **실물 미검증.**
"""

from __future__ import annotations

import asyncio
import json
import threading

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockRetryWaiter, MockSafetyController
from rpi.controller.models import ExecutionMode
from rpi.verifier import MockVerifier
from rpi4.models.act_messages import ExecuteMsg, HeartbeatMsg, parse_act_message
from rpi4.services.act_executor import ActExecutor


class _Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


class _Writer:
    def __init__(self) -> None:
        self.docs: list[dict] = []

    def write(self, data: bytes) -> None:
        self.docs.extend(json.loads(x) for x in data.splitlines() if x.strip())

    async def drain(self) -> None:
        pass

    def of(self, kind: str) -> list[dict]:
        return [d for d in self.docs if d.get("type") == kind]


class _GateGrbl:
    """누름마다 ``release``가 열릴 때까지 붙잡는다(이동·누름 중인 모션 흉내). 정지 요청이 오면 연다."""

    execution_mode = ExecutionMode.MOCK

    def __init__(self) -> None:
        self.presses: list[object] = []
        self.entered = threading.Event()
        self.release = threading.Event()
        self.stops = 0

    def press(self, command) -> None:
        self.presses.append(command)
        self.entered.set()
        self.release.wait(5)

    def request_stop(self) -> None:
        self.stops += 1
        self.release.set()

    def reset_stop(self) -> None:
        pass


def _setup(**kwargs):
    reader, writer, grbl, clock = asyncio.StreamReader(), _Writer(), _GateGrbl(), _Clock()
    controller = ClosedLoopController(grbl, MockVerifier([True] * 20), MockAlertSink(), MockSafetyController(),
                                      retry_waiter=MockRetryWaiter())
    executor = ActExecutor(reader, writer, controller, clock=clock, **kwargs)
    return executor, reader, writer, grbl, clock


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


def _execute(seq: str = "s-1", heartbeat_s: float | None = 1.0, buttons=("b1", "b2", "b3")) -> dict:
    doc = {"type": "execute", "sequence_id": seq, "buttons": list(buttons), "appliance_id": "microwave",
           "run_ref": "r-" + seq}
    if heartbeat_s is not None:
        doc["heartbeat_s"] = heartbeat_s
    return doc


async def _start(executor, reader, grbl, doc) -> None:
    _feed(reader, doc)
    await executor.run_once()
    assert await asyncio.to_thread(grbl.entered.wait, 5)


async def _line(executor, reader, doc) -> None:
    _feed(reader, doc)
    await executor.run_once()


# ── 규약 모양 ────────────────────────────────────────────────────────────────


def test_act_info_announces_heartbeat_protocol():
    async def _t():
        executor, reader, writer, _grbl, _clock = _setup()
        await _line(executor, reader, {"type": "hello"})
        return writer

    (info,) = asyncio.run(_t()).of("act_info")
    assert info["heartbeat_protocol"] == 1
    assert info["heartbeat_timeout_s"] == 3.0
    assert "last_link_stop" not in info


def test_heartbeat_and_execute_period_parse():
    assert isinstance(parse_act_message('{"type":"heartbeat","sequence_id":"s-1"}'), HeartbeatMsg)
    assert isinstance(parse_act_message('{"type":"heartbeat"}'), HeartbeatMsg)
    msg = parse_act_message(json.dumps(_execute(heartbeat_s=0.5)))
    assert isinstance(msg, ExecuteMsg) and msg.heartbeat_s == 0.5
    # 모양이 틀린 주기는 '없음'(옛 RPi5와 같다) — 실행 자체는 그대로 받는다.
    for bad in ("1", 0, -1, 11, float("inf"), True):
        doc = _execute()
        doc["heartbeat_s"] = bad
        parsed = parse_act_message(json.dumps(doc))
        assert isinstance(parsed, ExecuteMsg) and parsed.heartbeat_s is None
    assert parse_act_message(json.dumps(_execute(heartbeat_s=None))).heartbeat_s is None


# ── 끊기면 스스로 멈춘다 ─────────────────────────────────────────────────────


def test_rpi4_stops_by_itself_when_heartbeats_stop():
    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute())
        clock.t += 2.9
        assert executor.check_link_watchdog() is False  # 아직 제한 시간 안
        clock.t += 0.2  # 마지막 줄 뒤 3.1 s — 생존 신호 없음
        executor.check_link_watchdog()
        await executor.wait_idle()
        return writer, grbl, executor

    writer, grbl, executor = asyncio.run(_t())
    assert grbl.stops >= 1  # 받은 정지와 같은 길(컨트롤러 → 모션 어댑터 정지)
    assert len(grbl.presses) == 1  # 남은 버튼은 누르지 않았다 · 같은 버튼을 다시 누르지 않았다
    (result,) = writer.of("result")
    assert result["success"] is False and result["outcome"] == "safety_stop"
    assert result["abort_reason"] == "motion_link_lost"
    assert [b["button"] for b in result["button_results"]] == ["b1"]
    assert executor.last_link_stop is not None
    assert executor.last_link_stop["sequence_id"] == "s-1" and executor.last_link_stop["run_ref"] == "r-s-1"


def test_no_self_stop_while_heartbeats_keep_coming():
    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute())
        for _ in range(8):  # 8 s 동안 1 s마다 생존 신호 — 제한 시간(3 s)을 훨씬 넘는 실행
            clock.t += 1.0
            await _line(executor, reader, {"type": "heartbeat", "sequence_id": "s-1"})
            assert executor.check_link_watchdog() is False
        grbl.release.set()
        await executor.wait_idle()
        return writer, grbl, executor

    writer, grbl, executor = asyncio.run(_t())
    assert grbl.stops == 0
    (result,) = writer.of("result")
    assert result["success"] is True and "abort_reason" not in result
    assert executor.last_link_stop is None


def test_timeout_is_at_least_three_heartbeat_periods():
    """느린 주기(2 s)를 알린 실행은 3 s가 아니라 6 s를 기다린다 — 주기 두 번 놓친 것으로 멈추지 않는다."""

    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute(heartbeat_s=2.0))
        clock.t += 5.9
        early = executor.check_link_watchdog()
        clock.t += 0.2
        executor.check_link_watchdog()
        await executor.wait_idle()
        return early, writer

    early, writer = asyncio.run(_t())
    assert early is False
    (result,) = writer.of("result")
    assert result["abort_reason"] == "motion_link_lost"


def test_any_authentic_frame_counts_as_alive():
    """(2026-10-19 뒤집음) 이름은 옛 시험을 찾기 쉽게 그대로 둔다 — 이제는 **이 실행의 생존 신호만** 살아 있다는 근거다.

    예전에는 인증된 줄이면 무엇이든(시계 탐침·정지 보고 요청·hello) 감시 시각을 새로 적었다. 그런데 RPi5가 링크를 잃고
    이 실행을 포기한 뒤 다시 이으면 시계 탐침·hello 같은 줄은 계속 오지만 이 실행의 생존 신호는 오지 않는다 — 그동안 RPi4는
    버려진 실행의 남은 버튼을 계속 눌렀다. 이 실행 번호를 실은 ``heartbeat``만 감시 시각을 새로 적는다."""

    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute())
        clock.t += 2.5
        await _line(executor, reader, {"type": "clock_probe", "probe": "p1"})
        clock.t += 2.5
        fired = executor.check_link_watchdog()
        await executor.wait_idle()
        return fired, writer

    fired, writer = asyncio.run(_t())
    assert fired is True
    (result,) = writer.of("result")
    assert result["success"] is False and result["abort_reason"] == "motion_link_lost"


def test_heartbeat_of_another_sequence_does_not_count_as_alive():
    """다른 실행 번호(또는 번호 없는) 생존 신호는 이 실행이 살아 있다는 근거가 아니다(2026-10-19)."""

    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute())
        clock.t += 2.0
        await _line(executor, reader, {"type": "heartbeat", "sequence_id": "s-old"})
        clock.t += 1.0
        await _line(executor, reader, {"type": "heartbeat"})
        clock.t += 1.0
        fired = executor.check_link_watchdog()
        await executor.wait_idle()
        return fired, writer, grbl

    fired, writer, grbl = asyncio.run(_t())
    assert fired is True and grbl.stops >= 1
    (result,) = writer.of("result")
    assert result["abort_reason"] == "motion_link_lost"


def test_hello_while_running_is_link_loss_and_stops_the_drive():
    """실행 중에 hello가 오면 RPi5가 다시 이은 것이다 — RPi5는 이 실행을 이미 '링크 끊김'으로 포기했다(2026-10-19).

    남은 버튼을 누르지 않고 받은 구동 정지와 같은 길로 멈추며, 결과는 ``safety_stop``·``motion_link_lost``다."""

    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute())
        clock.t += 0.5
        await _line(executor, reader, {"type": "hello"})
        await executor.wait_idle()
        return writer, grbl, executor

    writer, grbl, executor = asyncio.run(_t())
    assert grbl.stops >= 1
    assert len(grbl.presses) == 1  # 남은 버튼은 누르지 않았다
    (result,) = writer.of("result")
    assert result["success"] is False and result["outcome"] == "safety_stop"
    assert result["abort_reason"] == "motion_link_lost"
    assert executor.last_link_stop is not None and executor.last_link_stop["sequence_id"] == "s-1"
    assert writer.of("act_info"), "hello에는 그대로 답한다"


# ── 요구하지 않는 경우(하위 호환) ─────────────────────────────────────────────


def test_no_heartbeat_requirement_when_idle():
    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _line(executor, reader, {"type": "hello"})
        clock.t += 3600.0
        return executor.check_link_watchdog(), writer, grbl

    fired, writer, grbl = asyncio.run(_t())
    assert fired is False and grbl.stops == 0
    assert writer.of("result") == []


def test_old_rpi5_execute_without_period_has_no_watchdog():
    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute(heartbeat_s=None))
        clock.t += 3600.0
        fired = executor.check_link_watchdog()
        grbl.release.set()
        await executor.wait_idle()
        return fired, writer, grbl

    fired, writer, grbl = asyncio.run(_t())
    assert fired is False and grbl.stops == 0
    assert writer.of("result")[0]["success"] is True


def test_watchdog_ends_with_the_run():
    """실행이 끝난 뒤의 침묵은 정지 사유가 아니다 — 다음 실행(생존 신호 없음)도 막지 않는다."""

    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        grbl.release.set()
        await _line(executor, reader, _execute("s-1"))
        await executor.wait_idle()
        clock.t += 60.0
        fired = executor.check_link_watchdog()
        await _line(executor, reader, _execute("s-2", heartbeat_s=None))
        await executor.wait_idle()
        return fired, writer, grbl

    fired, writer, grbl = asyncio.run(_t())
    assert fired is False and grbl.stops == 0
    assert [r["success"] for r in writer.of("result")] == [True, True]


# ── 다시 이은 뒤 알림 ─────────────────────────────────────────────────────────


def test_link_stop_is_announced_once_after_reconnect():
    async def _t():
        executor, reader, writer, grbl, clock = _setup()
        await _start(executor, reader, grbl, _execute())
        clock.t += 3.5
        executor.check_link_watchdog()
        await executor.wait_idle()
        await _line(executor, reader, {"type": "hello"})  # RPi5가 다시 이음
        await _line(executor, reader, {"type": "hello"})
        return writer

    first, second = asyncio.run(_t()).of("act_info")
    stop = first["last_link_stop"]
    assert stop["sequence_id"] == "s-1" and stop["run_ref"] == "r-s-1"
    assert stop["outcome"] == "safety_stop" and stop["pressed"] == 1 and stop["total"] == 3
    assert stop["timeout_s"] == 3.0 and stop["silent_ms"] >= 3000
    assert "last_link_stop" not in second


# ── 배경 감시 작업(짧은 실제 시간) ─────────────────────────────────────────────


def test_background_watchdog_stops_without_being_polled():
    async def _t():
        reader, writer, grbl = asyncio.StreamReader(), _Writer(), _GateGrbl()
        controller = ClosedLoopController(grbl, MockVerifier([True] * 20), MockAlertSink(), MockSafetyController(),
                                          retry_waiter=MockRetryWaiter())
        executor = ActExecutor(reader, writer, controller, heartbeat_timeout_s=0.05)
        await _start(executor, reader, grbl, _execute(heartbeat_s=0.01))
        await asyncio.wait_for(executor.wait_idle(), 3.0)
        return writer, grbl

    writer, grbl = asyncio.run(_t())
    assert grbl.stops >= 1 and len(grbl.presses) == 1
    assert writer.of("result")[0]["abort_reason"] == "motion_link_lost"
