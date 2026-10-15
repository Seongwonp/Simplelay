"""G2 이중 방어(RPi4) — 실행 시작 전에 온 abort를 그 실행(``run_ref``)에 묶어 둔다(2026-10-15).

RPi5가 정지 뒤 execute를 보내지 않는 것이 1차 방어다(rpi/tests/test_safety_g2_stop_before_dispatch.py). 그래도 abort가
execute보다 먼저 도착했다면(쉬는 중 abort), 수리 전 RPi4는 'idle'로 버리고 뒤이어 온 execute를 전부 실행했다.

규약(하위 호환): RPi5는 실행마다 ``run_ref``를 정해 그 실행의 abort와 execute 양쪽에 싣는다. RPi4는 쉬는 중에
``run_ref`` 달린 abort를 받으면 그 값을 기억하고, 같은 ``run_ref``의 execute는 **누르지 않고** 정지 결과
(``success:false, outcome:"stopped", button_results:[]``)로 답한다. ``run_ref``가 없는 프레임(옛 RPi5)은 종전 그대로다.
"""

from __future__ import annotations

import asyncio
import json

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier import MockVerifier

from rpi4.services.act_executor import ActExecutor


class _Writer:
    def __init__(self) -> None:
        self.docs: list[dict] = []

    def write(self, data: bytes) -> None:
        self.docs.extend(json.loads(x) for x in data.splitlines() if x.strip())

    async def drain(self) -> None:
        pass

    def results(self) -> list[dict]:
        return [d for d in self.docs if d.get("type") in ("result", "error")]


def _feed(reader: asyncio.StreamReader, doc: dict) -> None:
    reader.feed_data((json.dumps(doc, ensure_ascii=False) + "\n").encode())


def _setup():
    reader, writer = asyncio.StreamReader(), _Writer()
    grbl = MockGrblClient()
    controller = ClosedLoopController(grbl, MockVerifier([True] * 20), MockAlertSink(), MockSafetyController())
    return ActExecutor(reader, writer, controller), reader, writer, grbl


def _execute(seq: str, run_ref: str | None = None) -> dict:
    doc = {"type": "execute", "sequence_id": seq, "buttons": ["b1", "b2"], "appliance_id": "microwave"}
    if run_ref is not None:
        doc["run_ref"] = run_ref
    return doc


async def _drive(executor, reader, *docs):
    for doc in docs:
        _feed(reader, doc)
        await executor.run_once()
        await executor.wait_idle()


def test_idle_abort_for_a_run_refuses_that_runs_execute_without_pressing():
    async def _t():
        executor, reader, writer, grbl = _setup()
        await _drive(executor, reader, {"type": "abort", "run_ref": "r-1"}, _execute("s-1", "r-1"))
        return writer, grbl

    writer, grbl = asyncio.run(_t())
    assert grbl.commands == []  # 누르지 않았다
    (result,) = writer.results()
    assert result["type"] == "result" and result["sequence_id"] == "s-1"
    assert result["success"] is False and result["outcome"] == "stopped"
    assert result["button_results"] == [] and result["appliance_id"] == "microwave"


def test_idle_abort_for_another_run_does_not_block_a_new_run():
    async def _t():
        executor, reader, writer, grbl = _setup()
        await _drive(executor, reader, {"type": "abort", "run_ref": "old"}, _execute("s-2", "new"))
        return writer, grbl

    writer, grbl = asyncio.run(_t())
    assert len(grbl.commands) == 2
    (result,) = writer.results()
    assert result["success"] is True


def test_the_remembered_abort_is_used_once():
    async def _t():
        executor, reader, writer, grbl = _setup()
        await _drive(executor, reader, {"type": "abort", "run_ref": "r-3"}, _execute("s-3", "r-3"),
                     _execute("s-4", "r-3"))
        return writer, grbl

    writer, grbl = asyncio.run(_t())
    first, second = writer.results()
    assert first["outcome"] == "stopped" and second["success"] is True
    assert len(grbl.commands) == 2


def test_old_rpi5_frames_without_run_ref_keep_the_old_behaviour():
    """옛 RPi5(run_ref 없음): 쉬는 중 abort는 종전처럼 버리고 다음 execute는 실행한다 — 규약 하위 호환."""
    async def _t():
        executor, reader, writer, grbl = _setup()
        await _drive(executor, reader, {"type": "abort"}, _execute("s-5"))
        return writer, grbl

    writer, grbl = asyncio.run(_t())
    assert len(grbl.commands) == 2
    assert writer.results()[0]["success"] is True


def test_idle_abort_with_stop_id_still_reports_idle():
    """정지 보고 규약 1은 그대로 — 쉬는 중이면 target idle·단계 없음(멈출 것이 없었다)."""
    async def _t():
        executor, reader, writer, _grbl = _setup()
        _feed(reader, {"type": "abort", "stop_id": "st-1", "run_ref": "r-6"})
        await executor.run_once()
        for _ in range(50):
            if any(d.get("type") == "stop_report" for d in writer.docs):
                break
            await asyncio.sleep(0.01)
        return writer

    writer = asyncio.run(_t())
    report = next(d for d in writer.docs if d.get("type") == "stop_report")
    assert report["target"] == "idle" and report["stop_level"] is None
