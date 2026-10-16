"""G5(안전 계약 적용 보고 2026-10-15 §2) — 실행 중 RPi5→RPi4 생존 신호(RPi5 쪽)와 끊김 문구.

수리 전: RPi5는 실행 중 RPi4에 아무것도 보내지 않아 Wi-Fi가 조용히 끊겨도 RPi4가 알 길이 없었다(RPi4 쪽 시험은
``rpi4/tests/test_act_link_heartbeat.py``). 그리고 RPi4가 링크를 잃고 스스로 멈춘 결과가 돌아오면 RPi5는 '안전 정지·완료되지
못했어요'로 단정했을 것이다 — 연결이 끊긴 동안 마지막 누름이 됐는지 모른다.

수리 뒤:
- RPi4가 ``act_info.heartbeat_protocol``을 알렸을 때만 ``execute``에 ``heartbeat_s``를 싣고 결과까지 ``heartbeat``를 보낸다
  (링크 이벤트 루프의 작업 — 정지 보고를 기다리는 중에도, 공용 스레드 풀이 막혀도 굶지 않는다). 옛 RPi4에는 보내지 않는다.
- ``abort_reason: motion_link_lost`` 결과는 링크 끊김과 같은 '눌렸는지 모름'(G1 문장)으로 남는다.
- RPi4가 다시 이은 뒤 알린 ``last_link_stop``은 보호자 알림 한 건이 된다(같은 실행은 한 번만).
- 링크 소켓에 ``TCP_USER_TIMEOUT``(keepalive와 같은 11 s) — 생존 신호가 쌓인 죽은 연결도 keepalive만큼 빨리 끊는다.

전송은 가짜(StreamReader·쓰기 기록) — **실물 미검증.**
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import json
import socket
import threading
import time
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from rpi.api import SimpleLayService
from rpi.api.router import command_status_fields
from rpi.api.service import LINK_UNCONFIRMED_DETAIL
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.services.act_client import ActClient, ActClientConfig, ActLinkError, ActResult
from rpi.services.act_client_controller import (
    ActClientController,
    enable_tcp_keepalive,
    start_background_loop,
)
from rpi.services.care_events import CareEventStore
from rpi.services.history import InMemoryJobHistory
from rpi.services.link_heartbeat import LinkStopNotices

NOW = datetime(2026, 10, 16, 15, tzinfo=timezone(timedelta(hours=9)))


class _Writer:
    def __init__(self) -> None:
        self.docs: list[dict] = []

    def write(self, data: bytes) -> None:
        self.docs.extend(json.loads(x) for x in data.splitlines() if x.strip())

    async def drain(self) -> None:
        pass

    def of(self, kind: str) -> list[dict]:
        return [d for d in self.docs if d.get("type") == kind]


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


async def _client(info: dict, period: float = 0.01):
    reader, writer = asyncio.StreamReader(), _Writer()
    client = ActClient(reader, writer, config=ActClientConfig(heartbeat_seconds=period))
    await client.start()
    _feed(reader, {"type": "act_info", "execute_protocol": 2, **info})
    for _ in range(50):
        if client.act_info:
            break
        await asyncio.sleep(0)
    return client, reader, writer


async def _until(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, "condition not reached"
        await asyncio.sleep(0.005)


# ── 보내기 ───────────────────────────────────────────────────────────────────


def test_heartbeats_flow_during_a_run_and_stop_with_its_result():
    async def _t():
        client, reader, writer = await _client({"heartbeat_protocol": 1})
        task = asyncio.create_task(client.execute(["b1", "b2"], sequence_id="s-1", appliance_id="microwave"))
        await _until(lambda: len(writer.of("heartbeat")) >= 3)
        _feed(reader, {"type": "result", "sequence_id": "s-1", "appliance_id": "microwave", "success": True,
                       "retry": 0, "outcome": "success"})
        result = await task
        after = len(writer.of("heartbeat"))
        await asyncio.sleep(0.08)  # 주기의 8배 — 결과 뒤에는 보내지 않는다
        await client.stop()
        return result, writer, after

    result, writer, after = asyncio.run(_t())
    assert result.success is True
    (execute,) = writer.of("execute")
    assert execute["heartbeat_s"] == 0.01
    assert all(h == {"type": "heartbeat", "sequence_id": "s-1"} for h in writer.of("heartbeat"))
    assert len(writer.of("heartbeat")) == after


def test_no_heartbeats_to_an_old_rpi4():
    async def _t():
        client, reader, writer = await _client({})
        task = asyncio.create_task(client.execute(["b1"], sequence_id="s-1", appliance_id="microwave"))
        await asyncio.sleep(0.08)
        _feed(reader, {"type": "result", "sequence_id": "s-1", "appliance_id": "microwave", "success": True,
                       "retry": 0, "outcome": "success"})
        await task
        await client.stop()
        return writer

    writer = asyncio.run(_t())
    (execute,) = writer.of("execute")
    assert "heartbeat_s" not in execute  # 종전 줄 그대로
    assert writer.of("heartbeat") == []


def test_heartbeats_are_not_starved_by_a_pending_stop_or_a_busy_thread_pool():
    """정지 보고를 기다리는 동안에도, 루프의 기본 스레드 풀이 막혀 있어도 생존 신호는 제 주기로 나간다."""

    async def _t():
        client, reader, writer = await _client({"heartbeat_protocol": 1, "stop_report_protocol": 1})
        loop = asyncio.get_running_loop()
        gate = threading.Event()
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        loop.set_default_executor(pool)
        blocked = loop.run_in_executor(None, gate.wait, 5)  # 공용 스레드 풀 한 칸을 붙잡는다
        task = asyncio.create_task(client.execute(["b1"], sequence_id="s-1", appliance_id="microwave"))
        await asyncio.sleep(0.02)
        before = len(writer.of("heartbeat"))
        report = await client.abort_with_report(timeout_s=0.3)  # RPi4가 보고하지 않는다(끊김 흉내) — 0.3 s 기다림
        during = len(writer.of("heartbeat")) - before
        gate.set()
        await blocked
        _feed(reader, {"type": "result", "sequence_id": "s-1", "appliance_id": "microwave", "success": False,
                       "retry": 0, "outcome": "stopped"})
        await task
        await client.stop()
        pool.shutdown()
        return report, during

    report, during = asyncio.run(_t())
    assert report["stop_level"] == "sent"
    assert during >= 5  # 0.3 s 동안 주기 0.01 s — 넉넉히 잡은 하한


def test_heartbeat_period_from_env(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_LINK_HEARTBEAT_S", "0.5")
    assert ActClientConfig.from_env().heartbeat_seconds == 0.5
    for bad in ("0", "-1", "abc", "60"):
        monkeypatch.setenv("SIMPLELAY_LINK_HEARTBEAT_S", bad)
        assert ActClientConfig.from_env().heartbeat_seconds == 1.0
    monkeypatch.delenv("SIMPLELAY_LINK_HEARTBEAT_S")
    assert ActClientConfig.from_env().heartbeat_seconds == 1.0


# ── 문구: 링크를 잃고 멈춘 실행은 '눌렸는지 모름' ────────────────────────────────


class _LinkLostClient:
    """RPi4가 생존 신호를 잃고 스스로 멈췄다고 답하는 링크(결과는 늦게라도 도착한 경우)."""

    estop_latched = False
    estop_detail = None
    link_up = True

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def response_timeout_for(self, button_count: int) -> float:
        return 5.0

    async def execute(self, buttons, **kwargs) -> ActResult:
        self.calls.append(list(buttons))
        return ActResult(sequence_id="s-1", success=False, retry=0, outcome="safety_stop",
                         abort_reason="motion_link_lost")


def test_link_lost_self_stop_is_recorded_as_unconfirmed_not_failed():
    loop, _thread = start_background_loop()
    try:
        client = _LinkLostClient()
        controller = ActClientController(loop, client)
        controller.arm_execute_target("microwave")
        with pytest.raises(ActLinkError):
            controller.execute(["b1", "b2"])

        history, care = InMemoryJobHistory(), CareEventStore(FixedClock(NOW))
        service = SimpleLayService(RuleBasedIntentResolver(), ActClientController(loop, client),
                                   clock=FixedClock(NOW), history_store=history, care_events=care)
        job_id = service.submit_buttons(("BT-08", "시작"))
        deadline = time.monotonic() + 5
        snap = service.status()
        while snap.running or snap.last_job_id != job_id:
            assert time.monotonic() < deadline, "job did not finish"
            time.sleep(0.01)
            snap = service.status()
    finally:
        loop.call_soon_threadsafe(loop.stop)

    fields = command_status_fields(snap)
    assert fields["last_status"] == "unconfirmed" and fields["last_outcome"] == "unconfirmed"
    assert fields["last_detail"] == LINK_UNCONFIRMED_DETAIL
    entry = history.recent()[0]
    assert entry.outcome == "unconfirmed" and entry.receipt == "unknown"
    messages = [e.message for e in care.recent()]
    assert any("눌렸는지 확인하지 못했어요" in m for m in messages)
    assert not any("완료되지 못했어요" in m or "완료하지 못했어요" in m for m in messages)
    assert len(client.calls) == 2  # 다시 누르지 않는다(controller 1회 + service 1회)


# ── 다시 이은 뒤 RPi4의 알림 ──────────────────────────────────────────────────


def test_rpi4_link_stop_notice_becomes_one_care_event():
    care = CareEventStore(FixedClock(NOW))
    notices = LinkStopNotices(lambda: care)
    stop = {"sequence_id": "s-1", "run_ref": "r-1", "outcome": "safety_stop", "pressed": 1, "total": 3,
            "silent_ms": 3100, "timeout_s": 3.0}
    assert notices.receive({"type": "act_info", "last_link_stop": stop}) is True
    assert notices.receive({"type": "act_info", "last_link_stop": stop}) is False  # 같은 실행은 한 번
    assert notices.receive({"type": "act_info"}) is False
    assert notices.receive({"type": "act_info", "last_link_stop": {"sequence_id": 3}}) is False  # 모양이 틀림
    (event,) = care.recent()
    assert event.kind == "execution_failed"
    assert "연결이 끊겨" in event.message and "스스로 멈췄어요" in event.message
    assert "3개 중 1개" in event.message and "자동으로 다시 누르지 않아요" in event.message


def test_act_client_keeps_the_last_link_stop_across_link_down():
    async def _t():
        stop = {"sequence_id": "s-9", "run_ref": "r-9", "outcome": "safety_stop", "pressed": 0, "total": 2,
                "silent_ms": 3200, "timeout_s": 3.0}
        client, reader, writer = await _client({"heartbeat_protocol": 1, "last_link_stop": stop})
        reader.feed_eof()
        await _until(lambda: not client.link_up)
        await client.stop()
        return client

    client = asyncio.run(_t())
    assert client.last_link_stop is not None and client.last_link_stop["sequence_id"] == "s-9"


# ── 죽은 연결에 쌓인 생존 신호 ────────────────────────────────────────────────


class _RecordingSocket(socket.socket):
    def setsockopt(self, *args):  # type: ignore[override]
        self.calls.append(args)


def test_link_socket_gets_tcp_user_timeout(monkeypatch):
    """keepalive는 보낼 줄이 쌓여 있으면 돌지 않는다(Linux) — 생존 신호를 쓰는 링크는 TCP_USER_TIMEOUT으로 같은 11 s에 끊는다."""
    monkeypatch.setattr(socket, "TCP_USER_TIMEOUT", 18, raising=False)
    with _RecordingSocket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.calls = []
        writer = SimpleNamespace(transport=SimpleNamespace(serial=SimpleNamespace(_socket=sock)))
        assert enable_tcp_keepalive(writer) is True
        assert (socket.IPPROTO_TCP, 18, 11000) in sock.calls
